`timescale 1ns/1ps
// py_run.v — 独立参考生成的用例，驱动 f32_add 逐位比对（自动生成）
module py_run;
    reg  [31:0] a, b;
    wire [31:0] s;
    f32_add dut (.a(a), .b(b), .y(s));
    parameter TOTAL = 1009963;
    reg [31:0] av [0:TOTAL-1];
    reg [31:0] bv [0:TOTAL-1];
    reg [31:0] ev [0:TOTAL-1];
    integer errors = 0, idx;
    initial begin
        $readmemh("py_a.hex", av);
        $readmemh("py_b.hex", bv);
        $readmemh("py_e.hex", ev);
        for (idx = 0; idx < TOTAL; idx = idx + 1) begin
            a = av[idx]; b = bv[idx];
            #1;
            if (s !== ev[idx]) begin
                if (errors < 15)
                    $display("FAIL #%0d: a=%08h b=%08h got=%08h want=%08h",
                             idx, a, b, s, ev[idx]);
                errors = errors + 1;
            end
        end
        $display("f32_add(indep): %0d 用例, %0d 错误", TOTAL, errors);
        if (errors == 0) $display("=== ALL PASS ===");
        else $display("=== %0d ERROR(S) ===", errors);
        $finish;
    end
endmodule
