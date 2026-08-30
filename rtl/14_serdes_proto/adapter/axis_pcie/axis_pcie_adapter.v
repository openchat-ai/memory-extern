// ============================================================================
// axis_pcie_adapter.v — AXI-Stream / PCIe 风格适配器 (L1, 实例 B)
//
// "透传"适配器: 模拟 PCIe IP(gowin_pcie_ip)的 AXI-Stream 出口, 把其原始
// AXI-Stream(帧头+负载, tlast 标尾) 原样透传给 proto_core 的统一流接口。
//
// 它存在的意义: 证明"既有 PCIe IP 的 AXI-Stream 能无缝接入本通用内核"。
// 实际在 138K 上, gowin_pcie_ip 出 s_axis 直接接 proto_core —— 此适配器
// 即那段"胶水"(复位同步/握手), 无额外协议转换。
// ============================================================================

`timescale 1ns/1ps

module axis_pcie_adapter #(
    parameter DATAW = 128
)(
    input  wire        clk,
    input  wire        rst_n,

    // ---- PCIe IP AXI-Stream 主接口(输入) ----
    input  wire        pcie_tvalid,
    output wire        pcie_tready,
    input  wire [DATAW-1:0] pcie_tdata,
    input  wire [DATAW/8-1:0] pcie_tkeep,
    input  wire        pcie_tlast,

    // ---- 统一流输出(接 proto_core) ----
    output wire        core_tvalid,
    input  wire        core_tready,
    output wire [DATAW-1:0] core_tdata,
    output wire [DATAW/8-1:0] core_tkeep,
    output wire        core_tlast,

    // ---- 状态 ----
    output reg         link_up           // 模拟 PCIe 链路训练完成(复位后起)
);

    // 本适配器为纯透传(无数据平面改动)
    assign core_tvalid = pcie_tvalid;
    assign pcie_tready = core_tready;
    assign core_tdata  = pcie_tdata;
    assign core_tkeep  = pcie_tkeep;
    assign core_tlast  = pcie_tlast;

    // 模拟链路训练: 复位释放后若干周期 link_up 置位
    reg [3:0] reset_cnt;
    always @(posedge clk) begin
        if (!rst_n) begin
            reset_cnt <= 4'd0;
            link_up   <= 1'b0;
        end else begin
            if (reset_cnt < 4'd10)
                reset_cnt <= reset_cnt + 4'd1;
            else
                link_up <= 1'b1;
        end
    end

endmodule
