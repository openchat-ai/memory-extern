`timescale 1ps/1ps
//────────────────────────────────────────────────────────────────────────────
// kv_restore_tb.v — M15 v2 层 KV 读回件 (P1 状态搬移件, 读侧) 字节序对账
//
// 契约(写回协议 v0 镜像; 字节布局 ≡ M14 写者在真尺寸下实际吐出的 v2 帧):
//   · 每 token 24 层帧严格层序 0..23, 每帧 552B = 8B 头[层号,01,0,0,544LE]
//     + 512 latent INT8(qlat8, token 级 scale) + 32 rope 包(2×4bit/{偶,奇})
//   · 宿主持续献字节(kv_valid=busy 全速), 模块靠 credit 门: 无信用挂起记
//     stall, 回补后续吸 —— 不丢不序不乱
//   · 头 8B 逐字段模块自验 → head_bad(=0); 层序号由帧末 pl_lay 连进保证
//   · 黄金镜像逐字节: 增量(cur_lay, cur_off)游标, 值 = expb(r,层,off) 复算
//   · 信用: 寄存 occ_q 与吸收/排空同沿 → 无 delta 竞态, occ 上限 = 阈值
// 场景: T0 排空全开(零停顿); T1 排空熄火真挡 → 恢复; 全程 2 token 对账。
//────────────────────────────────────────────────────────────────────────────
module kv_restore_tb;
    localparam NL = 93, NL2 = 24, LATENT = 512, ROPE = 64;
    localparam V2_FB = 8 + LATENT + ROPE/2;
    localparam FIFO_CAP = 4096, TCUT = FIFO_CAP/2;

    reg clk = 0, rst_n = 0; always #5 clk = ~clk;
    reg go, drain_en = 0;
    wire credit;
    wire kv_valid, busy, token_done, head_bad;
    wire [7:0] s_kv, round;
    wire [31:0] bytes_consumed, frames, stalls;

    // 宿主献字节: 全速 (busy 期间每拍一个正确字节, credit 门由模块吸收)
    assign kv_valid = busy;
    assign s_kv = expb(u.round, u.pl_lay, u.q);

    kv_restore #(.NL2(NL2), .LATENT(LATENT), .ROPE(ROPE)) u (
        .clk(clk), .rst_n(rst_n), .go(go), .credit(credit), .busy(busy),
        .kv_valid(kv_valid), .s_kv(s_kv),
        .token_done(token_done), .head_bad(head_bad), .round(round),
        .bytes_consumed(bytes_consumed), .frames(frames), .stalls(stalls));

    //--------------- 值函数 (≡ M14 写者黄金核) ----------------
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

    // 每 token 第 lay 索引帧 (0..23 → 实际层 v2lay(lay)) 第 off 字节黄金
    function integer v2lay(input integer n);
        begin v2lay = (n == NL2 - 1) ? (NL - 1) : (4 * n + 3); end
    endfunction
    function [7:0] expb(input integer r, lay, off);
        integer rp, LL;
        reg [31:0] len; reg [7:0] o;
        begin
            LL = v2lay(lay);
            o = 0;
            if (off < 8) begin
                len = V2_FB - 8;
                case (off)
                    0: o = LL[7:0];
                    1: o = 8'h01;
                    2: o = 0; 3: o = 0;
                    4: o = len[7:0];
                    5: o = len[15:8];
                    6: o = len[23:16];
                    7: o = len[31:24];
                endcase
            end
            else if (off - 8 < LATENT)
                o = qlat8(lat_src(r, LL, off - 8), curLG);
            else begin
                rp = off - 8 - LATENT;
                o = {qr4(rope_src(r, LL, 2*rp), curRG),
                     qr4(rope_src(r, LL, 2*rp + 1), curRG)};
            end
            expb = o;
        end
    endfunction

    //--------------- 推口对账 + FIFO 占用 (occ_q 同沿, 无竞态) ----------------
    integer crime = 0, err = 0, exp_idx = 0, occ_max = 0;
    integer cur_lay = 0, cur_off = 0, cur_round = 0;
    integer TOK_B, b0, f0, L;
    reg [15:0] occ_q = 0;
    assign credit = (occ_q < TCUT);

    always @(posedge clk) begin
        if (rst_n) begin
            if (occ_q > occ_max) occ_max = occ_q;
            if (kv_valid && credit) begin
                if (expb(cur_round, cur_lay, cur_off) !== s_kv) begin
                    err = err + 1;
                    if (err < 8)
                        $display("%0t FAIL byte exp_idx=%0d (lay=%0d off=%0d) got=%0h gold=%0h", $time,
                                 exp_idx, cur_lay, cur_off, s_kv, expb(cur_round, cur_lay, cur_off));
                end
                exp_idx = exp_idx + 1;
                cur_off = cur_off + 1;
                if (cur_off == V2_FB) begin cur_lay = cur_lay + 1; cur_off = 0; end
            end
            if      (kv_valid && credit) occ_q <= occ_q + 1 - (drain_en && occ_q > 0 ? 1 : 0);
            else if (drain_en && occ_q > 0) occ_q <= occ_q - 1;
        end
        else occ_q <= 0;
    end

    //--------------- 主流程 ----------------
    initial begin
        TOK_B = NL2 * V2_FB;
        repeat (3) @(posedge clk); #1; rst_n = 1;
        go = 0;

        //---- T0 排空全开 (轮0) ----
        cur_round = 0;
        curLG = lscale_g(0); curRG = rscale_g(0);
        drain_en = 1; cur_lay = 0; cur_off = 0;
        @(posedge clk); go = 1; @(posedge clk); go = 0;
        b0 = bytes_consumed; f0 = frames;
        while (!token_done) @(posedge clk);
        repeat (2) @(posedge clk);
        if (bytes_consumed != TOK_B) err = err + 1;
        if (frames != NL2)           err = err + 1;
        if (u.stalls != 0)           err = err + 1;
        if (head_bad)                err = err + 1;
        $display("== T0 帧%0d 字节%0d 停顿%0d 对账到%0d 信用违例%0d occ峰%0d ==",
                 frames, bytes_consumed, u.stalls, exp_idx, crime, occ_max);

        //---- T1 停顿注入 (轮1) ----
        cur_round = 1;
        curLG = lscale_g(1); curRG = rscale_g(1);
        drain_en = 0; cur_lay = 0; cur_off = 0;
        @(posedge clk); go = 1; @(posedge clk); go = 0;
        b0 = bytes_consumed; f0 = frames;
        while (!token_done) begin
            @(posedge clk);
            if (u.stalls > 0) drain_en = 1;
        end
        repeat (2) @(posedge clk);
        if (bytes_consumed - b0[31:0] != TOK_B) err = err + 1;
        if (frames - f0[31:0] != NL2)           err = err + 1;
        if (u.stalls == 0)                      err = err + 1;
        if (head_bad)                           err = err + 1;
        if (crime)                              err = err + 1;
        if (exp_idx != 2 * TOK_B)               err = err + 1;
        $display("== T1 帧%0d 字节%0d 停顿%0d 对账到%0d 信用违例%0d head_bad=%0b occ峰%0d ==",
                 frames - f0[31:0], bytes_consumed - b0[31:0], u.stalls, exp_idx, crime, head_bad, occ_max);

        if (err == 0 && !head_bad && u.stalls > 0)
            $display("##### ALL PASS: M15 v2层 KV 读回 552B×24 严格层序 · token级scale恢复 · credit 弹性背压 #####");
        else
            $display("##### FAIL err=%0d head_bad=%0b occ_max=%0d #####", err, head_bad, occ_max);
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