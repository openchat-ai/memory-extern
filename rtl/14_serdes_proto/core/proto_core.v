// ============================================================================
// proto_core.v — 通用协议内核 (L2, 固定唯一)
//
// 从 pcie_dma_engine.v 抽离的"纯流式"接收内核。不关心上游是谁(自定义SerDes /
// PCIe / 10G网 …), 只认 AXI-Stream 接口。上游由"接口适配器"提供统一流。
//
// 帧格式(与 pcie_dma_engine.v 同构, 促进复用):
//   拍0 帧头: [7:0]=cmd  [15:8]=seq  [23:16]=payload_len(字节)
//   拍1..N  : 负载, 每拍 DATAW/8 字节, tkeep逐字节选通, tlast标末拍
//
// 行为约定:
//   - 帧头拍被内核消费(解码为 o_cmd/o_seq/length), 不转发给下游负载。
//   - payload 每拍以"单周期 tvalid 脉冲"交付给下游, 同时受 o_payload_tready 门控。
//   - 末拍给出 o_payload_tlast 与 o_frame_done 脉冲。
//   - 背压: S_SETTLE 期间 s_axis_tready=0 => 上游暂停; 保证帧不被打断。
//
// 参数化:
//   DATAW          : 流宽(一拍字节 = DATAW/8)
//   SETTLE_CYCLES  : 帧结束后背压周期数(给下游提交/settle; 0=不回弹直接 IDLE)
//
// 可扩展性: 命令表由上层/适配器定义, 本内核只做"帧头解码 + 搬运 + 节拍",
//   新增命令无需改动内核。
// ============================================================================

`timescale 1ns/1ps

module proto_core #(
    parameter DATAW         = 128,
    parameter SETTLE_CYCLES = 2
)(
    input  wire                  clk,
    input  wire                  rst_n,

    // ---- 上游: 任意接口适配器统一输出(标准 AXI-Stream) ----
    input  wire                  s_axis_tvalid,
    output wire                  s_axis_tready,
    input  wire [DATAW-1:0]     s_axis_tdata,
    input  wire [DATAW/8-1:0]   s_axis_tkeep,
    input  wire                  s_axis_tlast,

    // ---- 下游: 载荷逐拍交付(单周期 tvalid 脉冲) ----
    output reg                   o_payload_tvalid,
    input  wire                  o_payload_tready,
    output reg  [DATAW-1:0]     o_payload_tdata,
    output reg  [DATAW/8-1:0]   o_payload_tkeep,
    output reg                   o_payload_tlast,

    // ---- 帧级状态 ----
    output reg  [7:0]           o_cmd,
    output reg  [7:0]           o_seq,
    output reg                  o_frame_in_progress,
    output reg                  o_frame_done
);

    localparam S_IDLE    = 2'd0;
    localparam S_PAYLOAD = 2'd1;
    localparam S_SETTLE  = 2'd2;

    reg [1:0]  rx_state;
    reg [15:0] rem_bytes;
    reg [7:0]  settle_cnt;

    // 接收使能: settle 期间暂停; payload 期间需下游就绪才收
    assign s_axis_tready = (rx_state != S_SETTLE)
                         & ((rx_state != S_PAYLOAD) | o_payload_tready);

    wire header_beat  = (rx_state == S_IDLE)    && s_axis_tvalid && s_axis_tready;
    wire payload_beat = (rx_state == S_PAYLOAD) && s_axis_tvalid && s_axis_tready;
    wire frame_last   = (rem_bytes <= (DATAW/8)) || s_axis_tlast;

    always @(posedge clk) begin
        if (!rst_n) begin
            rx_state           <= S_IDLE;
            rem_bytes          <= 16'd0;
            settle_cnt         <= 8'd0;
            o_cmd              <= 8'd0;
            o_seq              <= 8'd0;
            o_payload_tvalid   <= 1'b0;
            o_payload_tdata    <= {DATAW{1'b0}};
            o_payload_tkeep    <= {(DATAW/8){1'b0}};
            o_payload_tlast    <= 1'b0;
            o_frame_in_progress<= 1'b0;
            o_frame_done       <= 1'b0;
        end else begin
            // 默认: 不拉 tvalid/tlast/done(每拍按需拉)
            o_payload_tvalid <= 1'b0;
            o_payload_tlast  <= 1'b0;
            o_frame_done     <= 1'b0;

            case (rx_state)
                S_IDLE: begin
                    if (header_beat) begin
                        o_cmd              <= s_axis_tdata[7:0];
                        o_seq              <= s_axis_tdata[15:8];
                        rem_bytes          <= s_axis_tdata[23:16];
                        rx_state           <= S_PAYLOAD;
                        o_frame_in_progress<= 1'b1;
                    end
                end

                S_PAYLOAD: begin
                    if (payload_beat) begin
                        // 交付一拍(单周期脉冲; 已满足下游就绪)
                        o_payload_tdata  <= s_axis_tdata;
                        o_payload_tkeep  <= s_axis_tkeep;
                        o_payload_tvalid <= 1'b1;

                        if (frame_last) begin
                            o_payload_tlast     <= 1'b1;
                            o_frame_done        <= 1'b1;
                            o_frame_in_progress <= 1'b0;
                            rem_bytes           <= 16'd0;
                            settle_cnt          <= 8'd0;
                            rx_state            <= (SETTLE_CYCLES>0) ? S_SETTLE : S_IDLE;
                        end else begin
                            rem_bytes <= rem_bytes - (DATAW/8);
                        end
                    end
                end

                S_SETTLE: begin
                    // 背压上游, 计满回 IDLE
                    if (settle_cnt >= SETTLE_CYCLES-1)
                        rx_state <= S_IDLE;
                    else
                        settle_cnt <= settle_cnt + 8'd1;
                end

                default: rx_state <= S_IDLE;
            endcase
        end
    end

endmodule
