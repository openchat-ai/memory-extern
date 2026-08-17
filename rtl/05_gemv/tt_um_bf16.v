`timescale 1ns/1ps
// tt_um_bf16.v — TinyTapeout 提交形态（版本 B，流片目标）顶层封装
//
// 演示内容：跨组 bf16 累加 MAC（bf16_add + periph_scale_bf16），逐位对齐
// C 参考（pim_mxfp4_periph_acc 的 bf16 语义）。比版本 A（fp32）面积小 ~55%，
// 压进 1 tile（≤1000 cells），且贴合 MX 生态标准累加精度。
//
// 引脚（TT 约定：ui 输入 / uo 输出）：
//   ui_in[0] : run 脉冲 —— 播放一行（NGRP 组）累加
//   ui_in[1] : select[0]
//   ui_in[2] : select[1]  —— 2-bit 行选择（0 空行 / 1 对消行 / 2 混合行）
//   uo_out[3:0] : acc 的当前 nibble（nib_sel 轮转）
//   uo_out[4]   : done 脉冲
//   uo_out[5]   : 运行中
//   uo_out[7:6] : 组计数高两位（观察进度）
// 复位：rst_n 低有效
module tt_um_bf16 (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [7:0]  ui_in,
    output wire [7:0]  uo_out,
    input  wire [7:0]  uio_in,
    output wire [7:0]  uio_out,
    output wire [7:0]  uio_oe
);
    localparam NGRP = 8;

    assign uio_oe  = 8'h00;
    assign uio_out = 8'h00;

    wire run   = ui_in[0];
    wire [1:0] sel = ui_in[2:1];

    // ---- 行表格：三行各 8 组 (q, scale)。q 为 bf16 位模式。----
    // 行 0：全 scale==255（跳过 → acc = +0）
    // 行 1：+1 -1 +1 -1 ...（对消 → +0）
    // 行 2：混合 +/- 与次正规（acc 非零）
    reg [15:0] q_t;
    reg [7:0]  sc_t;
    wire [2:0] g = row_g;
    always @(*) begin
        case ({sel, g})
            {2'd0, g[2:0]}: begin q_t = 16'h0000; sc_t = 8'hFF; end
            {2'd1, 3'd0}: begin q_t = 16'h3F80; sc_t = 8'h7F; end  // 1.0
            {2'd1, 3'd1}: begin q_t = 16'hBF80; sc_t = 8'h7F; end  // -1.0
            {2'd1, 3'd2}: begin q_t = 16'h3F80; sc_t = 8'h7F; end
            {2'd1, 3'd3}: begin q_t = 16'hBF80; sc_t = 8'h7F; end
            {2'd1, 3'd4}: begin q_t = 16'h3F80; sc_t = 8'h7F; end
            {2'd1, 3'd5}: begin q_t = 16'hBF80; sc_t = 8'h7F; end
            {2'd1, 3'd6}: begin q_t = 16'h3F80; sc_t = 8'h7F; end
            {2'd1, 3'd7}: begin q_t = 16'hBF80; sc_t = 8'h7F; end
            {2'd2, 3'd0}: begin q_t = 16'h4020; sc_t = 8'h7F; end  // 2.5
            {2'd2, 3'd1}: begin q_t = 16'hC020; sc_t = 8'h7F; end  // -2.5
            {2'd2, 3'd2}: begin q_t = 16'h4000; sc_t = 8'h78; end  // 2.0, scale 2^-7
            {2'd2, 3'd3}: begin q_t = 16'h0010; sc_t = 8'h78; end  // subnormal
            {2'd2, 3'd4}: begin q_t = 16'hC000; sc_t = 8'h7F; end  // -2.0
            {2'd2, 3'd5}: begin q_t = 16'h4080; sc_t = 8'h7F; end  // 4.0
            {2'd2, 3'd6}: begin q_t = 16'h4040; sc_t = 8'h7F; end  // 3.0
            {2'd2, 3'd7}: begin q_t = 16'hC040; sc_t = 8'h7F; end  // -3.0
            default: begin q_t = 16'h0000; sc_t = 8'hFF; end
        endcase
    end

    // ---- 行控制器：run 上升沿启动一次；periph_mac_bf16 在 go 后自己走完 ----
    reg        run_pp, row_active;
    reg [2:0]  row_g;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            run_pp     <= 1'b0;
            row_active <= 1'b0;
            row_g      <= 3'd0;
        end else begin
            run_pp <= run;
            if (run && !run_pp) begin
                row_active <= 1'b1;
                row_g      <= 3'd1;
            end else if (row_active) begin
                row_g <= row_g + 3'd1;
            end else begin
                row_g <= 3'd0;
            end
            if (done) row_active <= 1'b0;
        end
    end

    wire go = run && !run_pp;
    wire running = row_active;

    wire [15:0] acc;
    wire        done;
    periph_mac_bf16 #(.NGRP(NGRP)) u_mac (
        .clk   (clk),
        .rst   (!rst_n),
        .go    (go),
        .q     (q_t),
        .scale (sc_t),
        .acc   (acc),
        .done  (done)
    );

    // ---- LED 呈现：done 后轮转 acc nibble + 状态 ----
    reg [1:0] nib_sel;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) nib_sel <= 2'd0;
        else if (done) nib_sel <= nib_sel + 2'd1;
    end
    wire [3:0] nib = nib_sel == 2'd0 ? acc[15:12]
                   : nib_sel == 2'd1 ? acc[11:8]
                   : nib_sel == 2'd2 ? acc[7:4]
                   :                   acc[3:0];

    assign uo_out = {g[2:1], running, done, nib};
endmodule