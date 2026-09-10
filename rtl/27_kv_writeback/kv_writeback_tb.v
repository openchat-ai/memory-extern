`timescale 1ps/1ps
//────────────────────────────────────────────────────────────────────────────
// kv_writeback_tb.v — M12 v2 层 KV 写回件 (P1 状态搬移件) 字节序对账
//
// 契约(基线 §5 写回协议 v0 / sim_layer_flow.py):
//   · 每 token 24 层严格层序, 层 L payload 必在层 L+1 前到 host
//   · 帧 = 8B 头 + 544B payload(latent 512×INT8 + rope 64×4bit)
//        → token 账: 24×552 = 13,248B(帧), payload 12,750B=12.75KB ✓ 口径对接
//   · 每 token 1 scale(INT8 latent/rope 峰通算), token 全体梳理后定 —— pass0/pass1
//   · DMA 弹性 FIFO 无信用(阈值 50%)→ 停推不丢序; 恢复后续推
// 源纪律(M6 同款): lat_valid/s_rope 组合直出, 词序 == DUT 自身计数 (p0_lat/pl_lat/...),
//                  采样同拍 → 词值绝对对齐, 无任务握手竞态。
// 对账核:
//   · exp_idx 全局字节流镜像: 每推 1B 比对黄金帧字节(帧序号/层号/量化核独立复算)
//   · 推口信用违例(credit=0 时 f_we)记 crime; 停顿注入段真实挡(挂起字节恒有)
//   · 快照差账: bytes_written delta = 24×552, frames delta = 24
//   · order_bad 全程为 0
//────────────────────────────────────────────────────────────────────────────
module kv_writeback_tb;
    localparam NL2 = 24, LATENT = 512, ROPE = 64;
    localparam FRAME_B = 8 + LATENT + ROPE/2;      // 552
    localparam TOK_B   = NL2 * FRAME_B;            // 13248
    localparam FIFO_CAP = 4096, TCUT = FIFO_CAP/2; // 弹性 FIFO + 50% 阈值

    reg clk = 0, rst_n = 0; always #5 clk = ~clk;

    reg go, lat_valid, rope_valid;
    reg [7:0] s_lay, s_lat, s_rope;
    wire credit, f_valid, f_we; wire [7:0] f_b;
    wire busy, token_done, order_bad, lat_abs, rope_abs;
    wire [31:0] bytes_written, frames, stalls;

    kv_writeback #(.NL2(NL2), .LATENT(LATENT), .ROPE(ROPE)) u (
        .clk(clk), .rst_n(rst_n), .go(go), .busy(busy),
        .s_lay(s_lay), .lat_valid(lat_valid), .s_lat(s_lat),
        .rope_valid(rope_valid), .s_rope(s_rope), .lat_abs(lat_abs), .rope_abs(rope_abs),
        .credit(credit), .f_valid(f_valid), .f_we(f_we), .f_b(f_b),
        .bytes_written(bytes_written), .frames(frames), .stalls(stalls),
        .order_bad(order_bad), .token_done(token_done));

    //--------------- 数据 / 黄金核 ----------------
    integer crime = 0, err = 0;
    integer occ = 0;           // 弹性 FIFO 占用 (宿主侧未排空量)
    integer exp_idx = 0;       // 全局字节流游标 (深对账)
    integer drain_en = 0;      // 主机侧排空使能
    integer LG, RG;            // token 级 scale (全 token 梳理一次, 黄金核用)

    function [7:0] lat_src(input integer lay, input integer k);
        begin lat_src = ((lay*131 + k*7 + 5) % 255) + 1; end
    endfunction
    function [7:0] rope_src(input integer lay, input integer k);
        begin rope_src = ((lay*37 + k*3 + 13) % 255) + 1; end
    endfunction

    function [15:0] lscale_g;
        reg [7:0] mx; integer a, b;
        begin
            mx = 0;
            for (a = 0; a < NL2; a = a + 1)
                for (b = 0; b < LATENT; b = b + 1)
                    if (lat_src(a, b) > mx) mx = lat_src(a, b);
            lscale_g = (16'd16256) / {8'd0, mx};
        end
    endfunction
    function [15:0] rscale_g;
        reg [7:0] mx; integer a, b;
        begin
            mx = 0;
            for (a = 0; a < NL2; a = a + 1)
                for (b = 0; b < ROPE; b = b + 1)
                    if (rope_src(a, b) > mx) mx = rope_src(a, b);
            rscale_g = (16'd1920) / {8'd0, mx};
        end
    endfunction
    function [7:0] qlat(input [7:0] v, input [15:0] s);
        reg [23:0] t;
        begin t = $unsigned(v)*s; qlat = (t + 64) >> 7; if (qlat > 8'd127) qlat = 8'd127; end
    endfunction

    // 全局字节流黄金值: exp_idx → (层序) 字节, 552B/帧
    function [7:0] expb(input integer ix);
        integer fr, lay, off; reg [7:0] r;
        begin
            fr  = ix / FRAME_B;
            off = ix % FRAME_B;
            lay = fr % NL2;
            r = 0;
            if (off < 8) begin
                case (off)
                    0: r = lay[7:0];
                    1: r = 8'h00;
                    2: r = 8'h01;    // 类型 v2=KV-append
                    3: r = 8'h00;
                    4: r = 8'h00;
                    5: r = 8'h00;
                    6: r = 8'h20;    // 长度 544 = {0x02,0x20}
                    7: r = 8'h02;
                endcase
            end
            else if (off < 8 + LATENT)
                r = qlat(lat_src(lay, off - 8), LG);
            else begin
                // rope 段: 每字节 = 偶(hi)奇(lo) 各 4bit (量化核同式复算)
                r = {(qrope4(rope_src(lay, (off-8-LATENT)*2),   RG)),
                     (qrope4(rope_src(lay, (off-8-LATENT)*2+1), RG))};
            end
            expb = r;
        end
    endfunction
    function [3:0] qrope4(input [7:0] v, input [15:0] s);
        reg [23:0] t; reg [3:0] r;
        begin t = $unsigned(v)*s; r = (t + 64) >> 7; if (r > 4'd15) r = 4'd15; qrope4 = r; end
    endfunction

    //--------------- M6 组合源: 词序 == DUT 内部计数 ----------------
    wire latv_p0 = u.session && (u.st == 2'd1) && (u.p0_lat < LAT_T);
    wire latv_p1 = u.session && (u.st == 2'd2) && (u.ws == 3'd1);
    wire ropev_p0 = u.session && (u.st == 2'd1) && (u.p0_rope < ROPE_T);
    wire ropev_p1 = u.session && (u.st == 2'd2) && ((u.ws == 3'd2) || (u.ws == 3'd3));
    assign lat_valid = latv_p0 | latv_p1;
    assign rope_valid = ropev_p0 | ropev_p1;
    assign s_lat  = (u.st == 2'd1) ? lat_src(u.p0_lat / 512, u.p0_lat % 512)
                                   : lat_src(u.pl_lay, u.pl_lat);
    assign s_rope = (u.st == 2'd1) ? rope_src(u.p0_rope / 64, u.p0_rope % 64)
                                   : rope_src(u.pl_lay, u.pl_rope + (u.ws == 3'd3 ? 1 : 0));
    assign s_lay  = u.pl_lay[7:0];

    localparam LAT_T = NL2 * LATENT, ROPE_T = NL2 * ROPE;

    //--------------- 推口对账 + FIFO 占用 ----------------
    always @(posedge clk) begin
        if (rst_n) begin
            if (u.f_we && u.f_valid) begin
                if (!credit) begin
                    crime = crime + 1;
                    $display("%0t FAIL push without credit (occ=%0d)", $time, occ);
                end
                if (expb(exp_idx) !== u.f_b) begin
                    err = err + 1;
                    $display("%0t FAIL byte exp_idx=%0d got=%0h gold=%0h", $time,
                             exp_idx, u.f_b, expb(exp_idx));
                end
                exp_idx = exp_idx + 1;
                occ = occ + 1;
            end
            if (drain_en && occ > 0) occ = occ - 1;
        end
    end
    assign credit = (occ < TCUT);

    //--------------- 主流程 ----------------
    integer b0, f0;
    initial begin
        repeat (3) @(posedge clk); #1; rst_n = 1;
        go = 0; LG = lscale_g(); RG = rscale_g();

        //---- T0 全信用(主机常排空, 预期零停顿) ----
        drain_en = 1;
        @(posedge clk); go = 1; @(posedge clk); go = 0;
        b0 = bytes_written; f0 = frames;
        while (!token_done) @(posedge clk);
        repeat (2) @(posedge clk);
        if (bytes_written - b0[31:0] != TOK_B) err = err + 1;
        if (frames - f0[31:0]   != NL2)       err = err + 1;
        $display("== T0 帧%0d 字节%0d 对账到%0d stalls=%0d 信用违例%0d ==",
                 frames - f0[31:0], bytes_written - b0[31:0], exp_idx, u.stalls, crime);

        //---- T1 停顿注入: 排空熄火 → FIFO>50% 真挡 → 恢复 ----
        drain_en = 0;
        @(posedge clk); go = 1; @(posedge clk); go = 0;
        b0 = bytes_written; f0 = frames;
        while (!token_done) begin
            @(posedge clk);
            if (u.stalls > 0) drain_en = 1;   // 第一次真实 stall 后恢复排空
        end
        repeat (2) @(posedge clk);
        if (bytes_written - b0[31:0] != TOK_B) err = err + 1;
        if (frames - f0[31:0]   != NL2)       err = err + 1;
        if (u.stalls == 0)                  err = err + 1;
        if (order_bad)                      err = err + 1;
        if (crime)                          err = err + 1;
        if (exp_idx != 2 * TOK_B)          err = err + 1;
        $display("== T1 帧%0d 字节%0d 停顿%0d 对账到%0d 信用违例%0d order_bad=%0b ==",
                 frames - f0[31:0], bytes_written - b0[31:0], u.stalls, exp_idx, crime, order_bad);

        if (err == 0 && crime == 0 && !order_bad && u.stalls > 0)
            $display("##### ALL PASS: M12 v2层 KV 写回 544B×24 严格层序 · token级1scale · credit 弹性 FIFO #####");
        else
            $display("##### FAIL err=%0d crime=%0d #####", err, crime);
        $finish;
    end

    // 看门狗
    integer wdc = 0;
    always @(posedge clk) begin
        if (busy) begin
            if (wdc > 2000000) begin $display("%0t FAIL watchdog", $time); $finish; end
            wdc = wdc + 1;
        end else wdc = 0;
    end
endmodule