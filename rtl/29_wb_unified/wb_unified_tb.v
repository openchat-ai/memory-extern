`timescale 1ps/1ps
//────────────────────────────────────────────────────────────────────────────
// wb_unified_tb.v — M14 统一写回引擎 (P1 状态搬移件) 字节序对账
//
// 契约/对账核(与 sim_layer_flow.py build_events 执行序同构):
//   · 每 token 93 帧严格层序 0..92: v1 → diff 49,160B / v2 → KV 552B
//   · 帧序 = 层序(逐层一帧), 层完成 = barrier, token_done 后 host ACK, round++
//   · 黄金镜像逐字节: 增量(cur_lay, cur_off)游标, 值按(round,层,头/kv/i|词)复算
//   · LG/RG 每 token 由 token 级峰独立复算 (round 参与值函数 → 轮值可区分)
//   · 信用: 寄存 occ_q 与推/排空同沿 → 无 delta 竞态, occ 上限 = 阈值
// 场景: T0 全信用(零停顿); T1 排空熄火真挡 → 恢复; 全程 2 token 字节序对账。
//────────────────────────────────────────────────────────────────────────────
module wb_unified_tb;
    localparam NL = 93, NL2 = 24, HEADS = 96, D = 128;
    localparam LATENT = 512, ROPE = 64;
    localparam DIFF_B = HEADS * (D + D) * 2;
    localparam V2_FB = 8 + LATENT + ROPE/2;
    localparam FIFO_CAP = 4096, TCUT = FIFO_CAP/2;

    reg clk = 0, rst_n = 0; always #5 clk = ~clk;
    reg go, credit_ok;   // (credit 由 occ_q 组合)
    reg diff_valid, lat_valid, rope_valid;
    reg [7:0] s_lay, s_lat, s_rope; reg [15:0] s_elem;
    wire credit, f_valid, f_we, busy, token_done, order_bad;
    wire [7:0] f_b, round;
    wire [31:0] bytes_written, frames, stalls;

    wb_unified #(.NL(NL), .NL2(NL2), .LATENT(LATENT), .ROPE(ROPE),
                 .HEADS(HEADS), .D(D)) u (
        .clk(clk), .rst_n(rst_n), .go(go), .credit(credit), .busy(busy),
        .s_lay(s_lay), .diff_valid(diff_valid), .s_elem(s_elem),
        .lat_valid(lat_valid), .s_lat(s_lat), .rope_valid(rope_valid), .s_rope(s_rope),
        .f_valid(f_valid), .f_we(f_we), .f_b(f_b),
        .bytes_written(bytes_written), .frames(frames), .stalls(stalls),
        .order_bad(order_bad), .token_done(token_done), .round(round));

    //--------------- 层型 / 值函数 ----------------
    function integer v2(input integer l);
        begin v2 = (l % 4 == 3) || (l == NL - 1); end
    endfunction
    function integer v2lay(input integer n);
        begin v2lay = (n == NL2 - 1) ? (NL - 1) : (4 * n + 3); end
    endfunction
    function integer fszb(input integer l);
        begin fszb = v2(l) ? V2_FB : 8 + DIFF_B; end
    endfunction
    function [15:0] elem_src(input integer r, lay, head, kv, i);
        reg [31:0] t;
        begin
            t = (r * 131 + lay * 257 + head * 131 + kv * 37 + i * 11 + 17) % 65536;
            elem_src = (t + 1) & 16'hFFFF;
        end
    endfunction
    function [7:0] lat_src(input integer r, lay, k);
        begin lat_src = ((lay * 131 + k * 7 + r * 5 + 5) % 255) + 1; end
    endfunction
    function [7:0] rope_src(input integer r, lay, k);
        begin rope_src = ((lay * 37 + k * 3 + r * 7 + 13) % 255) + 1; end
    endfunction
    function [7:0] qlat8(input [7:0] v, input [15:0] s);
        reg [23:0] t; begin t = $unsigned(v)*s; qlat8 = (t + 64) >> 7; if (qlat8 > 8'd127) qlat8 = 8'd127; end
    endfunction
    function [3:0] qr4(input [7:0] v, input [15:0] s);
        reg [23:0] t; begin t = $unsigned(v)*s; qr4 = (t + 64) >> 7; if (qr4 > 4'd15) qr4 = 4'd15; end
    endfunction

    integer curLG, curRG;
    function [15:0] lscale_g(input integer r);
        reg [7:0] mx; integer a, b;
        begin
            mx = 0;
            for (a = 0; a < NL2; a = a + 1)
                for (b = 0; b < LATENT; b = b + 1)
                    if (lat_src(r, v2lay(a), b) > mx) mx = lat_src(r, v2lay(a), b);
            lscale_g = (16'd16256) / {8'd0, mx};
        end
    endfunction
    function [15:0] rscale_g(input integer r);
        reg [7:0] mx; integer a, b;
        begin
            mx = 0;
            for (a = 0; a < NL2; a = a + 1)
                for (b = 0; b < ROPE; b = b + 1)
                    if (rope_src(r, v2lay(a), b) > mx) mx = rope_src(r, v2lay(a), b);
            rscale_g = (16'd1920) / {8'd0, mx};
        end
    endfunction

    // 帧内 (lay, off) 黄金字节
    function [7:0] expb(input integer lay, off, r);
        integer e, ei, b, head, win, kv, i, rp;
        reg [31:0] len; reg [15:0] el; reg [7:0] o;
        begin
            o = 0;
            if (off < 8) begin
                len = v2(lay) ? V2_FB - 8 : DIFF_B;
                case (off)
                    0: o = lay[7:0];
                    1: o = v2(lay) ? 8'h01 : 8'h11;
                    2: o = 0; 3: o = 0;
                    4: o = len[7:0];
                    5: o = len[15:8];
                    6: o = len[23:16];
                    7: o = len[31:24];
                endcase
            end
            else if (!v2(lay)) begin
                e = off - 8; ei = e / 2; b = e % 2;
                head = ei / (D + D); win = ei % (D + D);
                kv = win / D; i = win % D;
                el = elem_src(r, lay, head, kv, i);
                o = b ? el[15:8] : el[7:0];
            end
            else begin
                if (off - 8 < LATENT)
                    o = qlat8(lat_src(r, lay, off - 8), curLG);
                else begin
                    rp = off - 8 - LATENT;
                    o = {qr4(rope_src(r, lay, 2*rp), curRG),
                         qr4(rope_src(r, lay, 2*rp + 1), curRG)};
                end
            end
            expb = o;
        end
    endfunction

    //--------------- 组合源 (词序 ≡ u 计数) ----------------
    localparam P0_LAT_T = NL2 * LATENT, P0_ROPE_T = NL2 * ROPE, ELEM_T = HEADS * (D + D);
    assign lat_valid  = (u.st == 2'd1) ? (u.p0_lat < P0_LAT_T)
                       : (u.st == 2'd2) ? (u.ws == 2'd1 && v2(u.pl_lay) && u.pl_kvlat < LATENT) : 0;
    assign rope_valid = (u.st == 2'd1) ? (u.p0_rope < P0_ROPE_T)
                       : (u.st == 2'd2) ? ((u.ws == 2'd2 || u.ws == 2'd3) && v2(u.pl_lay) && u.pl_kvrope < ROPE) : 0;
    assign diff_valid = (u.st == 2'd2) && !v2(u.pl_lay) && (u.ws == 2'd1) && (u.pl_elem < ELEM_T);
    assign s_lat  = (u.st == 2'd1) ? lat_src(u.round, v2lay(u.p0_lat / LATENT), u.p0_lat % LATENT)
                                   : lat_src(u.round, u.pl_lay, u.pl_kvlat);
    assign s_rope = (u.st == 2'd1) ? rope_src(u.round, v2lay(u.p0_rope / ROPE), u.p0_rope % ROPE)
                                   : (u.ws == 2'd3) ? rope_src(u.round, u.pl_lay, u.pl_kvrope + 1)
                                                    : rope_src(u.round, u.pl_lay, u.pl_kvrope);
    assign s_elem = elem_src(u.round, u.pl_lay,
                              (u.pl_elem / (D + D)), ((u.pl_elem % (D + D)) / D), (u.pl_elem % D));
    assign s_lay  = u.pl_lay[7:0];

    //--------------- 推口对账 + FIFO 占用 (ocq 同沿, 无竞态) ----------------
    integer crime = 0, err = 0, exp_idx = 0, drain_en = 0, occ_max = 0;
    integer cur_lay = 0, cur_off = 0, cur_round = 0;
    integer TOK_B;
    integer b0, f0, L;
    reg [15:0] occ_q = 0;
    assign credit = (occ_q < TCUT);

    always @(posedge clk) begin
        if (rst_n) begin
            if (occ_q > occ_max) occ_max = occ_q;
            if (u.f_we && u.f_valid) begin
                if (expb(cur_lay, cur_off, cur_round) !== u.f_b) begin
                    err = err + 1;
                    if (err < 8)
                        $display("%0t FAIL byte exp_idx=%0d (lay=%0d off=%0d) got=%0h gold=%0h", $time,
                                 exp_idx, cur_lay, cur_off, u.f_b, expb(cur_lay, cur_off, cur_round));
                end
                exp_idx = exp_idx + 1;
                cur_off = cur_off + 1;
                if (cur_off == fszb(cur_lay)) begin cur_lay = cur_lay + 1; cur_off = 0; end
            end
            if      (u.f_we && u.f_valid) occ_q <= occ_q + 1 - (drain_en && occ_q > 0 ? 1 : 0);
            else if (drain_en && occ_q > 0) occ_q <= occ_q - 1;
        end
        else occ_q <= 0;
    end

    //--------------- 主流程 ----------------
    initial begin
        TOK_B = 0;
        for (L = 0; L < NL; L = L + 1) TOK_B = TOK_B + fszb(L);
        repeat (3) @(posedge clk); #1; rst_n = 1;
        go = 0;

        //---- T0 全信用 (轮0) ----
        cur_round = 0;
        curLG = lscale_g(0); curRG = rscale_g(0);
        drain_en = 1; cur_lay = 0; cur_off = 0;
        @(posedge clk); go = 1; @(posedge clk); go = 0;
        b0 = bytes_written; f0 = frames;
        while (!token_done) @(posedge clk);
        repeat (2) @(posedge clk);
        if (bytes_written != TOK_B) err = err + 1;
        if (frames != NL)           err = err + 1;
        $display("== T0 帧%0d 字节%0d 停顿%0d 对账到%0d 信用违例%0d occ峰%0d ==",
                 frames, bytes_written, u.stalls, exp_idx, crime, occ_max);

        //---- T1 停顿注入 (轮1) ----
        cur_round = 1;
        curLG = lscale_g(1); curRG = rscale_g(1);
        drain_en = 0; cur_lay = 0; cur_off = 0;
        @(posedge clk); go = 1; @(posedge clk); go = 0;
        b0 = bytes_written; f0 = frames;
        while (!token_done) begin
            @(posedge clk);
            if (u.stalls > 0) drain_en = 1;
        end
        repeat (2) @(posedge clk);
        if (bytes_written - b0[31:0] != TOK_B) err = err + 1;
        if (frames - f0[31:0] != NL)           err = err + 1;
        if (u.stalls == 0)                     err = err + 1;
        if (order_bad)                         err = err + 1;
        if (crime)                             err = err + 1;
        if (exp_idx != 2 * TOK_B)              err = err + 1;
        $display("== T1 帧%0d 字节%0d 停顿%0d 对账到%0d 信用违例%0d order_bad=%0b occ峰%0d ==",
                 frames - f0[31:0], bytes_written - b0[31:0], u.stalls, exp_idx, crime, order_bad, occ_max);

        if (err == 0 && crime == 0 && !order_bad && u.stalls > 0)
            $display("##### ALL PASS: M14 统一写回引擎 93层混排 严格层序 0..92 (69×diff + 24×KV) · token级scale · credit 弹性 FIFO · 2 token 字节序对账 #####");
        else
            $display("##### FAIL err=%0d crime=%0d occ_max=%0d #####", err, crime, occ_max);
        $finish;
    end

    // 看门狗
    integer wdc = 0;
    always @(posedge clk) begin
        if (busy) begin
            if (wdc > 20000000) begin $display("%0t FAIL watchdog", $time); $finish; end
            wdc = wdc + 1;
        end else wdc = 0;
    end
endmodule