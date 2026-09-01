// ============================================================================
// nvme_bridge.v — NVMe 对接桥(阶段 N6 核心, 物理无关, 纯仿真先行)
//
// 位置: 应用层(file2lba / cachectl_pipeline) 与 NVMe 协议层(nvme_host) 之间。
//   应用层给出"块级 LBA 请求"(读权重块 / 写回缓存块), 本桥逐块翻译成
//   nvme_host 的读/写命令, 处理 admin 握手 / 主机忙 / 完成 / 数据缓冲。
//
// 职责:
//   1. 请求下达(一次一块, 保序): 复位后等 host admin(NVMe Identify)完成, 之后
//      接待上层请求, 主机忙时 rq_ready=0 反压; 主机每完成一块回一个 done。
//   2. 数据通路(复用 nvme_data_fifo, 背压安全):
//       读: host.rd → 读FIFO → o_data/o_valid/o_ready(下游 GEMV/权重流)
//       写: i_data/i_valid(缓存更新源) → 写FIFO → host.wr(组合直通 tx_data 出设备)
//   3. 完成/错误: 每块完成回 done(1拍脉冲); 主机 err 则同样上报。
//
// 语义对齐: cachectl_pipeline 每"字"tag=文件块号, 组合给出其 wt_lba; 真机上
//   N6 把"每个文件块"按 wt_lba 发起一次 NVMe 读, 读回的权重流喂入 GEMV。
//   本桥以通用"块请求"协议呈现(每块一次 rq_valid+rq_lba+rq_len), 不写死
//   上游格式, 与 cachectl 逐字流的对接由上层分配器完成。
//
// 物理侧(rx/rx_cpl/tx_data/tx_cmd): 透传 nvme_host, 可接 nvme_device_model
//   (仿真)或真实物理适配器(PCIe硬核/自定义SerDes, 按 ARCHITECTURE §11.5
//   N4/N5 决定)。
// ============================================================================

