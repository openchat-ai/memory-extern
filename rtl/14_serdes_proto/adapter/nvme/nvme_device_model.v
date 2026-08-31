// ============================================================================
// nvme_device_model.v — NVMe 设备行为模型(仿真桩, 模拟 M.2 SSD 端)
//
// 阶段 N1 仿真用: 接收 nvme_host 的命令/数据, 回完成, 为读命令返回数据块,
// 为写命令接收数据。data 通路用"消费端持续就绪 + 计数"的干净握手指南,
// 避免与主机组合直通的 1 拍竞态。
//
// tx_cmd_ready: 空闲期恒 1(主机发命令即收)。
// 读: rx_valid 持续置 1 送数据, 每被主机接受(rx_valid&&rx_ready)计一拍, 满 blk_len 回完成。
// 写: tx_data_ready 持续置 1, 每收一拍 tx_data_valid 计一拍, 满 blk_len 回完成。
// ============================================================================

`timescale 1ns/1ps

module nvme_device_model #(
    parameter LBAW  = 48,
    parameter DATAW = 32,
    parameter CMDW  = 32
)(
    input  wire clk,
    input  wire rst_n,

    // 命令通道(host -> 设备)
    input  wire [CMDW-1:0] tx_cmd,
    input  wire            tx_cmd_valid,
    output                 tx_cmd_ready,
    // 数据通道(host <-> 设备), 方向由命令决定
    output reg  [DATAW-1:0] rx_data, output reg rx_valid, input wire rx_ready,
    input  wire [DATAW-1:0] tx_data, input wire tx_data_valid, output reg tx_data_ready,
    // 完成通道(设备 -> host)
    output reg  [CMDW-1:0] rx_cpl, output reg rx_cpl_valid, input wire rx_cpl_ready
);

    localparam OP_ADMIN=8'h01, OP_READ=8'h02, OP_WRITE=8'h03;

    reg [7:0]  op;
    reg [3:0]  tag;
    reg [15:0] blk_len;
    reg [15:0] blk_cnt;
    reg        waiting_data;
    reg        data_dir;   // 1=read, 0=write
    reg [DATAW-1:0] pat;
    reg        cpl_pend;

    always @(posedge clk) begin
        if (!rst_n) begin
            rx_valid <= 0; rx_data <= 0;
            tx_data_ready <= 0; rx_cpl_valid <= 0; rx_cpl <= 0;
            op <= 0; tag <= 0; blk_len <= 0; blk_cnt <= 0;
            waiting_data <= 0; data_dir <= 0; pat <= 0; cpl_pend <= 0;
        end else begin
            // 默认
            rx_cpl_valid <= 0;

            if (!waiting_data) begin
                // 收命令(空闲期恒 ready, 由组合 assign 给出)
                if (tx_cmd_valid) begin
                    op      <= tx_cmd[7:0];
                    tag     <= tx_cmd[11:8];
                    blk_len <= tx_cmd[27:12];
                    case (tx_cmd[7:0])
                        OP_ADMIN: begin
                            rx_cpl <= {28'b0, 4'h0, 8'd0};
                            rx_cpl_valid <= 1;
                        end
                        OP_WRITE: begin
                            waiting_data <= 1; data_dir <= 0; blk_cnt <= tx_cmd[27:12];
                        end
                        OP_READ: begin
                            waiting_data <= 1; data_dir <= 1; blk_cnt <= tx_cmd[27:12];
                            pat <= {28'h0, tx_cmd[31:28]};
                            rx_data <= {28'h0, tx_cmd[31:28]} + tx_cmd[27:12];
                        end
                        default: begin
                            rx_cpl <= {28'b0, 4'h0, 8'hFF};
                            rx_cpl_valid <= 1;
                        end
                    endcase
                end
            end else if (data_dir) begin
                // 读: 每接收一拍递减, 并预生成下一个字(pat+blk_cnt), 消除 1 拍滞后
                rx_valid <= 1;
                if (rx_valid && rx_ready) begin
                    blk_cnt <= blk_cnt - 1;
                    rx_data  <= pat + (blk_cnt - 1);
                    if (blk_cnt == 1) cpl_pend <= 1;
                end
            end else begin
                // 写: 持续就绪, 每收一拍计数
                tx_data_ready <= 1;
                if (tx_data_valid) begin
                    blk_cnt <= blk_cnt - 1;
                    if (blk_cnt == 1) cpl_pend <= 1;
                end
            end

            // 完成脉冲(数据收/发完当下拖到下一拍送)
            if (cpl_pend) begin
                rx_cpl <= {28'b0, 4'h0, 8'd0};
                rx_cpl_valid <= 1;
                waiting_data <= 0;
                cpl_pend <= 0;
                rx_valid <= 0;
                tx_data_ready <= 0;
            end
        end
    end

    assign tx_cmd_ready = waiting_data ? 1'b0 : 1'b1;

endmodule
