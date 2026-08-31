// ============================================================================
// nvme_host.v — NVMe 主机协议层(物理无关, 阶段 N1)
//
// 把上层 ext4/file2lba 的 "读/写 LBA + 数据块" 翻译成本机 Admin/I/O 命令,
// 维护简洁命令队列状态, 经标准传输接口与物理适配器交换命令/完成/数据。
//
// 命令帧 tx_cmd[31:0](与设备模型对齐):
//   [7:0]   op     (01=ADMIN/Identify, 02=READ, 03=WRITE)
//   [11:8]  tag
//   [27:12] blk_len(块数)
//   [31:28] pat / lba 高位(读数据填充派生)
//
// 完成帧 rx_cpl[31:0]: [11:8]=tag, [7:0]=status(0=OK)。
//
// 数据通路: 上/下两级 valid/ready 直通(组合), 主机只计拍不缓存, 避免内部
// 寄存器握手引入 1 拍竞态。计拍用"当前级 valid 被消费级 accept 的那一拍"。
// 物理无关: 仅做协议形态, 门铃/队列指针参数化, 不绑定地址映射。
// ============================================================================

`timescale 1ns/1ps

module nvme_host #(
    parameter LBAW  = 48,
    parameter BLKW  = 16,
    parameter TAGW  = 4,
    parameter NQ    = 4,
    parameter DATAW = 32,
    parameter CMDW  = 32
)(
    input wire clk, input wire rst_n,

    // 上层命令接口
    input  wire            req,
    input  wire            is_read,
    input  wire [LBAW-1:0] lba,
    input  wire [BLKW-1:0] blk_len,
    output reg             busy, done, err,

    // 读数据出口
    output reg  [DATAW-1:0] rd_data, output reg rd_valid, input wire rd_ready,
    // 写数据入口
    input  wire [DATAW-1:0] wr_data, input wire wr_valid, output wr_ready,
    output reg  [CMDW-1:0]   tx_cmd, output reg tx_cmd_valid, input wire tx_cmd_ready,
    input  wire [DATAW-1:0]  rx_data, input wire rx_valid,  output rx_ready,
    output      [DATAW-1:0]  tx_data, output tx_data_valid, input wire tx_data_ready,
    input  wire [CMDW-1:0]   rx_cpl,  input wire rx_cpl_valid, output reg rx_cpl_ready
);

    localparam OP_ADMIN=8'h01, OP_READ=8'h02, OP_WRITE=8'h03;

    localparam S_IDLE=0, S_ADMIN=1, S_ADMIN_WAIT=2,
               S_CMD=3, S_CMDW=4, S_DATAW=5, S_DATAR=6, S_WAITC=7;
    reg [2:0] st;

    reg [TAGW-1:0]   tag;
    reg [BLKW-1:0]   blk_cnt;
    reg              is_read_q;
    reg [LBAW-1:0]   lba_q;
    reg              admin_ok;
    reg [TAGW-1:0]   q_head, q_tail;
    reg [NQ-1:0]     pend;

    // ---- 数据直通(组合): 当前级 valid/ready 由对端口决定 ----
    // 写: 上层 wr → tx 到设备;  读: 设备 rx → rd 到上层
    wire wr_accept  = wr_valid && tx_data_ready;
    // 读接受 = rx_valid && rd_ready(设备送、上层收)
    wire rd_accept  = rx_valid && rd_ready;

    always @(posedge clk) begin
        if (!rst_n) begin
            st <= S_IDLE;
            busy <= 0; done <= 0; err <= 0;
            tag <= 0; blk_cnt <= 0; is_read_q <= 0; lba_q <= 0;
            admin_ok <= 0; q_head <= 0; q_tail <= 0; pend <= 0;
            tx_cmd_valid <= 0; tx_cmd <= 0;
            rx_cpl_ready <= 0;
            rd_data <= 0; rd_valid <= 0;
        end else begin
            // 默认清脉冲
            done <= 0; err <= 0;
            rd_valid <= 0;
            tx_cmd_valid <= 0;
            rx_cpl_ready <= 0;

            case (st)
                S_IDLE: begin
                    if (!admin_ok) begin
                        tx_cmd <= OP_ADMIN;
                        tx_cmd_valid <= 1;
                        st <= S_ADMIN;
                    end else if (req) begin
                        busy <= 1;
                        is_read_q <= is_read;
                        lba_q <= lba;
                        blk_cnt <= blk_len;
                        tag <= q_tail;
                        pend[q_tail] <= 1;
                        q_tail <= q_tail + 1;
                        st <= S_CMD;
                    end
                end

                S_ADMIN: begin
                    if (tx_cmd_valid && tx_cmd_ready) begin
                        tx_cmd_valid <= 0;
                        st <= S_ADMIN_WAIT;
                    end
                end
                S_ADMIN_WAIT: begin
                    rx_cpl_ready <= 1;
                    if (rx_cpl_valid) begin
                        admin_ok <= 1;
                        busy <= 0; done <= 1;
                        st <= S_IDLE;
                    end
                end

                S_CMD: begin
                    tx_cmd <= { is_read_q ? lba_q[15:12] : 4'h0,
                                blk_cnt[15:0], tag, is_read_q ? OP_READ : OP_WRITE };
                    tx_cmd_valid <= 1;
                    st <= S_CMDW;
                end
                S_CMDW: begin
                    if (tx_cmd_valid && tx_cmd_ready) begin
                        tx_cmd_valid <= 0;
                        if (is_read_q) st <= S_DATAR;
                        else           st <= S_DATAW;
                    end
                end

                // ---- 写: 数据直通, 按设备接受拍计数 blk_cnt 拍 ----
                S_DATAW: begin
                    if (wr_accept) begin
                        blk_cnt <= blk_cnt - 1;
                        if (blk_cnt == 1) st <= S_WAITC;
                    end
                end

                // ---- 读: 设备 rx → 上层 rd(逐字寄存器脉冲) ----
                S_DATAR: begin
                    if (rx_valid && rx_ready) begin
                        rd_data  <= rx_data;
                        rd_valid <= 1;
                        blk_cnt <= blk_cnt - 1;
                        if (blk_cnt == 1) st <= S_WAITC;
                    end
                end

                S_WAITC: begin
                    rx_cpl_ready <= 1;
                    if (rx_cpl_valid) begin
                        busy <= 0;
                        if (rx_cpl[7:0] !== 8'd0) err <= 1; else done <= 1;
                        pend[q_head] <= 0;
                        q_head <= q_head + 1;
                        st <= S_IDLE;
                    end
                end

                default: st <= S_IDLE;
            endcase
        end
    end

    // ---- 组合直通 ----
    // 读: 仅 S_DATAR 接受设备数据
    assign rx_ready = (st == S_DATAR) ? rd_ready : 1'b0;
    // 写: 上层 wr → 设备 tx
    assign tx_data      = wr_data;
    assign tx_data_valid= (st == S_DATAW) ? wr_valid : 1'b0;
    assign wr_ready     = (st == S_DATAW) ? tx_data_ready : 1'b0;

endmodule
