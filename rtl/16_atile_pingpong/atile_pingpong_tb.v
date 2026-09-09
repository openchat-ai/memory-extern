`timescale 1ns/1ps
//────────────────────────────────────────────────────────────────────────────
// atile_pingpong_tb.v — A-tile 双缓冲 数据完整性测试
//   期望以 DUT 计数器 (frames_read, rwc) 为基准: DUT 读"帧F字K" -> 数据==F*1000+K。
//   P2 帧0 就绪即读 4 字          P3 rwx 并发窗口#1: 读帧0后半 ∧ 填帧1前半
//   P4 补填帧1 -> 读帧1, 再开 rwx 并发窗口#2: 读帧1后半 ∧ 填帧2, 收尾帧2
//   rwx: 同一 posedge 上 r_take ∧ f_valid 同高 (异轨读写真并发)
//────────────────────────────────────────────────────────────────────────────
module tb;
    localparam DW = 32, TDEPTH = 8;
    reg clk = 0, rst_n = 0; always #5 clk = ~clk;
    reg f_start, f_valid; reg [DW-1:0] f_data;
    wire f_ready, f_sel, any_free, r_valid, r_frame_done, swap;
    wire [DW-1:0] r_data;
    reg r_take;
    wire [31:0] frames_filled, frames_read, bubbles;

    atile_pingpong #(.DW(DW), .TDEPTH(TDEPTH)) u (.clk(clk),.rst_n(rst_n),
        .f_start(f_start),.f_valid(f_valid),.f_data(f_data),
        .f_ready(f_ready),.f_sel(f_sel),.any_free(any_free),
        .r_take(r_take),.r_valid(r_valid),.r_data(r_data),
        .r_frame_done(r_frame_done),.swap(swap),
        .frames_filled(frames_filled),.frames_read(frames_read),.bubbles(bubbles));

    integer fail, i;

    task wrw(input integer v);               // 单写一字
        begin
            while (!f_ready) @(posedge clk);
            f_valid = 1; f_data = v; @(posedge clk);
            f_valid = 0; @(posedge clk);
        end
    endtask

    task claim;                              // 开新帧(等 any_free)
        begin
            while (!any_free) @(posedge clk);
            f_start = 1; @(posedge clk); f_start = 0;
        end
    endtask

    task rwx(input integer v);               // 并发: 读一字 ∧ 写一字 (同拍)
        integer expf, expk;
        begin
            while (!r_valid) @(posedge clk);
            expf = u.frames_read; expk = u.rwc;
            if (u.r_data !== expf*1000 + expk) begin
                $display("  *** DUT读到 帧%0d字%0d -> %0d, 期望 %0d",
                         expf, expk, u.r_data, expf*1000 + expk);
                fail = 1;
            end
            if (!f_ready) begin
                $display("  *** rwx 写被拒: f_ready=0"); fail = 1;
            end
            r_take = 1; f_valid = 1; f_data = v; @(posedge clk);
            r_take = 0; f_valid = 0; @(posedge clk);
        end
    endtask

    task eat;                                // 单读一字
        integer expf, expk;
        begin
            while (!r_valid) @(posedge clk);
            expf = u.frames_read; expk = u.rwc;
            if (u.r_data !== expf*1000 + expk) begin
                $display("  *** DUT读到 帧%0d字%0d -> %0d, 期望 %0d",
                         expf, expk, u.r_data, expf*1000 + expk);
                fail = 1;
            end
            r_take = 1; @(posedge clk);
            r_take = 0; @(posedge clk);
        end
    endtask

    task blk_ck(input integer expf, input integer where);
        begin
            if (frames_read !== expf) begin
                $display("  *** [step%0d] 读帧数 %0d 期望 %0d", where, frames_read, expf);
                fail = 1;
            end
        end
    endtask

    initial begin
        f_start = 0; f_valid = 0; f_data = 0; r_take = 0;
        fail = 0;
        #20 rst_n = 1; @(posedge clk);
        @(posedge clk);

        //──── P1 空读冒泡 ────
        $display("P1) 空读冒泡 x3...");
        if (r_valid) begin $display("  *** 初始不该有帧"); fail = 1; end
        repeat (3) begin r_take = 1; @(posedge clk); r_take = 0; @(posedge clk); end
        if (bubbles != 3) begin
            $display("  *** bubbles=%0d 期望 3", bubbles); fail = 1;
        end else $display("  bubbles=%0d (PASS)", bubbles);

        //──── P2 填帧0, 读前半 ────
        $display("P2) 填帧0, 读4字...");
        claim;
        for (i = 0; i < TDEPTH; i = i + 1) wrw(i);        // f0 = 0..7
        for (i = 0; i < 4; i = i + 1) eat;                // 读 f0 w0..3

        //──── P3 并发窗口#1: 读f0后半 ∧ 填f1前半 ────
        $display("P3) rwx 并发#1: 读帧0剩余4字 ∧ 填帧1前4字...");
        claim;                                            // f1 -> 另一轨
        for (i = 0; i < 4; i = i + 1) rwx(1000 + i);
        blk_ck(1, 31);

        //──── P4 补填帧1, 读帧1, 并发窗口#2, 收尾帧2 ────
        $display("P4) 补填帧1后4字 -> 读帧1...");
        for (i = 4; i < TDEPTH; i = i + 1) wrw(1000 + i); // f1 = 1000..1007
        for (i = 0; i < 4; i = i + 1) eat;                // 读 f1 w0..3
        blk_ck(1, 41);
        $display("P4b) rwx 并发#2: 读帧1剩余4字 ∧ 填帧2前4字...");
        claim;                                            // f2 -> 又一轨
        for (i = 0; i < 4; i = i + 1) rwx(2000 + i);
        blk_ck(2, 42);                           // f1 读毕 -> fr 已达 3
        for (i = 4; i < TDEPTH; i = i + 1) wrw(2000 + i); // f2 = 2000..2007
        for (i = 0; i < TDEPTH; i = i + 1) eat;           // 读 f2 全帧

        //──── 总结算 ────
        @(posedge clk); @(posedge clk);
        if (frames_filled != 3 || frames_read != 3) begin
            $display("  *** 帧计数: 填=%0d 读=%0d 期望 3/3", frames_filled, frames_read);
            fail = 1;
        end
        if (r_valid) begin $display("  *** 末帧读毕后 r_valid 应熄"); fail = 1; end
        if (bubbles != 3) begin
            $display("  *** 气泡不应再涨: %0d", bubbles); fail = 1;
        end
        $display("  终态: frames_filled=%0d frames_read=%0d bubbles=%0d",
                 frames_filled, frames_read, bubbles);
        if (fail) begin $display("##################  FAIL ##################"); $finish; end
        $display("==================  ALL PASS ==================");
        $finish;
    end
endmodule
`default_nettype wire