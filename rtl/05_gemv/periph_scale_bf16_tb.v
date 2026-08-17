`timescale 1ns/1ps
// periph_scale_bf16_tb — 对照 C 的 bf16 × 2^k 逐位验证（含次正规/溢出/0/inf/nan）
module periph_scale_bf16_tb;
    reg  [15:0] q;
    reg  [7:0]  sb;
    wire [15:0] p;

    periph_scale_bf16 dut (.q(q), .sb(sb), .p(p));

    reg [15:0] qv [0:12119];
    reg [7:0]  sv [0:12119];
    reg [15:0] ev [0:12119];

    integer errors = 0, tested = 0, idx;
    integer total = 12120;

    initial begin
        $display("=== periph_scale_bf16 testbench ===");
        $readmemh("bf16s_q.hex", qv);
        $readmemh("bf16s_sb.hex", sv);
        $readmemh("bf16s_exp.hex", ev);
        for (idx = 0; idx < total; idx = idx + 1) begin
            q = qv[idx]; sb = sv[idx];
            #1;
            tested = tested + 1;
            if (p !== ev[idx]) begin
                if (errors < 15)
                    $display("FAIL #%0d: q=%04h sb=%02h got=%04h want=%04h",
                             idx, q, sb, p, ev[idx]);
                errors = errors + 1;
            end
        end
        $display("periph_scale_bf16: %0d 用例, %0d 错误", tested, errors);
        if (errors == 0) $display("=== ALL PASS ===");
        else $display("=== %0d ERROR(S) ===", errors);
        $finish;
    end
endmodule