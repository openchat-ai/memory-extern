`timescale 1ns/1ps
// tt_um_periph_mac.v — TinyTapeout 提交形态顶层封装（SkyWater 130nm）
//
// 演示内容：内存侧数字外围 periph_mac（f32_add + periph_scale + 跨组 fp32 累加），
// 逐位对齐设备 golden（pim_mxfp4_periph_acc）。
//
// 引脚/接口（TT 约定：ui 输入 / uo 输出）：
//   ui_in[0] : run 脉冲 —— 播放一行（NGRP 组）累加
//   ui_in[1] : select[0]
//   ui_in[2] : select[1]  —— 2-bit 行选择（0 空行 / 1 对消行 / 2 次正规混合行）
//   uo_out[3:0] : acc 的当前 nibble（nib_sel 轮转）
//   uo_out[4]   : done 脉冲
//   uo_out[5]   : 运行中
//   uo_out[7:6] : 组计数高两位（观察进度）
// 复位：rst_n 低有效
//
// 设计说明：periph_mac 的 FSM 在 go 之后 RUN 期间每周期消费一个 (q,scale)，
// 所以演示需要一个与累加节奏同步的 term 源。这里用 case 驱动的小表格
// （来自真实 edge fixture 的可复现数据），按组序号放出 term —— 门开销极小，
// 同时让累加器在真硅上跑通逐位契约。
module tt_um_periph_mac (
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

    // ---- 行表格：三行各 8 组 (q, scale)。源 = 已验证 edge fixture。----
    // 行 0：全 scale==255（跳过 → acc = +0，验证跳过路径）
    // 行 1：+1 -1 +1 -1 ...（对消 → +0，验证符号/对消）
    // 行 2：混合 +/- 与次正规（scale 偏低，验证次正规乘积路径，acc 非零）
    reg [31:0] q_t;
    reg [7:0]  sc_t;
    // 组索引 = 控制器计数器（go 拍 g=0 → 第 0 组；RUN 期间随 g 推进）。
    wire [2:0] g = row_g;
    always @(*) begin
        case ({sel, g})
            {2'd0, g[2:0]}: begin q_t = 32'h00000000; sc_t = 8'hFF; end
            {2'd1, 3'd0}: begin q_t = 32'h3F800000; sc_t = 8'h7F; end
            {2'd1, 3'd1}: begin q_t = 32'hBF800000; sc_t = 8'h7F; end
            {2'd1, 3'd2}: begin q_t = 32'h3F800000; sc_t = 8'h7F; end
            {2'd1, 3'd3}: begin q_t = 32'hBF800000; sc_t = 8'h7F; end
            {2'd1, 3'd4}: begin q_t = 32'h3F800000; sc_t = 8'h7F; end
            {2'd1, 3'd5}: begin q_t = 32'hBF800000; sc_t = 8'h7F; end
            {2'd1, 3'd6}: begin q_t = 32'h3F800000; sc_t = 8'h7F; end
            {2'd1, 3'd7}: begin q_t = 32'hBF800000; sc_t = 8'h7F; end
            {2'd2, 3'd0}: begin q_t = 32'h40200000; sc_t = 8'h7F; end  // 2.5
            {2'd2, 3'd1}: begin q_t = 32'hC0200000; sc_t = 8'h7F; end  // -2.5
            {2'd2, 3'd2}: begin q_t = 32'h40000001; sc_t = 8'h78; end  // 2.0, scale 2^-7
            {2'd2, 3'd3}: begin q_t = 32'h00000010; sc_t = 8'h78; end  // subnormal 小
            {2'd2, 3'd4}: begin q_t = 32'hC0000000; sc_t = 8'h7F; end  // -2.0
            {2'd2, 3'd5}: begin q_t = 32'h40800000; sc_t = 8'h7F; end  // 4.0
            {2'd2, 3'd6}: begin q_t = 32'h40400000; sc_t = 8'h7F; end  // 3.0
            {2'd2, 3'd7}: begin q_t = 32'hC0400000; sc_t = 8'h7F; end  // -3.0
            default: begin q_t = 32'h00000000; sc_t = 8'hFF; end
        endcase
    end

    // ---- 行控制器：run 上升沿启动一次；periph_mac 在 go 后自己走完 NGRP 组 ----
    reg        run_pp, row_active;
    reg [2:0]  row_g;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            run_pp    <= 1'b0;
            row_active <= 1'b0;
            row_g      <= 3'd0;
        end else begin
            run_pp  <= run;
            if (run && !run_pp) begin
                row_active <= 1'b1;     // run 上升沿：启动一行
                row_g      <= 3'd1;     // go 拍读组 0，首个 RUN 周期读组 1
            end else if (row_active) begin
                row_g <= row_g + 3'd1;  // RUN 周期逐组推进
            end else begin
                row_g <= 3'd0;
            end
            if (done) row_active <= 1'b0;     // 该行走完
        end
    end

    wire go = run && !run_pp;             // 一拍脉冲
    wire running = row_active;

    wire [31:0] acc;
    wire        done;
    periph_mac #(.NGRP(NGRP)) u_mac (
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
    wire [3:0] nib = nib_sel == 2'd0 ? acc[31:28]
                   : nib_sel == 2'd1 ? acc[27:24]
                   : nib_sel == 2'd2 ? acc[23:20]
                   :                   acc[19:16];

    assign uo_out = {g[2:1], running, done, nib};
endmodule