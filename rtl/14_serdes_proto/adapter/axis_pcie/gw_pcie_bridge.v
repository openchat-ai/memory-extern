// ============================================================================
// gw_pcie_bridge.v — Gowin PCIe IP ↔ 通用协议内核 桥 (L1, 实例 B 高速纵深)
//
// 高速 PCIe 路径 (对应 GW5AST-138 板上 x4 lane @ 5G = 20Gbps 金手指):
//
//       主机 ──PCIe──> gowin_pcie_ip ──M_AXIS──> 本桥 ──> proto_core
//                                     <──S_AXIS── 本桥 <── 载荷回程
//
// RX 方向: PCIe M_AXIS 帧(帧头+负载) → proto_core 统一流解码(nullptr 解析
//   cmd/seq/len, 载荷逐拍交付)。证明"通用协议内核直接吃 PCIe 流"。
// TX 方向: 载荷拍回程给 PCIe S_AXIS 回主机 (echo)。
//
// 帧格式(与 proto_core / pcie_dma_engine 同构):
//   拍0 帧头: [7:0]=cmd [15:8]=seq [23:16]=payload_len(字节)
//   拍1..N  : 负载, 每拍 AW/8 字节, tkeep 逐字节选通, tlast 标末拍
//
// 真实实现: gowin_pcie_ip 的 M_AXIS 直连本桥 pcie_rx_*, 本桥 pcie_tx_* 回连
// 其 S_AXIS。本桥 = 协议层对 PCIe 的唯一胶水, 无数据平面协议转换。
// ============================================================================

`timescale 1ns/1ps

module gw_pcie_bridge #(
    parameter AW     = 128,
    parameter SETTLE = 2
)(
    input  wire        clk,
    input  wire        rst_n,

    // ---- PCIe IP M_AXIS (主机→FPGA) ----
    input  wire [AW-1:0]     pcie_rx_tdata,
    input  wire [AW/8-1:0]  pcie_rx_tkeep,
    input  wire              pcie_rx_tvalid,
    output wire              pcie_rx_tready,
    input  wire              pcie_rx_tlast,

    // ---- PCIe IP S_AXIS (FPGA→主机 载荷回程) ----
    output wire [AW-1:0]      pcie_tx_tdata,
    output wire              pcie_tx_tvalid,
    input  wire              pcie_tx_tready,
    output wire [AW/8-1:0]  pcie_tx_tkeep,
    output wire              pcie_tx_tlast,

    // ---- 解码/状态 (供顶层映射到 BAR) ----
    output wire [7:0]       o_cmd,
    output wire [7:0]       o_seq,
    output wire             o_frame_done,
    output wire             o_frame_in_progress
);

    // ------------------------------------------------------------------------
    // 1) RX: PCIe 流 → proto_core 通用解码
    //    proto_core 的载荷出口直接作为回程 TX 流 (echo), 无额外缓冲。
    // ------------------------------------------------------------------------
    // 载荷出口 tready = 回程 TX 握手 (TX 空闲即可收, 单拍 echo)
    wire core_pv, core_pl;
    wire [AW-1:0]    core_pd;
    wire [AW/8-1:0]  core_pk;

    proto_core #(.DATAW(AW), .SETTLE_CYCLES(SETTLE)) u_core (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tvalid(pcie_rx_tvalid),  .s_axis_tready(pcie_rx_tready),
        .s_axis_tdata (pcie_rx_tdata),   .s_axis_tkeep(pcie_rx_tkeep),
        .s_axis_tlast (pcie_rx_tlast),
        .o_payload_tvalid(core_pv),      .o_payload_tready(pcie_tx_tready),
        .o_payload_tdata (core_pd),      .o_payload_tkeep(core_pk),
        .o_payload_tlast (core_pl),
        .o_cmd(o_cmd), .o_seq(o_seq),
        .o_frame_in_progress(o_frame_in_progress), .o_frame_done(o_frame_done)
    );

    // ------------------------------------------------------------------------
    // 2) TX: 载荷拍原样回程给 PCIe (echo 路径)
    //    当回程 TX 未就绪(被 PCIe 背压)时, proto_core 的 o_payload_tready 拉低,
    //    自动背压上游, 保证载荷不丢 —— 与 pcie_dma_engine 的 holding 语义一致。
    // ------------------------------------------------------------------------
    assign pcie_tx_tvalid = core_pv;
    assign pcie_tx_tdata  = core_pd;
    assign pcie_tx_tkeep  = core_pk;
    assign pcie_tx_tlast  = core_pl;

endmodule
