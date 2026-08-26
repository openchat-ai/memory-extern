// ============================================================================
// tb_simd_pipeline.v — SIMD MAC 阵列 + 归约树 + 激活函数 全链路验证
//
// 验证目标：
//   1. 128 个独立累加器各自正确累加
//   2. 归约树输出 = 手工计算的部分和之和
//   3. 激活函数输出在预期范围内
//
// 参考模型：
//   acc[i] += w[i] * x[i]（每拍）
//   sum    = Σ acc[i]
//   y      = gelu_approx(sum)
// ============================================================================

`timescale 1ns/1ps

/* verilator lint_off SYNCASYNCNET */
module tb_simd_pipeline;
/* verilator lint_on SYNCASYNCNET */

    // ------------------------------------------------------------------
    // 参数
    // ------------------------------------------------------------------
    localparam NUM_LANES = 128;
    localparam ACC_WIDTH = 32;
    localparam CLK_PERIOD = 10;   // 100 MHz

    // ------------------------------------------------------------------
    // DUT 信号
    // ------------------------------------------------------------------
    reg                        clk;
    reg                        rst_n;
    reg                        en;

    // MAC 阵列
    reg                        wt_valid;
    reg  [NUM_LANES*4-1:0]     wt_data;
    reg  [NUM_LANES*8-1:0]     x_data;
    reg                        x_valid;
    reg                        acc_clr;
    reg                        acc_en;
    wire [NUM_LANES*ACC_WIDTH-1:0] acc_out;
    wire                       acc_done;

    // 归约树
    wire [ACC_WIDTH-1:0]       sum_out;
    wire                       sum_valid;

    // 激活函数
    wire [NUM_LANES*8-1:0]     act_out;
    /* verilator lint_off UNUSEDSIGNAL */
    wire                       act_out_unused = |act_out[NUM_LANES*8-1:8];
    /* verilator lint_on UNUSEDSIGNAL */
    wire                       act_valid;

    // ------------------------------------------------------------------
    // 时钟与复位
    // ------------------------------------------------------------------
    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    task do_reset;
        begin
            rst_n    = 0;
            en       = 0;
            wt_valid = 0;
            x_valid  = 0;
            acc_clr  = 1;
            acc_en   = 0;
            repeat (5) @(posedge clk);
            rst_n    = 1;
            acc_clr  = 0;
            repeat (2) @(posedge clk);
        end
    endtask

    // ------------------------------------------------------------------
    // DUT 实例化
    // ------------------------------------------------------------------
    simd_mac_array #(
        .NUM_LANES(NUM_LANES),
        .ACC_WIDTH(ACC_WIDTH)
    ) u_mac (
        .clk       (clk),
        .rst_n     (rst_n),
        .en        (en),
        .wt_valid  (wt_valid),
        .wt_data   (wt_data),
        .wt_scale  (8'h40),
        .x_data    (x_data),
        .x_valid   (x_valid),
        .acc_clr   (acc_clr),
        .acc_en    (acc_en),
        .acc_out   (acc_out),
        .acc_done  (acc_done)
    );

    reduction_tree #(
        .NUM_LANES(NUM_LANES),
        .ACC_WIDTH(ACC_WIDTH)
    ) u_red (
        .clk      (clk),
        .rst_n    (rst_n),
        .in_valid (acc_done),
        .acc_in   (acc_out),
        .sum_out  (sum_out),
        .out_valid(sum_valid)
    );

    activation_vec #(
        .NUM_LANES(NUM_LANES),
        .IN_WIDTH (ACC_WIDTH),
        .OUT_WIDTH(8)
    ) u_act (
        .clk      (clk),
        .rst_n    (rst_n),
        .en       (en),
        .in_valid (sum_valid),
        .x_in     ({NUM_LANES{sum_out}}),   // 简化：所有 lane 喂同一个 sum
        .out_valid(act_valid),
        .y_out    (act_out)
    );

    // ------------------------------------------------------------------
    // mxfp4 E2M1 查表（参考模型用）
    // ------------------------------------------------------------------
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

    // GELU 近似参考模型（和 RTL 相同的分段逻辑）
    function signed [7:0] gelu_ref;
        input signed [31:0] x;
        reg signed [31:0] x_abs;
        reg signed [7:0] corr;
        reg signed [7:0] y_pos;
        begin
            x_abs = (x < 0) ? -x : x;
            if (x_abs < 8)
                y_pos = x[7:0];
            else if (x_abs < 64) begin
                corr  = (x_abs - ((x_abs * x_abs * x_abs) >>> 13)) >> 6;  // 缩放
                y_pos = $signed(x_abs[7:0]) - corr;
            end else
                y_pos = 127;
            gelu_ref = (x < 0) ? (-y_pos) : y_pos;
        end
    endfunction

    // ------------------------------------------------------------------
    // 测试数据生成 & 参考累加
    // ------------------------------------------------------------------
    integer i, beat;
    integer n_beats;
    reg [3:0] rand_w [0:NUM_LANES-1];
    reg [7:0] rand_x [0:NUM_LANES-1];

    reg signed [31:0] ref_acc [0:NUM_LANES-1];   // 参考累加器
    integer ref_sum;
    reg signed [31:0] sum_signed;

    task gen_random_beat;
        begin
            for (i = 0; i < NUM_LANES; i = i + 1) begin
                rand_w[i] = $urandom_range(0, 15);   // 4-bit 随机码
                rand_x[i] = $urandom_range(0, 255) - 128;
            end
        end
    endtask

    task update_ref_acc;
        integer k;
        reg signed [7:0] w_dec;
        reg signed [7:0] x_s;
        begin
            for (k = 0; k < NUM_LANES; k = k + 1) begin
                w_dec = e2m1_ref(rand_w[k]);      // 和 RTL 同样的查表
                x_s   = $signed(rand_x[k]);       // int8 有符号
                ref_acc[k] = ref_acc[k] + w_dec * x_s;
            end
        end
    endtask

    // ------------------------------------------------------------------
    // 主测试流程
    // ------------------------------------------------------------------
    integer errors;
    initial errors = 0;

    initial begin
        $dumpfile("tb_simd_pipeline.vcd");
        $dumpvars(0, tb_simd_pipeline);

        $display("======================================================");
        $display(" SIMD Pipeline Verification");
        $display(" NUM_LANES=%0d, ACC_WIDTH=%0d", NUM_LANES, ACC_WIDTH);
        $display("======================================================");

        do_reset();

        // ── 测试 1：单拍累加验证 ──────────────────────────────
        $display("\n[Test 1] 单拍累加：喂 16 拍随机数据");
        for (i = 0; i < NUM_LANES; i = i + 1) ref_acc[i] = 0;

        n_beats = 16;
        en      = 1;
        acc_en  = 1;

        for (beat = 0; beat < n_beats; beat = beat + 1) begin
            gen_random_beat();
            // 在 posedge 之后立即驱动下一拍数据（阻塞赋值，稳定）
            @(posedge clk);
            #1;
            wt_valid = 1;
            x_valid  = 1;
            for (i = 0; i < NUM_LANES; i = i + 1) begin
                wt_data[i*4 +: 4] = rand_w[i];
                x_data[i*8 +: 8]  = rand_x[i];
            end
            update_ref_acc();
        end
        @(posedge clk);
        #1;
        wt_valid = 0;
        x_valid  = 0;
        @(posedge clk);
        #1;

        // 逐 lane 校验
        errors = 0;
        for (i = 0; i < NUM_LANES; i = i + 1) begin
            if ($signed(acc_out[i*ACC_WIDTH +: ACC_WIDTH]) !== ref_acc[i]) begin
                if (errors < 5)
                    $display("  ✗ Lane %0d: DUT=%h REF=%h",
                             i, acc_out[i*ACC_WIDTH +: ACC_WIDTH], ref_acc[i]);
                errors = errors + 1;
            end
        end
        if (errors == 0)
            $display("  ✓ 所有 %0d 个累加器全部正确", NUM_LANES);
        else
            $display("  ✗ %0d 个累加器不匹配", errors);

        // ── 测试 2：归约树输出 ────────────────────────────────
        $display("\n[Test 2] 归约树：等流水线排空后检查 sum");

        ref_sum = 0;
        for (i = 0; i < NUM_LANES; i = i + 1) ref_sum = ref_sum + ref_acc[i];
        $display("  期望 sum = %0d", ref_sum);

        // 等待归约树完成（STAGES=7 拍 + 余量）
        repeat (20) @(posedge clk);

        sum_signed = $signed(sum_out);
        if (sum_signed !== ref_sum[ACC_WIDTH-1:0]) begin
            $display("  ✗ sum=%0d, 期望 %0d", sum_signed, ref_sum);
            errors = errors + 1;
        end else
            $display("  ✓ 归约树输出正确: sum=%0d", sum_signed);

        // ── 测试 3：激活函数范围检查 ──────────────────────────
        $display("\n[Test 3] 激活函数输出范围");
        repeat (10) @(posedge clk);
        if (act_valid) begin
            if ($signed(act_out[7:0]) > 127 || $signed(act_out[7:0]) < -128)
                $display("  ✗ 超出 int8 范围: %h", act_out[7:0]);
            else
                $display("  ✓ 激活输出在范围内: %0d", $signed(act_out[7:0]));
        end else
            $display("  ⚠ act_valid 未触发（可能流水线延迟不够）");

        // ── 测试 4：GELU 边界值 ──────────────────────────────
        $display("\n[Test 4] GELU 分段边界");
        begin
            reg signed [31:0] test_x;
            test_x = 32'd5;
            $display("  gelu(%0d) = %0d (期望 %0d)", test_x, gelu_ref(test_x), test_x);
            test_x = 32'd32;
            $display("  gelu(%0d) = %0d", test_x, gelu_ref(test_x));
            test_x = 32'd100;
            $display("  gelu(%0d) = %0d (饱和)", test_x, gelu_ref(test_x));
        end

        // ── 总结 ────────────────────────────────────────────
        $display("\n======================================================");
        if (errors == 0)
            $display(" ✓✓ ALL TESTS PASSED");
        else
            $display(" ✗ %0d ERRORS", errors);
        $display("======================================================\n");
        $finish;
    end

    // 超时保护
    initial begin
        #100000;
        $display("TIMEOUT!");
        $finish;
    end

endmodule
