`timescale 1ns/1ps
// 02_lru — 测试台：2 路 LRU 命中/替换方向验证。
// 范式：`$monitor` + 逐拍断言。req/tag 在 posedge 后 #1 摆好，下一拍检查 hit/way。
module lru2_tb;
    reg clk = 0;
    reg rst = 1;
    reg req;
    reg we;
    reg [7:0] tag;
    wire hit;
    wire [1:0] way;

    lru2 #(.AW(8)) dut (.clk(clk), .rst(rst), .req(req), .we(we), .tag(tag),
                        .hit(hit), .way(way));

    integer errors = 0;

    // 任务：在一个非 posedge 时刻发一次访问，等一拍拿结果
    task access(input [7:0] t, input iswe);
        begin
            #1 req = 1; we = iswe; tag = t;
            @(posedge clk); #1;              // 组合输出在沿后稳定
            req = 0; we = 0;
        end
    endtask

    initial begin
        $display("=== 02_lru: 2-way LRU test ===");
        repeat (2) @(posedge clk);
        rst = 0;
        #1;

        // 1) 空表访问 A → miss，装入 way 0
        access(8'h11, 1);
        if (hit || way !== 2'd0) begin
            $display("FAIL t1 miss-A: hit=%b way=%d", hit, way); errors++;
        end

        // 2) 访问 B → miss，装入 way 1
        access(8'h22, 1);
        if (hit || way !== 2'd1) begin
            $display("FAIL t2 miss-B: hit=%b way=%d", hit, way); errors++;
        end

        // 3) 访问 A（MRU）→ 命中 way 0，A 保持 MRU
        access(8'h11, 0);
        if (!hit || way !== 2'd0) begin
            $display("FAIL t3 hit-A: hit=%b way=%d", hit, way); errors++;
        end

        // 4) 访问 C → miss，应替换 LRU 路（B，way1）
        access(8'h33, 1);
        if (hit || way !== 2'd1) begin
            $display("FAIL t4 miss-C evict-B: hit=%b way=%d", hit, way); errors++;
        end

        // 5) 访问 B → miss（已被换出），替换 LRU 路（A，way0）
        access(8'h22, 1);
        if (hit || way !== 2'd0) begin
            $display("FAIL t5 miss-B evict-A: hit=%b way=%d", hit, way); errors++;
        end

        // 6) 访问 B（MRU）→ 命中 way0
        access(8'h22, 0);
        if (!hit || way !== 2'd0) begin
            $display("FAIL t6 hit-B: hit=%b way=%d", hit, way); errors++;
        end

        $display("02_lru: %0d errors", errors);
        if (errors == 0) $display("=== ALL PASS ===");
        else $display("=== %0d ERROR(S) ===", errors);
        $finish;
    end

    always #5 clk = ~clk;
endmodule