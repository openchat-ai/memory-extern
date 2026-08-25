// ============================================================================
// pcie_dma_engine.v — PCIe DMA 权重流引擎（FPGA 侧框架）
//
// 职责：
//   1. 接收主机通过 PCIe BAR/DMA 下发的权重流（AXI-Stream 从接口）
//   2. 打成 SIMD 阵列需要的 lane 格式喂给 engine_core
//   3. 收集推理结果，经 AXI-Stream 主接口回传主机
//
// 设计约定：
//   - 权重协议：每拍 512 lane × 4bit 码 + valid（与 simd_mac_array 对齐）
//   - 一个"权重包" = NUM_LANES 个码；包间由 acc_clr 分隔推理轮次
//   - 结果回传：32bit sum + token 计数
//
// 与 Gowin PCIe IP 的对接点：
//   gowin_pcie_ip (AXI-Stream master/slave) ←→ 本模块 s_axis/m_axis
// ============================================================================

`timescale 1ns/1ps

module pcie_dma_engine #(
    parameter NUM_LANES  = 128,
    parameter ACC_WIDTH  = 32,
    // AXI-Stream 数据宽度：容纳 lane 码流 + 激活向量分帧
    // 取 128bit（PCIe Gen3 x4 TLP 友好），多拍拼一个 lane 帧
    parameter AXIS_WIDTH = 128
)(
    input  wire                     clk,
    input  wire                     rst_n,

    // ---- 主机 → FPGA（权重/命令）----
    input  wire                     s_axis_tvalid,
    output wire                     s_axis_tready,
    input  wire [AXIS_WIDTH-1:0]    s_axis_tdata,
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire [AXIS_WIDTH/8-1:0]  s_axis_tkeep,   // v0.1 忽略，v0.2 用于尾拍
    input  wire                     s_axis_tlast,   // v0.1 忽略
    /* verilator lint_on UNUSEDSIGNAL */

    // ---- FPGA → 主机（结果）----
    output reg                      m_axis_tvalid,
    input  wire                     m_axis_tready,
    output reg  [31:0]              m_axis_tdata,
    output reg                      m_axis_tlast,

    // ---- 引擎状态读出（可映射到 BAR 寄存器）----
    output reg  [31:0]              status_tokens,   // 已完成 token 数
    output wire                     engine_busy
);

    // ========================================================================
    // 帧格式定义（AXIS_WIDTH=128 时）：
    //
    //   拍 0        : [7:0]=cmd (0x01=推激活向量, 0x02=权重开始)
    //                 [15:8]=seq 序号
    //                 其余 = payload 前 14 字节
    //   拍 1..N     : payload 续
    //
    // 简化 v0.1：
    //   - 激活向量固定由内部寄存器提供（后续经 cmd 写入）
    //   - 权重码流直接透传给引擎
    // ========================================================================

    localparam CMD_PUSH_X     = 8'h01;   // 写激活向量
    localparam CMD_RUN_WEIGHT = 8'h02;   // 一帧权重
    // v0.2 预留：CMD_VERIFY_BATCH=0x03 —— 投机解码批量验证
    //   帧头后跟 k(1B)+保留(1B)+k×4B token_id；同一权重流服务 k 个激活
    //   路由并集预取由 RISC-V 固件计算（tools/spec_decode_harness.py）

    // ------------------------------------------------------------------
    // 激活寄存器组：NUM_LANES × int8
    // AXIS 128bit = 16 字节/拍 → 需要 ceil(1024/128)=8 拍装满 128 lane
    // ------------------------------------------------------------------
    localparam X_BEATS = (NUM_LANES*8) / AXIS_WIDTH;   // 8

    reg [NUM_LANES*8-1:0] x_reg;
    reg [$clog2(X_BEATS+1)-1:0] x_beat_cnt;
    reg [7:0] cur_cmd;

    assign s_axis_tready = 1'b1;   // v0.1 永远就绪（背压后续版本做）

    // ------------------------------------------------------------------
    // 接收解析 FSM
    // ------------------------------------------------------------------
    reg        wt_valid_q;
    reg [NUM_LANES*4-1:0] wt_lane_data;

    integer i;
    always @(posedge clk) begin
        if (!rst_n) begin
            x_reg        <= {(NUM_LANES*8){1'b0}};
            x_beat_cnt   <= 0;
            cur_cmd      <= 8'h00;
            wt_valid_q   <= 1'b0;
            wt_lane_data <= {(NUM_LANES*4){1'b0}};
        end else begin
            wt_valid_q <= 1'b0;

            if (s_axis_tvalid && s_axis_tready) begin
                if (x_beat_cnt == 0) begin
                    // 新帧头
                    cur_cmd <= s_axis_tdata[7:0];
                    if (s_axis_tdata[7:0] == CMD_PUSH_X)
                        x_beat_cnt <= {{($bits(x_beat_cnt)-1){1'b0}}, 1'b1};
                end else if (cur_cmd == CMD_PUSH_X) begin
                    // 激活载荷：每拍收 AXIS_WIDTH/8 个 int8
                    for (i = 0; i < AXIS_WIDTH/8; i = i + 1)
                        x_reg[x_beat_cnt*AXIS_WIDTH - AXIS_WIDTH + i*8 +: 8]
                            <= s_axis_tdata[i*8 +: 8];

                    if (x_beat_cnt == X_BEATS[$clog2(X_BEATS+1)-1:0])
                        x_beat_cnt <= {$bits(x_beat_cnt){1'b0}};
                    else
                        x_beat_cnt <= x_beat_cnt + 1'b1;
                end

                // 权重命令：帧头即载荷，码流从 byte2 开始（跳过 cmd+seq）
                // 单拍可容纳 (AXIS_WIDTH/8-2)*2 = 28 个 lane 码
                // 单拍帧：帧头当拍即载荷，需用当前拍的 cmd 匹配
                if ((cur_cmd == CMD_RUN_WEIGHT || s_axis_tdata[7:0] == CMD_RUN_WEIGHT)
                    && x_beat_cnt == 0) begin
                    wt_valid_q   <= 1'b1;
                    for (i = 0; i < NUM_LANES && i < (AXIS_WIDTH/8-2)*2; i = i + 1)
                        wt_lane_data[i*4 +: 4] <= s_axis_tdata[(i*4)+16 +: 4];
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // 推理引擎实例化
    // ------------------------------------------------------------------
    wire [ACC_WIDTH-1:0] sum_out;
    wire                 sum_valid;

    engine_core #(
        .NUM_LANES(NUM_LANES),
        .ACC_WIDTH(ACC_WIDTH)
    ) u_engine (
        .clk       (clk),
        .rst_n     (rst_n),
        .wt_valid  (wt_valid_q),
        .wt_data   (wt_lane_data),
        .x_data    (x_reg),
        .x_valid   (1'b1),          // 激活常驻寄存器
        .acc_clr   (~rst_n),
        .sum_out   (sum_out),
        .sum_valid (sum_valid),
        .busy      (engine_busy)
    );

    // ------------------------------------------------------------------
    // 结果回传：sum_valid → 一拍 AXIS 主事务
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            m_axis_tvalid <= 1'b0;
            m_axis_tdata  <= 32'd0;
            m_axis_tlast  <= 1'b0;
            status_tokens <= 32'd0;
        end else begin
            m_axis_tvalid <= 1'b0;
            m_axis_tlast  <= 1'b0;

            if (sum_valid && m_axis_tready) begin
                m_axis_tvalid <= 1'b1;
                m_axis_tdata  <= sum_out;
                m_axis_tlast  <= 1'b1;
                status_tokens <= status_tokens + 32'd1;
            end
        end
    end

endmodule
