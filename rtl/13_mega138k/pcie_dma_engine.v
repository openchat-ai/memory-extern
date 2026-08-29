// ============================================================================
// pcie_dma_engine.v — PCIe DMA 权重流引擎（FPGA 侧框架，v0.2 完整 FSM）
//
// 职责：
//   1. 接收主机通过 PCIe BAR/DMA 下发的权重流（AXI-Stream 从接口）
//   2. 打成 SIMD 阵列需要的 lane 格式喂给 engine_core
//   3. 收集推理结果，经 AXI-Stream 主接口回传主机
//
// 帧格式（AXIS_WIDTH=128 时，TLP 友好）：
//   拍 0（帧头）: [7:0]=cmd（0x01=推激活向量, 0x02=权重开始）
//                 [15:8]=seq 序号（v0.2 记录用，不参与校验）
//                 [23:16]=payload_len 负载字节数（= NUM_LANES 或 NUM_LANES*4/8）
//   拍 1..N     : 负载，每拍 AXIS_WIDTH/8 字节（tkeep 逐字节选通）
//
// 帧大小（默认 NUM_LANES=128）：
//   CMD_PUSH_X    : 帧头 + 8 拍（128 字节 int8 × 128 lane）
//   CMD_RUN_WEIGHT: 帧头 + 4 拍（64 字节 = 128 lane × 4bit 码）
//
// 时序保证：
//   - 权重帧结束进入 SETTLE（2 拍：acc_clr 先清、wt_valid 后发），
//     保证"清→装→累加"顺序，避免帧间污染
//   - SETTLE 期间 s_axis_tready=0，天然背压，主机暂停下一帧
//   - 结果输出为 holding 寄存器：sum_valid 到来时若无 m_axis_tready
//     则挂起等待，绝不丢结果；status_tokens 只统计"已产生"的结果
//
// 与 Gowin PCIe IP 的对接点：
//   gowin_pcie_ip (AXI-Stream master/slave) ←→ 本模块 s_axis/m_axis
// ============================================================================

