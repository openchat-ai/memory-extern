// ============================================================================
// tb_pipe_vs_combo.v — 实验：验证打断关键路径后的流水版与原版功能等价
//
// 节拍约定：数据在 negedge 后设置并更新 ref；posedge 处数据已稳定，
//           DUT 上升沿采样累加，ref 同步对齐 —— 消除 #1 偏移的错位。
// ============================================================================

`timescale 1ns/1ps

module tb_pipe_vs_combo;

    localparam NUM_LANES = 128;
    localparam ACC_WIDTH = 32;
    localparam CLK_PERIOD = 5;   // 200MHz

    reg clk, rst_n, en;
    reg wt_valid, x_valid, acc_clr, acc_en;
    reg [NUM_LANES*4-1:0] wt_data;
    reg [NUM_LANES*8-1:0] x_data;

    wire [NUM_LANES*ACC_WIDTH-1:0] combo_out;
    wire combo_done;
    wire [NUM_LANES*ACC_WIDTH-1:0] pipe_out;
    wire pipe_done;

    simd_mac_array #(
        .NUM_LANES(NUM_LANES), .ACC_WIDTH(ACC_WIDTH)
    ) u_combo (
        .clk(clk), .rst_n(rst_n), .en(en),
        .wt_valid(wt_valid), .wt_data(wt_data), .wt_scale(8'h40),
        .x_data(x_data), .x_valid(x_valid),
        .acc_clr(acc_clr), .acc_en(acc_en),
        .acc_out(combo_out), .acc_done(combo_done)
    );

    simd_mac_array #(
        .NUM_LANES(NUM_LANES), .ACC_WIDTH(ACC_WIDTH), .PIPE_MUL(1)
    ) u_pipe (
        .clk(clk), .rst_n(rst_n), .en(en),
        .wt_valid(wt_valid), .wt_data(wt_data), .wt_scale(8'h40),
        .x_data(x_data), .x_valid(x_valid),
        .acc_clr(acc_clr), .acc_en(acc_en),
        .acc_out(pipe_out), .acc_done(pipe_done)
    );

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
    integer err_cvr, err_pvr, err_pvc;
    reg [3:0] rand_w [0:NUM_LANES-1];
    reg [7:0] rand_x [0:NUM_LANES-1];
    reg signed [31:0] ref_acc [0:NUM_LANES-1];
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
            // 在 negedge 后设置数据（posedge 前稳定）
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

    // 对采样后结果做一次全面比对
    task check_all;
        integer k;
        input [20:0] tag;
        begin
            for (k = 0; k < NUM_LANES; k = k + 1) begin
                if ($signed(combo_out[k*ACC_WIDTH +: ACC_WIDTH]) !== ref_acc[k]) begin
                    if (err_cvr < 4) $display("  tag%0d combo lane%0d DUT=%0d REF=%0d", tag, k, $signed(combo_out[k*ACC_WIDTH+:ACC_WIDTH]), ref_acc[k]);
                    err_cvr = err_cvr + 1;
                end
                if ($signed(pipe_out[k*ACC_WIDTH +: ACC_WIDTH]) !== ref_acc[k]) begin
                    if (err_pvr < 4) $display("  tag%0d pipe  lane%0d DUT=%0d REF=%0d", tag, k, $signed(pipe_out[k*ACC_WIDTH+:ACC_WIDTH]), ref_acc[k]);
                    err_pvr = err_pvr + 1;
                end
                if ($signed(pipe_out[k*ACC_WIDTH +: ACC_WIDTH]) !== $signed(combo_out[k*ACC_WIDTH +: ACC_WIDTH])) begin
                    if (err_pvc < 4) $display("  tag%0d pipe<>combo lane%0d pipe=%0d combo=%0d", tag, k, $signed(pipe_out[k*ACC_WIDTH+:ACC_WIDTH]), $signed(combo_out[k*ACC_WIDTH+:ACC_WIDTH]));
                    err_pvc = err_pvc + 1;
                end
            end
        end
    endtask

    initial begin
        $dumpfile("tb_pipe_vs_combo.vcd");
        $dumpvars(0, tb_pipe_vs_combo);

        $display("======================================================");
        $display(" 重定时打断关键路径 — 功能等价性实验 @ %0d MHz", 1000/CLK_PERIOD);
        $display("======================================================");

        do_reset();
        err_cvr = 0; err_pvr = 0; err_pvc = 0;
        for (i = 0; i < NUM_LANES; i = i + 1) ref_acc[i] = 0;

        // ---- 帧 1：5 拍 ----
        n_beats = 5;
        $display("\n[帧1] %0d 拍", n_beats);
        for (beat = 0; beat < n_beats; beat = beat + 1) begin
            gen_beat();
            drive_beat();   // 内含一个 @(posedge clk)
        end
        // 帧结束：撤 valid，等两版流水各自收敛到最终 acc
        @(negedge clk); wt_valid = 0; x_valid = 0;
        // 等足够多拍（pipe 比 combo 多 2 拍填充 → 多等一些拍再采样）
        repeat (20) @(posedge clk);
        check_all(1);

        // ---- 帧 2：25 拍（累积在前帧基础上？否——重新清零，单独帧）----
        // 重新清零 acc（acc_clr 高脉冲），分别重跑一个长帧
        $display("\n[帧2] 重新清零 + %0d 拍长帧", 25);
        @(negedge clk); acc_clr = 1;
        @(posedge clk);
        @(negedge clk); acc_clr = 0;
        for (i = 0; i < NUM_LANES; i = i + 1) ref_acc[i] = 0;
        for (beat = 0; beat < 25; beat = beat + 1) begin
            gen_beat();
            drive_beat();
        end
        @(negedge clk); wt_valid = 0; x_valid = 0;
        repeat (20) @(posedge clk);
        check_all(2);

        $display("\n======================================================");
        $display(" 汇总：combo-vs-ref=%0d  pipe-vs-ref=%0d  pipe-vs-combo=%0d", err_cvr, err_pvr, err_pvc);
        if (err_cvr==0 && err_pvr==0 && err_pvc==0)
            $display(" ✓✓ 流水版与原版 + 参考模型完全一致 → 打断关键路径功能等价");
        else
            $display(" ✗✗ 存在不一致，需排查");
        $display("======================================================");
        $finish;
    end

    initial begin
        #200000;
        $display("TIMEOUT!");
        $finish;
    end

endmodule
