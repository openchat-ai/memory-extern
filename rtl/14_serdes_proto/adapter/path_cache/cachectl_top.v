// ============================================================================
// cachectl_top.v — 缓存控制器骨架: 路径自动识别 + 统一权重流出口 + 命令来源可切
//
// 场景: 冷存储(HDD, 全量权重) + L2缓存(SSD, trunk + 每层激活专家, 动态更新)。
// SSD 可插 FPGA 板上 M.2(路径1/SerDes) 或 PC 主板 M.2(路径2/PCIe)。
//
// 本骨架验证三条"可自动切换"的关键链:
//   (1) links_detect  复位后探测两路就绪, 先到先得锁定(不复切)
//   (2) path_mux      按锁定路径选通统一权重流(wt_valid/wt_data/wt_ready)
//                     -> GEMV(engine_core) 全程无感知
//   (3) 命令统一      CMD_UPDATE_EXPERT 命令从任一路(本地/主机)进入, 经
//                     命令汇聚后一律触发专家更新 => "更新动作"来源可切
//
// 设计取舍:
//   - 权重流与命令流分离: 权重走 path_mux 直通; 命令走独立窄 cmd 通道,
//     避免"普通权重块"与"命令帧"在单流上混帧歧义。
//   - CMD_UPDATE_EXPERT 帧(任一物理来源):
//       帧头: [7:0]=cmd(0x40) [15:8]=seq [23:16]=payload_len(=1)
//       载荷: [7:0]=expert_id, [31:8]=新权重(简化单字), tlast 标尾
//   - trunk 视为永久驻留(冷数据由 HDD 提供, 不走路径流)。
// ============================================================================

`timescale 1ns/1ps

module cachectl_top #(
    parameter DW                  = 32,         // 权重流字位宽(GEMV wt_data)
    parameter CW                  = 32,         // 命令流字位宽
    parameter CMD_UPDATE_EXPERT   = 8'h40       // 专家更新命令
)(
    input  wire clk,
    input  wire rst_n,

    // ---- 两路就绪探测输入 ----
    input  wire serdes_aligned,    // 路径1: SerDes 对齐(SFP) -> 板上 M.2
    input  wire pcie_link_up,      // 路径2: PCIe link-up  -> 主机 M.2

    // ---- 路径1 外部字流(本地 SSD/NVMe 桩): 权重 ----
    input  wire [DW-1:0]  st_in_a_data,
    input  wire           st_in_a_valid,
    output wire           st_in_a_ready,

    // ---- 路径2 外部字流(主机 PCIe 下传桩): 权重 ----
    input  wire [DW-1:0]  st_in_b_data,
    input  wire           st_in_b_valid,
    output wire           st_in_b_ready,

    // ---- 命令流(独立窄通道, 任一物理来源可发) ----
    input  wire [CW-1:0]  cmd_a_data,
    input  wire           cmd_a_valid,
    output wire           cmd_a_ready,
    input  wire           cmd_a_last,

    input  wire [CW-1:0]  cmd_b_data,
    input  wire           cmd_b_valid,
    output wire           cmd_b_ready,
    input  wire           cmd_b_last,

    // ---- 统一权重流出口 -> GEMV ----
    output wire [DW-1:0]  wt_data,
    output wire           wt_valid,
    input  wire           wt_ready,

    // ---- 状态/调试 ----
    output wire           path_locked,     // 路径已锁定
    output wire           path_sel,        // 0=本地(路径1), 1=主机(路径2)
    output reg  [31:0]    expert_updates,  // 已处理 CMD_UPDATE_EXPERT 计数
    output reg  [7:0]     last_expert_id,
    output reg  [31:0]    last_src         // 最近一次更新的来源(0=本地,1=主机)
);

    // ================= 路径探测锁 =================
    wire sel, locked;
    links_detect u_detect (
        .clk(clk), .rst_n(rst_n),
        .align_a(serdes_aligned),
        .link_b (pcie_link_up),
        .sel(sel), .locked(locked),
        .valid_a(), .valid_b()
    );

    // ================= 权重: path_mux 选通统一出口 =================
    wire wtv_out;
    wire [DW-1:0] wtd_out;
    wire a_ready, b_ready;
    path_mux #(.DW(DW)) u_mux (
        .clk(clk), .rst_n(rst_n),
        .sel(sel), .locked(locked),
        .wtd_a(st_in_a_data), .wtv_a(st_in_a_valid), .wtr_a(a_ready),
        .wtd_b(st_in_b_data), .wtv_b(st_in_b_valid), .wtr_b(b_ready),
        .wt_valid(wtv_out), .wt_data(wtd_out), .wt_ready_gnv(wt_ready)
    );

    assign wt_valid = wtv_out;
    assign wt_data  = wtd_out;
    assign st_in_a_ready = a_ready;
    assign st_in_b_ready = b_ready;
    assign path_locked = locked;
    assign path_sel    = sel;

    // ================= 命令: 汇聚集 + 处理 =================
    //   两条物理来源命令流简单 OR-汇聚(物理互斥, 复位后同一时刻至多一路活跃),
    //   但其"可切住"体现在: 无论 cmd_a 还是 cmd_b, 都进入同一处理逻辑。
    //   命令帧 = 帧头字(cmd) + 单载荷字(expert_id)。固定两拍。
    reg [1:0] cmd_state;   // 0=IDLE,1=got_header
    reg [7:0] saved_cmd;

    localparam CS_IDLE=0, CS_HDR=1;

    wire cmd_any_valid = cmd_a_valid | cmd_b_valid;
    wire [CW-1:0] cmd_any_data = cmd_a_valid ? cmd_a_data : cmd_b_data;
    wire          cmd_any_src  = cmd_a_valid ? 1'b0       : 1'b1;   // 0=A,1=B

    assign cmd_a_ready = 1'b1;   // 窄命令流, 恒可收
    assign cmd_b_ready = 1'b1;

    always @(posedge clk) begin
        if (!rst_n) begin
            cmd_state       <= CS_IDLE;
            expert_updates  <= 0;
            last_expert_id  <= 0;
            last_src        <= 0;
            saved_cmd       <= 0;
        end else begin
            case (cmd_state)
                CS_IDLE: if (cmd_any_valid) begin
                    saved_cmd <= cmd_any_data[7:0];
                    cmd_state <= CS_HDR;
                end
                CS_HDR: begin
                    if (cmd_any_valid && saved_cmd == CMD_UPDATE_EXPERT) begin
                        last_expert_id <= cmd_any_data[7:0];
                        last_src       <= cmd_any_src;
                        expert_updates <= expert_updates + 1;
                    end
                    cmd_state <= CS_IDLE;
                end
            endcase
        end
    end

endmodule
