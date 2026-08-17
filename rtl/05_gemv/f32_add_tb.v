`timescale 1ns/1ps
// f32_add_tb — 对照 C 的 IEEE fp32 加法逐位验证（RN，含次正规/溢出/对消）
module f32_add_tb;
    reg  [31:0] a, b;
    wire [31:0] s;

    f32_add dut (.a(a), .b(b), .y(s));

    reg [31:0] av [0:20021];
    reg [31:0] bv [0:20021];
    reg [31:0] ev [0:20021];

    integer errors = 0, tested = 0, idx;
    integer total = 20022;

    initial begin
        $display("=== f32_add testbench ===");
        $readmemh("add_pairs_a.hex", av);
        $readmemh("add_pairs_b.hex", bv);
        $readmemh("add_expected.hex", ev);
        for (idx = 0; idx < total; idx = idx + 1) begin
            a = av[idx]; b = bv[idx];
            #1;
            tested = tested + 1;
            if (s !== ev[idx]) begin
                if (errors < 15)
                    $display("FAIL #%0d: a=%08h b=%08h got=%08h want=%08h",
                             idx, a, b, s, ev[idx]);
                errors = errors + 1;
            end
        end
        $display("f32_add: %0d 用例, %0d 错误", tested, errors);
        if (errors == 0) $display("=== ALL PASS ===");
        else $display("=== %0d ERROR(S) ===", errors);
        $finish;
    end
endmodule