`timescale 1ns/1ps

module nvme_bridge #(
    parameter LBAW  = 48,
    parameter BLKW  = 16,       // 请求块长度(字数)位宽
    parameter TAGW  = 4,
    parameter NQ    = 4,
    parameter DATAW = 32,
    parameter CMDW  = 32,
    parameter DFIFO = 8         // 两端数据 FIFO 深度(2 的幂)
)(
    input  wire clk, input wire rst_n,

    // ---- 应用层: 块请求接口(一次一块, 保序) ----
    input  wire            rq_valid,       // 请求一块
    input  wire            rq_is_read,     // 1=读, 0=写
    input  wire [LBAW-1:0] rq_lba,
    input  wire [BLKW-1:0] rq_len,         // 本块字数
    output wire            rq_ready,       // 已受理(反压: 主机忙/未就绪=0)
    output reg             done,           // 每块完成(1拍脉冲)
    output reg             err,            // 完成但主机报错(1拍脉冲)

    // ---- 数据通路 ----
    // 读路径输出(喂下游 GEMV / 权重流)
    output wire [DATAW-1:0] o_data, output wire o_valid, input wire o_ready,
    // 写路径输入(缓存更新源)
    input  wire [DATAW-1:0] i_data, input wire i_valid, output wire i_ready,

    // ---- 物理侧(透传 nvme_host, 接设备模型 / 真适配器) ----
    output wire [CMDW-1:0]  tx_cmd,      output wire tx_cmd_valid, input  wire tx_cmd_ready,
    input  wire [DATAW-1:0] rx_data,     input  wire rx_valid,     output wire rx_ready,
    output wire [DATAW-1:0] tx_data,     output wire tx_data_valid, input  wire tx_data_ready,
    input  wire [CMDW-1:0]  rx_cpl,      input  wire rx_cpl_valid,  output wire rx_cpl_ready
);

    // ---- nvme_host(协议层) ----
    wire h_busy, h_done, h_err;
    wire [CMDW-1:0]  h_tx_cmd;      wire h_tx_cmd_valid, h_tx_cmd_ready;
    wire [DATAW-1:0] h_rx_data;     wire h_rx_valid,     h_rx_ready;
    wire [DATAW-1:0] h_tx_data;     wire h_tx_data_valid, h_tx_data_ready;
    wire [CMDW-1:0]  h_rx_cpl;      wire h_rx_cpl_valid,  h_rx_cpl_ready;

    // 桥到 host 的请求/写口
    reg            req_r, is_read_r;
    reg [LBAW-1:0] lba_r;
    reg [BLKW-1:0] len_r;
    wire [DATAW-1:0] h_rd_data; wire h_rd_valid, h_rd_ready;
    wire             h_wr_ready, h_wr_valid;
    wire [DATAW-1:0] h_wr_data;

    nvme_host #(.CMDW(CMDW), .DATAW(DATAW), .LBAW(LBAW), .BLKW(BLKW),
                .NQ(NQ), .TAGW(TAGW)) u_host (
        .clk(clk), .rst_n(rst_n),
        .req(req_r), .is_read(is_read_r), .lba(lba_r), .blk_len(len_r),
        .busy(h_busy), .done(h_done), .err(h_err),
        .rd_data(h_rd_data), .rd_valid(h_rd_valid), .rd_ready(h_rd_ready),
        .wr_data(h_wr_data), .wr_valid(h_wr_valid), .wr_ready(h_wr_ready),
        .tx_cmd(h_tx_cmd), .tx_cmd_valid(h_tx_cmd_valid), .tx_cmd_ready(h_tx_cmd_ready),
        .rx_data(h_rx_data), .rx_valid(h_rx_valid), .rx_ready(h_rx_ready),
        .tx_data(h_tx_data), .tx_data_valid(h_tx_data_valid), .tx_data_ready(h_tx_data_ready),
        .rx_cpl(h_rx_cpl), .rx_cpl_valid(h_rx_cpl_valid), .rx_cpl_ready(h_rx_cpl_ready)
    );

    // ---- 请求下达 FSM (一次一块保序; admin 完成前不接待) ----
    // host 自动跑 admin(S_IDLE 优先分支), 未完成时桥若发 req 会被忽略还在
    // admin 握手 —— 所以先等 u_host.admin_ok 再放行请求。
    localparam S_WAIT_ADM = 0, S_IDLE = 1, S_ISSUE = 2, S_WAIT_CMP = 3;
    reg [1:0] st;

    always @(posedge clk) begin
        if (!rst_n) begin
            st <= S_WAIT_ADM;
            req_r <= 0; is_read_r <= 0; lba_r <= 0; len_r <= 0;
            done <= 0; err <= 0;
        end else begin
            done <= 0; err <= 0;
            case (st)
                S_WAIT_ADM: if (u_host.admin_ok) st <= S_IDLE;

                S_IDLE: begin
                    if (rq_valid && !h_busy) begin
                        is_read_r <= rq_is_read;
                        lba_r     <= rq_lba;
                        len_r     <= rq_len;
                        req_r     <= 1;
                        st        <= S_ISSUE;
                    end
                end

                S_ISSUE: begin
                    req_r <= 0;
                    st    <= S_WAIT_CMP;
                end

                S_WAIT_CMP: if (h_done) begin
                    done <= 1;
                    err  <= h_err;
                    st   <= S_IDLE;
                end
            endcase
        end
    end

    assign rq_ready = (st == S_IDLE) && !h_busy;

    // ---- 读路径: host.rd -> 读FIFO -> 下游 ----
    wire rf_wr_ready, rf_rd_valid;
    wire [DATAW-1:0] rf_out;
    nvme_data_fifo #(.DFIFO(DFIFO), .DATAW(DATAW)) u_rf (
        .clk(clk), .rst_n(rst_n),
        .wr_data(h_rd_data), .wr_valid(h_rd_valid), .wr_ready(rf_wr_ready),
        .rd_data(rf_out), .rd_valid(rf_rd_valid), .rd_ready(o_ready)
    );
    assign h_rd_ready = rf_wr_ready;
    assign o_data  = rf_out;
    assign o_valid = rf_rd_valid;

    // ---- 写路径: 上游 -> 写FIFO -> host.wr (组合直通 tx_data 出设备) ----
    wire wf_wr_ready, wf_rd_valid;
    wire [DATAW-1:0] wf_out;
    nvme_data_fifo #(.DFIFO(DFIFO), .DATAW(DATAW)) u_wf (
        .clk(clk), .rst_n(rst_n),
        .wr_data(i_data), .wr_valid(i_valid), .wr_ready(wf_wr_ready),
        .rd_data(wf_out), .rd_valid(wf_rd_valid), .rd_ready(h_wr_ready)
    );
    assign i_ready    = wf_wr_ready;
    assign h_wr_data  = wf_out;
    assign h_wr_valid = wf_rd_valid;

    // ---- 物理侧透传 ----
    assign tx_cmd            = h_tx_cmd;
    assign tx_cmd_valid      = h_tx_cmd_valid;
    assign h_tx_cmd_ready    = tx_cmd_ready;
    assign h_rx_data         = rx_data;
    assign h_rx_valid        = rx_valid;
    assign rx_ready          = h_rx_ready;
    assign tx_data           = h_tx_data;
    assign tx_data_valid     = h_tx_data_valid;
    assign h_tx_data_ready   = tx_data_ready;
    assign h_rx_cpl          = rx_cpl;
    assign h_rx_cpl_valid    = rx_cpl_valid;
    assign rx_cpl_ready      = h_rx_cpl_ready;

endmodule