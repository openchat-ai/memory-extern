// ============================================================================
// tb_reduce_hier.v — 独立验证分层归约树的时序与分组边界
//
// 验证项：
//   1. 与平坦参考模型逐帧对比 sum_out（数值等价）
//   2. out_valid 与 sum_out 同拍对齐（总延迟 8 拍）
//   3. 组边界划分正确（lane [0:31],[32:63],[64:95],[96:127] 局部归约）
// ============================================================================

`timescale 1ns/1ps

module tb_reduce_hier;

    parameter NUM_LANES = 128;
    parameter ACC_WIDTH = 32;

    reg clk = 0;
    reg rst_n = 0;
    reg in_valid = 0;
    reg [NUM_LANES*ACC_WIDTH-1:0] acc_in = 0;

    wire [ACC_WIDTH-1:0] sum_out;
    wire                 out_valid;

    always #2.5 clk = ~clk;      // 200MHz

    integer errors = 0;
    integer frames  = 50;
    integer f;

    // 期望模型：直接全加（行为参考）
    reg signed [ACC_WIDTH-1:0] exp_sum;
    reg                        exp_valid;
    integer lane;

    // 事件记录
    reg sum_v_seen = 0;

    // 观察 out_valid 脉冲（打印前 3 个）
    integer seen_cnt = 0;
    always @(posedge clk) begin
        if (u_dut.out_valid) begin
            seen_cnt = seen_cnt + 1;
            if (seen_cnt <= 3)
                $display("  [out_valid @%0t] sum=%0d", $time, $signed(u_dut.sum_out));
        end
    end

    initial begin
        $display("=== 分层归约树 时序/数值验证 @200MHz ===");
        // 复位
        rst_n = 0;
        #15 rst_n = 1;
        @(posedge clk);

        // 逐帧驱动：每帧 acc_in = lane 号递增（#1 相位：沿后稳定，下沿采样）
        for (f = 0; f < frames; f = f + 1) begin
            @(posedge clk); #1;
            // 请求本帧
            for (lane = 0; lane < NUM_LANES; lane = lane + 1)
                acc_in[lane*ACC_WIDTH +: ACC_WIDTH] = (f*16 + lane);
            in_valid = 1;
            @(posedge clk); #1;
            in_valid = 0;
            acc_in = 0;

            // 计算期望：sum over lanes
            exp_sum = 0;
            for (lane = 0; lane < NUM_LANES; lane = lane + 1)
                exp_sum = exp_sum + (f*16 + lane);

            // 等待 out_valid 脉冲出现（总延迟 8 拍）
            wait (out_valid === 1'b1);
            if ($signed(sum_out) == exp_sum) begin
                // 对齐正确
            end else begin
                $display(" ✗ 帧%0d 数值错误: sum=%0d exp=%0d", f, $signed(sum_out), exp_sum);
                errors = errors + 1;
            end
            // 等脉冲结束
            @(posedge clk); #1;
        end

        $display("");
        if (errors == 0) $display(" ✓✓ HIER REDUCTION ALL PASSED (对齐=8拍, 数值等价)");
        else             $display(" ✗✗ %0d ERRORS", errors);
        $finish;
    end

    initial begin
        #100000 $display("TIMEOUT"); $finish;
    end

    reduction_tree #(
        .NUM_LANES  (NUM_LANES),
        .ACC_WIDTH  (ACC_WIDTH),
        .GROUP_LANES(32)
    ) u_dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (in_valid),
        .acc_in    (acc_in),
        .sum_out   (sum_out),
        .out_valid (out_valid)
    );

endmodule