`timescale 1ns/1ps

module pcie_dma_engine #(
    parameter NUM_LANES  = 128,
    parameter ACC_WIDTH  = 32,
    parameter AXIS_WIDTH = 128
)(
    input  wire                     clk,
    input  wire                     rst_n,

    // ---- 主机 → FPGA（权重/命令）----
    input  wire                     s_axis_tvalid,
    output wire                     s_axis_tready,
    input  wire [AXIS_WIDTH-1:0]    s_axis_tdata,
    input  wire [AXIS_WIDTH/8-1:0]  s_axis_tkeep,
    input  wire                     s_axis_tlast,

    // ---- FPGA → 主机（结果）----
    output reg                               m_axis_tvalid,
    input  wire                              m_axis_tready,
    output reg  [31:0]                       m_axis_tdata,
    output reg                               m_axis_tlast,

    // ---- 引擎状态读出（可映射到 BAR 寄存器）----
    output reg  [31:0]              status_tokens,
    output wire                     engine_busy
);

    // ==========================================================================
    // 帧大小派生（要求 AXIS_WIDTH 整除负载位数）
    // ==========================================================================
    localparam X_BYTES   = NUM_LANES * 1;                     // 128 byte int8
    localparam W_BYTES   = (NUM_LANES * 4) / 8;               // 64 byte lane 码
    localparam B_PER_X   = X_BYTES / (AXIS_WIDTH/8);          // 8 拍
    localparam B_PER_W   = W_BYTES / (AXIS_WIDTH/8);          // 4 拍
    localparam MAX_BEATS = B_PER_X > B_PER_W ? B_PER_X : B_PER_W;

    localparam CMD_PUSH_X     = 8'h01;
    localparam CMD_RUN_WEIGHT = 8'h02;

    // v0.2 预留：CMD_VERIFY_BATCH=0x03 —— 投机解码批量验证
    //   帧头后跟 k(1B)+保留(1B)+k×4B token_id；同一权重流服务 k 个激活

    // ==========================================================================
    // 接收 FSM
    // ==========================================================================
    localparam S_IDLE    = 2'd0;
    localparam S_PAYLOAD = 2'd1;
    localparam S_SETTLE  = 2'd2;

    reg [1:0]   rx_state;
    reg [7:0]   cur_cmd;
    reg [7:0]   cur_seq;
    reg [15:0]  rem_bytes;
    reg [7:0]   pay_beat;
    reg [1:0]   settle_cnt;

    // 激活寄存器组：NUM_LANES × int8
    reg [NUM_LANES*8-1:0] x_reg;

    // lane 码缓冲：NUM_LANES × 4bit（整帧装好后随 wt_valid 一次性交付）
    reg [NUM_LANES*4-1:0] wt_lane_data;
    reg                   wt_valid_q;
    reg                   acc_clr_q;

    // 接收背压：SETTLE 期间暂停上游，其余全速收
    assign s_axis_tready = (rx_state != S_SETTLE);

    integer ii;
    always @(posedge clk) begin
        if (!rst_n) begin
            rx_state <= S_IDLE;
            cur_cmd  <= 8'h00;
            cur_seq  <= 8'h00;
            rem_bytes<= 16'd0;
            pay_beat <= 8'd0;
            settle_cnt <= 2'd0;
            x_reg        <= {(NUM_LANES*8){1'b0}};
            wt_lane_data <= {(NUM_LANES*4){1'b0}};
            wt_valid_q   <= 1'b0;
            acc_clr_q    <= 1'b0;
        end else begin
            wt_valid_q <= 1'b0;
            acc_clr_q  <= 1'b0;

            case (rx_state)
                S_IDLE: begin
                    // 帧头拍：cmd / seq / len，本拍即被消费
                    if (s_axis_tvalid && s_axis_tready) begin
                        cur_cmd   <= s_axis_tdata[7:0];
                        cur_seq   <= s_axis_tdata[15:8];
                        rem_bytes <= s_axis_tdata[23:16];
                        pay_beat  <= 8'd0;
                        rx_state  <= S_PAYLOAD;
                    end
                end

                S_PAYLOAD: begin
                    if (s_axis_tvalid && s_axis_tready) begin
                        if (cur_cmd == CMD_PUSH_X) begin
                            // 激活负载：每拍 AXIS_WIDTH/8 个 int8，按 tkeep 选通
                            for (ii = 0; ii < AXIS_WIDTH/8; ii = ii + 1) begin
                                if (s_axis_tkeep[ii])
                                    x_reg[pay_beat*AXIS_WIDTH + ii*8 +: 8]
                                        <= s_axis_tdata[ii*8 +: 8];
                            end
                        end else if (cur_cmd == CMD_RUN_WEIGHT) begin
                            // lane 码负载：每拍 (AXIS_WIDTH/4) 个 4bit 码
                            for (ii = 0; ii < AXIS_WIDTH/8; ii = ii + 1) begin
                                if (s_axis_tkeep[ii]) begin
                                    wt_lane_data[(pay_beat*(AXIS_WIDTH/4) + ii*2)*4 +: 4]
                                        <= s_axis_tdata[ii*8 +: 4];
                                    wt_lane_data[(pay_beat*(AXIS_WIDTH/4) + ii*2 + 1)*4 +: 4]
                                        <= s_axis_tdata[ii*8+4 +: 4];
                                end
                            end
                        end

                        pay_beat <= pay_beat + 8'd1;

                        // 帧结束：按 len 或 tlast（取先到者）
                        if (rem_bytes <= (AXIS_WIDTH/8) || s_axis_tlast) begin
                            rem_bytes <= 16'd0;
                            if (cur_cmd == CMD_RUN_WEIGHT) begin
                                rx_state   <= S_SETTLE;  // 清→装→累加
                                settle_cnt <= 2'd0;      // 关键：确保 acc_clr/wt_valid 序列从头开始
                            end else
                                rx_state <= S_IDLE;     // 激活常驻，直接收下一帧
                        end else begin
                            rem_bytes <= rem_bytes - (AXIS_WIDTH/8);
                        end
                    end
                end

                S_SETTLE: begin
                    // 清 → 装 → 释放，2 拍序列；期间 tready=0 暂停上游
                    settle_cnt <= settle_cnt + 2'd1;
                    case (settle_cnt)
                        2'd0: acc_clr_q  <= 1'b1;   // 先清累加器
                        2'd1: wt_valid_q <= 1'b1;   // 后交付整帧 lane 码
                        default: rx_state <= S_IDLE;
                    endcase
                end

                default: rx_state <= S_IDLE;
            endcase
        end
    end

    // ==========================================================================
    // 推理引擎实例化
    // ==========================================================================
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
        .acc_clr   (acc_clr_q),
        .sum_out   (sum_out),
        .sum_valid (sum_valid),
        .busy      (engine_busy)
    );

    // ==========================================================================
    // 结果回传：holding producer —— sum_valid 到来即挂起，绝不丢结果
    // ==========================================================================
    always @(posedge clk) begin
        if (!rst_n) begin
            m_axis_tvalid <= 1'b0;
            m_axis_tdata  <= 32'd0;
            m_axis_tlast  <= 1'b0;
            status_tokens <= 32'd0;
        end else begin
            if (!m_axis_tvalid) begin
                if (sum_valid) begin
                    m_axis_tvalid <= 1'b1;
                    m_axis_tdata  <= sum_out;
                    m_axis_tlast  <= 1'b1;
                    status_tokens <= status_tokens + 32'd1;
                end
            end else if (m_axis_tready) begin
                m_axis_tvalid <= 1'b0;
            end
        end
    end

endmodule