// ============================================================================
// links_detect.v — 双路径运行时自动识别 + 先到先得锁定
//
// 场景: 同一块 SSD 可物理插在 FPGA 板上 M.2(路径1/SerDes) 或 PC 主板 M.2
//       (路径2/PCIe)。本模块在复位后一次性探测两路就绪信号, "谁先就绪选谁",
//       锁定后不再复切 —— 与用户确认的语义一致。
//
// 就绪信号(两路物理互斥, 天然二选一):
//   align_a : 路径1 本地 SerDes 对齐(来自 serdes_phy_sfp 的 rx_ip_aligned)
//   link_b  : 路径2 主机 PCIe link-up(硬核 link status)
//
// 输出:
//   sel    : 0=路径1(本地 SerDes/M.2), 1=路径2(主机 PCIe/M.2)
//   locked : 1=已锁定(复位后首次锁存生效); 0=尚未探测到就绪(等待)
//   valid_a/valid_b : 当前两路就绪原样(供观测/复位期间防误选)
// ============================================================================

`timescale 1ns/1ps

module links_detect (
    input  wire clk,
    input  wire rst_n,

    // ---- 两路就绪探测输入(被动采样, 不驱动链路) ----
    input  wire align_a,     // 路径1: SerDes 是否对齐
    input  wire link_b,      // 路径2: PCIe 是否 link-up

    // ---- 选择输出 ----
    output reg  sel,         // 0=路径1, 1=路径2
    output reg  locked,      // 已锁定
    output wire valid_a,
    output wire valid_b
);

    assign valid_a = align_a;
    assign valid_b = link_b;

    // 先到先得: 复位后第一拍有两个中都锁, 否则等先就绪的那路。
    // 用 locked 位锁存一次, 之后不复切(即便另一路后来也就绪)。
    always @(posedge clk) begin
        if (!rst_n) begin
            sel    <= 1'b0;
            locked <= 1'b0;
        end else if (!locked) begin
            if (align_a && !link_b) begin
                sel    <= 1'b0;      // 仅路径1就绪
                locked <= 1'b1;
            end else if (link_b && !align_a) begin
                sel    <= 1'b1;      // 仅路径2就绪
                locked <= 1'b1;
            end else if (align_a && link_b) begin
                sel    <= 1'b0;      // 同时就绪 -> 默认路径1(本地优先)
                locked <= 1'b1;
            end
            // 都不就绪 -> 保持等待
        end
    end

endmodule
