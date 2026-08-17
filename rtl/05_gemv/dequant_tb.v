`timescale 1ns/1ps
// dequant_tb.v — 04_dequant RTL 去量化验证（含边界：次正规/溢出/NAN scale）。
// 读 dq_packed.hex / dq_scale.hex / dq_expected.hex（C 参考生成），
// 每个打包字节 = 2 元素，nib_sel 0 后 1，逐位比对。
module dequant_tb;
    reg [7:0] pbyte, scale;
    reg nib_sel;
    wire [31:0] fp32;
    integer i, idx;
    integer errors = 0;
    reg [7:0] packed_v[0:8191];
    reg [7:0] scale_v[0:8191];
    reg [31:0] expected_v[0:16383];
    integer V;

    dequant dut (.pbyte(pbyte), .nib_sel(nib_sel), .scale(scale), .fp32(fp32));

    initial begin
        $readmemh("dq_packed.hex", packed_v);
        $readmemh("dq_scale.hex", scale_v);
        $readmemh("dq_expected.hex", expected_v);
        V = 16384;
        $display("=== dequant RTL vs C reference (%0d elements, incl. subnorm/ovf/NaN) ===", V);
        for (i = 0; i < V; i = i + 1) begin
            idx = i >> 1;
            pbyte = packed_v[idx];
            scale = scale_v[idx];
            nib_sel = i[0];
            #1;
            if (fp32 !== expected_v[i]) begin
                if (errors < 8)
                    $display("FAIL [%0d] pbyte=%02h s=%02h nib=%0d got=%08h exp=%08h",
                             i, pbyte, scale, i[0], fp32, expected_v[i]);
                errors = errors + 1;
            end
        end
        $display("dequant: %0d errors", errors);
        if (errors == 0) $display("=== ALL PASS ===");
        else $display("=== %0d ERROR(S) ===", errors);
        $finish;
    end
endmodule