`timescale 1ns/1ps
module cache4_tb;
    reg clk = 0;
    reg rst_n = 0;
    reg req = 0;
    reg [7:0] addr = 0;
    wire hit;
    wire [31:0] hit_count, miss_count;

    cache4 dut (.clk(clk), .rst_n(rst_n), .req(req), .addr(addr),
                .hit(hit), .hit_count(hit_count), .miss_count(miss_count));

    always #5 clk = ~clk;

    integer errors = 0;

    // 驱动一次访问：摆输入 → 等一拍（#1 脱离时钟沿的那一拍）→ 等时钟沿 → 检查 hit
    // 教训：输入必须在两个时钟沿之间摆好，绝不能让 req/addr 和 posedge 落在同一拍，
    //       否则 DUT 会在你以为的"那一拍"之前就采样（本课踩中的第三个同款竞态）。
    task drive(input [7:0] a, input expect_hit);
        req = 1;
        addr = a;
        #1;                       // 摆完输入先走 1ns：确保脱离时钟沿那一拍
        @(posedge clk);
        #1;
        if (hit !== expect_hit) begin
            $display("FAIL: addr 0x%02x expect %0s got %0s", a,
                     expect_hit ? "hit" : "miss", hit ? "hit" : "miss");
            errors = errors + 1;
        end else
            $display("PASS: addr 0x%02x -> %0s", a, expect_hit ? "hit" : "miss");
        req = 0;
    endtask

    initial begin
        $display("=== cache4 testbench ===");
        repeat (2) @(posedge clk);
        rst_n = 1;
        @(posedge clk);          // 释放复位后空等一拍：让复位沿干净过去
        #1;
        req = 0;

        // 热身：填满 4 路（地址用 16 进制，位模式一眼可见）
        drive(8'h0A, 0);   // miss
        drive(8'h0B, 0);   // miss
        drive(8'h0C, 0);   // miss
        drive(8'h0D, 0);   // miss
        // 工作集 {0A,0B,0C,0D} 命中
        drive(8'h0A, 1);   // hit
        drive(8'h0B, 1);   // hit
        // 第 5 个地址 0E 进来 → 驱逐最久未用 → 造成震荡
        drive(8'h0E, 0);   // miss（驱逐 0C）
        drive(8'h0A, 1);   // hit（0A 还在）
        drive(8'h0B, 1);   // hit（0B 还在）
        drive(8'h0C, 0);   // miss（驱逐 0D）
        drive(8'h0D, 0);   // miss（驱逐 0E）

        // 计数核对：11 次访问 = 4 命中 + 7 缺失
        if (hit_count !== 32'd4) begin $display("FAIL: hit_count=%0d want 4", hit_count); errors = errors + 1; end
        else $display("PASS: hit_count = 4");
        if (miss_count !== 32'd7) begin $display("FAIL: miss_count=%0d want 7", miss_count); errors = errors + 1; end
        else $display("PASS: miss_count = 7");

        // 复位清计数
        rst_n = 0;
        @(posedge clk); #1;
        rst_n = 1;
        if (hit_count !== 0 || miss_count !== 0) begin
            $display("FAIL: reset did not clear counters");
            errors = errors + 1;
        end else
            $display("PASS: reset clears counters");

        if (errors === 0) $display("=== ALL PASS ===");
        else $display("=== %0d ERROR(S) ===", errors);
        $finish;
    end
endmodule
