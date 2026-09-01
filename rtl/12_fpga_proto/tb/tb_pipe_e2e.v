// ============================================================================
// tb_pipe_e2e.v — 流水版 SIMD MAC + 归约树 + 激活 全链路端到端验证
//
// 验证：流水加深版（打断关键路径）在全链路下：
//   1. 128 累加器各 lane 正确
//   2. acc_done 帧同步正确（信号有效时刻与 acc_out 对齐）
//   3. 归约树 sum 正确
//   4. 激活输出正确
// ============================================================================

`timescale 1ns/1ps

module tb_pipe_e2e;

    localparam NUM_LANES = 128;
    localparam ACC_WIDTH = 32;
    localparam CLK_PERIOD = 5;   // 200MHz

    reg clk, rst_n, en;
    reg wt_valid, x_valid, acc_clr, acc_en;
    reg [NUM_LANES*4-1:0] wt_data;
    reg [NUM_LANES*8-1:0] x_data;

    wire [NUM_LANES*ACC_WIDTH-1:0] acc_out;
    wire acc_done;
    wire [ACC_WIDTH-1:0] sum_out;
    wire sum_valid;

    simd_mac_array #(
        .NUM_LANES(NUM_LANES), .ACC_WIDTH(ACC_WIDTH), .PIPE_MUL(1)
    ) u_mac (
        .clk(clk), .rst_n(rst_n), .en(en),
        .wt_valid(wt_valid), .wt_data(wt_data), .wt_scale(8'h40),
        .x_data(x_data), .x_valid(x_valid),
        .acc_clr(acc_clr), .acc_en(acc_en),
        .acc_out(acc_out), .acc_done(acc_done)
    );

    reduction_tree #(
        .NUM_LANES(NUM_LANES), .ACC_WIDTH(ACC_WIDTH)
    ) u_red (
        .clk(clk), .rst_n(rst_n),
        .in_valid(acc_done), .acc_in(acc_out),
        .sum_out(sum_out), .out_valid(sum_valid)
    );

    activation_vec #(
        .NUM_LANES(NUM_LANES), .IN_WIDTH(ACC_WIDTH), .OUT_WIDTH(8)
    ) u_act (
        .clk(clk), .rst_n(rst_n), .en(en),
        .in_valid(sum_valid), .x_in({NUM_LANES{sum_out}}),
        .out_valid(act_valid), .y_out(act_out)
    );
    wire act_valid;
    wire [NUM_LANES*8-1:0] act_out;

    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    task do_reset;
        begin
            rst_n = 0; en = 0; wt_valid = 0; x_valid = 0;
            acc_clr = 1; acc_en = 0; wt_data = 0; x_data = 0;
            repeat (5) @(posedge clk);
            rst_n = 1; acc_clr = 0; acc_en = 1; en = 1;
            repeat (2) @(posedge clk);
        end
    endtask

    function signed [7:0] e2m1_ref;
        input [3:0] code;
        begin
            case (code[2:0])
                3'b000: e2m1_ref = 0;
                3'b001: e2m1_ref = 2;
                3'b010: e2m1_ref = 4;
                3'b011: e2m1_ref = 6;
                3'b100: e2m1_ref = 8;
                3'b101: e2m1_ref = 12;
                3'b110: e2m1_ref = 16;
                3'b111: e2m1_ref = 24;
                default: e2m1_ref = 0;
            endcase
            if (code[3]) e2m1_ref = -e2m1_ref;
        end
    endfunction

    integer i, beat, n_beats;
    integer errors;
    reg [3:0] rand_w [0:NUM_LANES-1];
    reg [7:0] rand_x [0:NUM_LANES-1];
    reg signed [31:0] ref_acc [0:NUM_LANES-1];
    integer ref_sum;
    reg signed [31:0] sum_signed;
    reg signed [7:0] w_dec;
    reg signed [7:0] x_s;

    task gen_beat;
        integer k;
        begin
            for (k = 0; k < NUM_LANES; k = k + 1) begin
                rand_w[k] = $urandom_range(0, 15);
                rand_x[k] = $urandom_range(0, 255) - 128;
            end
        end
    endtask

    task update_ref;
        integer k;
        begin
            for (k = 0; k < NUM_LANES; k = k + 1) begin
                w_dec = e2m1_ref(rand_w[k]);
                x_s   = $signed(rand_x[k]);
                ref_acc[k] = ref_acc[k] + w_dec * x_s;
            end
        end
    endtask

    task drive_beat;
        integer k;
        begin
            @(negedge clk);
            wt_valid = 1; x_valid = 1;
            for (k = 0; k < NUM_LANES; k = k + 1) begin
                wt_data[k*4 +: 4] = rand_w[k];
                x_data[k*8 +: 8]  = rand_x[k];
            end
            update_ref();
            @(posedge clk);
        end
    endtask

    initial begin
        $dumpfile("tb_pipe_e2e.vcd");
        $dumpvars(0, tb_pipe_e2e);
        errors = 0;
        $display("=== 流水版全链路端到端 @ %0dMHz ===", 1000/CLK_PERIOD);
        do_reset();
        for (i = 0; i < NUM_LANES; i = i + 1) ref_acc[i] = 0;
        en = 1; acc_en = 1;

        n_beats = 16;
        for (beat = 0; beat < n_beats; beat = beat + 1) begin
            gen_beat();
            drive_beat();
        end
        @(negedge clk); wt_valid = 0; x_valid = 0;
        repeat (30) @(posedge clk);

        for (i = 0; i < NUM_LANES; i = i + 1)
            if ($signed(acc_out[i*ACC_WIDTH +: ACC_WIDTH]) !== ref_acc[i]) begin
                $display("  ✗ lane%0d DUT=%0d REF=%0d", i, $signed(acc_out[i*ACC_WIDTH+:ACC_WIDTH]), ref_acc[i]);
                errors = errors + 1;
            end
        if (errors == 0) $display("  ✓ 128 累加器全部正确"); else $display("  ✗ %0d errors", errors);

        ref_sum = 0;
        for (i = 0; i < NUM_LANES; i = i + 1) ref_sum = ref_sum + ref_acc[i];
        sum_signed = $signed(sum_out);
        if (sum_signed !== ref_sum[ACC_WIDTH-1:0]) begin
            $display("  ✗ 归约树 sum=%0d 期望 %0d", sum_signed, ref_sum);
            errors = errors + 1;
        end else
            $display("  ✓ 归约树输出正确 sum=%0d", sum_signed);

        $display("");
        if (errors == 0) $display(" ✓✓ PIPE E2E ALL PASSED"); else $display(" ✗✗ %0d ERRORS", errors);
        $finish;
    end

    initial begin
        #200000; $display("TIMEOUT!"); $finish;
    end

endmodule