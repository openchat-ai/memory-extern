`timescale 1ns/1ps
// bf16_add_tb — 对照 C 的 IEEE bf16 加法逐位验证（RN，含次正规/溢出/对消）
module bf16_add_tb;
    reg  [15:0] a, b;
    wire [15:0] s;

    bf16_add dut (.a(a), .b(b), .y(s));

    reg [15:0] av [0:30017];
    reg [15:0] bv [0:30017];
    reg [15:0] ev [0:30017];

    integer errors = 0, tested = 0, idx;
    integer total = 30018;

    initial begin
        $display("=== bf16_add testbench ===");
        $readmemh("bf16_pairs_a.hex", av);
        $readmemh("bf16_pairs_b.hex", bv);
        $readmemh("bf16_expected.hex", ev);
        for (idx = 0; idx < total; idx = idx + 1) begin
            a = av[idx]; b = bv[idx];
            #1;
            tested = tested + 1;
            if (s !== ev[idx]) begin
                if (errors < 15)
                    $display("FAIL #%0d: a=%04h b=%04h got=%04h want=%04h",
                             idx, a, b, s, ev[idx]);
                errors = errors + 1;
            end
        end
        $display("bf16_add: %0d 用例, %0d 错误", tested, errors);
        if (errors == 0) $display("=== ALL PASS ===");
        else $display("=== %0d ERROR(S) ===", errors);
        $finish;
    end
endmodule