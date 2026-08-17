`timescale 1ns/1ps
// 05_gemv — 边界测试台：数字外围 MAC 的定向/随机边界用例。
// 覆盖真实 fixture 测不到路径（scale==255 跳过、±inf/NaN 累加传播、
// 次正规乘积、+0/-0、对消、累加溢出、负次正规符号）。
// expected 由 gen_mac_edge.c 调用 pim/mxfp4_gemv.c 的 C golden 算出。
module periph_mac_edge_tb;
    localparam ROWS = 48;
    localparam NGRP = 8;

    reg         clk = 0;
    reg         rst = 1;
    reg         go;
    reg  [31:0] q;
    reg  [7:0]  scale;
    wire [31:0] acc;
    wire        done;

    periph_mac #(.NGRP(NGRP)) dut (
        .clk(clk), .rst(rst), .go(go), .q(q), .scale(scale), .acc(acc), .done(done)
    );

    reg [31:0] qmem    [0:ROWS*NGRP-1];
    reg [7:0]  smem    [0:ROWS*NGRP-1];
    reg [31:0] expmem  [0:ROWS-1];

    integer errors = 0;

    initial begin
        $readmemh("edge_q.hex",        qmem);
        $readmemh("edge_scale.hex",    smem);
        $readmemh("edge_expected.hex", expmem);
        $display("=== periph_mac edge testbench (rows=%0d, ngrp=%0d) ===", ROWS, NGRP);

        repeat (2) @(posedge clk);
        rst = 0;
        #1;

        for (integer r = 0; r < ROWS; r = r + 1) begin
            go = 1;
            q = qmem[r*NGRP];
            scale = smem[r*NGRP];
            @(posedge clk);                    // go 拍：模块采样 go/q/scale
            #1;
            go = 0;
            for (integer g = 1; g < NGRP; g = g + 1) begin
                q = qmem[r*NGRP + g];
                scale = smem[r*NGRP + g];
                @(posedge clk);
                #1;
            end
            if (done !== 1'b1 || acc !== expmem[r]) begin
                $display("FAIL row=%0d: got=%08h want=%08h done=%b", r, acc, expmem[r], done);
                errors = errors + 1;
            end
            @(posedge clk);                    // 复位 done 脉冲
            #1;
        end

        $display("periph_mac(edge): %0d 行, %0d 错误", ROWS, errors);
        if (errors == 0) $display("=== ALL PASS ===");
        else $display("=== %0d ERROR(S) ===", errors);
        $finish;
    end

    always #5 clk = ~clk;
endmodule