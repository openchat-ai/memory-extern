`timescale 1ns/1ps
// 05_gemv — 测试台：数字外围 MAC，逐行与 C 黄金参考逐位比较。
// 数据来自 gen_fixture（真实 checkpoint 权重 × LCG 激活，ADC 12bit 量化）。
// 时序：go 拍喂第 0 组（q+scale），之后每拍喂一组，done 拍 y[r] 就绪。
module periph_mac_tb;
    localparam ROWS = 64;
    localparam NGRP = 112;

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
        $readmemh("q.hex",        qmem);
        $readmemh("scale.hex",    smem);
        $readmemh("expected.hex", expmem);
        $display("=== periph_mac testbench (rows=%0d, ngrp=%0d) ===", ROWS, NGRP);

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

        $display("periph_mac: %0d 行, %0d 错误", ROWS, errors);
        if (errors == 0) $display("=== ALL PASS ===");
        else $display("=== %0d ERROR(S) ===", errors);
        $finish;
    end

    always #5 clk = ~clk;
endmodule
