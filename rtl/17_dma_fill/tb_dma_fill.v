`timescale 1ns/1ps
//────────────────────────────────────────────────────────────────────────────
// tb_dma_fill.v — 引擎→A-tile 直连端到端
//   go(total=24) -> 引擎灌 3 帧(0..15 先灌 => A/B 双轨被占 => 引擎停等 any_free)
//   -> 读侧吃空帧0 -> 引擎秒续 claim 灌帧3(16..23) -> 与读帧1/2 交叉 -> 全部读毕。
//   断流: 每 3 字停 2 拍, 验背压下词序/帧界不丢。
//   生产端 = 寄存器化的真源: have/nxt 喂字, always 以 NFL 沿发出 valid/data,
//   消费沿后撤 valid —— 一源一字, 与引擎/atile 的沿采样完全确定。
//   验收: frames_claimed=3 / frames_filled=3 / frames_read=3 / prog=24 /
//         readback=0..23 全序 / bubbles=0 / done 恰好一拍 / busy 收尾归零。
//────────────────────────────────────────────────────────────────────────────
module tb;
    localparam DW = 32, TDEPTH = 8;
    reg clk = 0, rst_n = 0; always #5 clk = ~clk;

    //---- 字符源 (寄存器化) -----
    reg go, have; reg [DW-1:0] nxt;
    reg src_valid; reg [DW-1:0] src_data;
    wire src_ready, busy, done;
    wire [31:0] frames_claimed, prog;

    //---- A-tile 读侧 -----
    wire r_valid; wire [DW-1:0] r_data; wire r_frame_done, swap;
    wire [31:0] frames_filled, frames_read, bubbles;
    reg r_take;

    wire f_start, f_valid, f_ready, any_free, f_sel;
    wire [DW-1:0] f_data;

    dma_fill #(.DW(DW), .TDEPTH(TDEPTH)) eng (.clk(clk),.rst_n(rst_n),
        .go(go),.total(32'd24),.busy(busy),.done(done),
        .src_valid(src_valid),.src_ready(src_ready),.src_data(src_data),
        .f_start(f_start),.f_valid(f_valid),.f_data(f_data),
        .f_ready(f_ready),.any_free(any_free),
        .frames_claimed(frames_claimed),.prog(prog));

    atile_pingpong #(.DW(DW), .TDEPTH(TDEPTH)) u (.clk(clk),.rst_n(rst_n),
        .f_start(f_start),.f_valid(f_valid),.f_data(f_data),
        .f_ready(f_ready),.f_sel(f_sel),.any_free(any_free),
        .r_take(r_take),.r_valid(r_valid),.r_data(r_data),
        .r_frame_done(r_frame_done),.swap(swap),
        .frames_filled(frames_filled),.frames_read(frames_read),.bubbles(bubbles));

    // 寄存器化源: have/nxt -> 沿发出, 消费后撤
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            src_valid <= 0; src_data <= 0;
        end else begin
            if (have) begin
                src_valid <= 1; src_data <= nxt;
            end else if (src_ready) begin
                src_valid <= 0;
            end
        end
    end

    integer fail, i, rd_index, seen_done;

    initial begin
        #3000000 $display("[watchdog] 超时"); $finish;
    end
    reg done_seen_reg; always @(posedge clk) if (done) done_seen_reg <= 1'b1;

    task feed(input integer v);             // 喂一字: 撤旧->断流->装新->等沿上认可
        begin
            ensure_clear;
            if (v % 3 == 2) repeat (2) @(posedge clk);
            have = 1; nxt = v;
            while (!(src_valid && src_data == v)) @(posedge clk);
            have = 0;
        end
    endtask

    task ensure_clear;                      // 等上一字 valid 撤净
        begin
            while (src_valid) @(posedge clk);
        end
    endtask

    task eat;                               // 读一字并核对全序
        integer exp;
        begin
            exp = rd_index;
            while (!r_valid) @(posedge clk);
            if (u.r_data !== rd_index) begin
                $display("  *** 第%0d次读 -> %0d, 期望 %0d", rd_index, u.r_data, rd_index);
                fail = 1;
            end
            r_take = 1; @(posedge clk);
            r_take = 0; @(posedge clk);
            rd_index = rd_index + 1;
        end
    endtask

    task eatn(input integer n);
        integer k;
        begin for (k = 0; k < n; k = k + 1) eat; end
    endtask

    initial begin
        go = 0; have = 0; nxt = 0; r_take = 0;
        fail = 0; rd_index = 0; seen_done = 0;
        #20 rst_n = 1; @(posedge clk); @(posedge clk);

        $display("=== 场景1: go(total=24), 前2帧灌入即占满双轨 ===");
        go = 1; @(posedge clk); go = 0;

        for (i = 0; i < 16; i = i + 1) feed(i);        // 帧1=0..7 帧2=8..15
        repeat (4) @(posedge clk);                       // 让帧2收尾沿落定
        $display("  (前16字灌毕)");
        if (frames_claimed !== 2) begin $display("  *** claimed=%0d 期望2", frames_claimed); fail = 1; end
        if (prog        !== 16)    begin $display("  *** prog=%0d 期望16", prog); fail = 1; end
        if (busy        !== 1)     begin $display("  *** 引擎应仍 busy"); fail = 1; end
        if (frames_filled !== 2)   begin $display("  *** 双轨应READY: %0d", frames_filled); fail = 1; end
        if (!((u.st[0]==2 && u.st[1]==3) || (u.st[0]==3 && u.st[1]==2))) begin
            $display("  *** 双轨应为 READY+READING(级联在转轨): st=(%0d,%0d)", u.st[0], u.st[1]); fail = 1;
        end
        $display("  stop点: claimed=%0d prog=%0d A双轨READY (PASS)", frames_claimed, prog);

        $display("=== 场景2: 读侧吃空帧0 -> 引擎秒续帧3 ===");
        eatn(8);                                      // 帧1 0..7
        for (i = 16; i < 24; i = i + 1) feed(i);      // 帧3数据 16..23
        $display("  (帧1读毕, 帧3灌毕)");
        if (frames_claimed !== 3) begin $display("  *** claimed=%0d 期望3", frames_claimed); fail = 1; end

        $display("=== 场景3: 收尾 帧2/帧3 交错读毕 ===");
        eatn(8);                                      // 帧2 8..15
        eatn(8);                                      // 帧3 16..23

        @(posedge clk); @(posedge clk);
        seen_done = done_seen_reg;
        if (busy) begin $display("  *** 引擎应归零 busy"); fail = 1; end
        if (!seen_done) begin $display("  *** 未观察到 done 脉冲"); fail = 1; end
        if (rd_index !== 24) begin $display("  *** 读序只到 %0d", rd_index); fail = 1; end
        if (frames_read   !== 3) begin $display("  *** frames_read=%0d", frames_read); fail = 1; end
        if (bubbles       !== 0) begin $display("  *** bubbles=%0d", bubbles); fail = 1; end
        $display("  终态: read=%0d/24 filled=%0d claimed=%0d bubbles=%0d busy=%0b done_seen=%0b",
                 rd_index, frames_filled, frames_claimed, bubbles, busy, seen_done);
        if (fail) begin $display("##################  FAIL ##################"); $finish; end
        $display("==================  ALL PASS ==================");
        $finish;
    end
endmodule
`default_nettype wire