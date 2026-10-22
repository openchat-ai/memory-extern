`timescale 1ns/1ps
`default_nettype none
//────────────────────────────────────────────────────────────────────────────
// uart_rx.v — 115200 8N1 字节接收器 (板级 UART 输入通道)
// 用途: PC 通过同一根 USB JTAG&UART 线给板子发命令 (board_decode_top 的 xext
//       覆盖 / 手动触发一帧)
// 采样: 起始位下降沿后过 DIV+HALF 确认起始位, 之后每个位时间中点采样
//       (中点采样比边沿采样抗抖动, 且省掉亚稳态处理)
// 输出: rd_valid 置起后等 rd_ready 才清 (握手式, 上层可慢慢取)
// 注: 代码风格按 Gowin 前端挑刺规避 (不用 SV 转换 N'(x); else 单独成行且带 begin/end)
//────────────────────────────────────────────────────────────────────────────
module uart_rx #(
    parameter CLK_HZ = 50000000,
    parameter BAUD   = 115200
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       rx,
    input  wire       rd_ready,
    output reg        rd_valid,
    output reg [7:0]  rd_data
);
    localparam integer DIV  = CLK_HZ / BAUD;
    localparam integer HALF = DIV / 2;
    localparam CW  = (DIV <= 1) ? 1 : $clog2(DIV);
    localparam CWH = (HALF <= 1) ? 1 : $clog2(HALF);
    localparam [CW-1:0]  DIVM1  = DIV - 1;
    localparam [CWH-1:0] HALFM1 = HALF - 1;

    localparam [2:0] S_IDLE  = 3'd0,
                     S_START = 3'd1,
                     S_DATA  = 3'd2,
                     S_STOP  = 3'd3;

    reg [2:0]   st;
    reg [CWH-1:0] hc;      // 起始位半位计数
    reg [CW-1:0]  cnt;     // 位时间计数
    reg [2:0]   bidx;
    reg [7:0]   sh;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_IDLE; hc <= {CWH{1'b0}}; cnt <= {CW{1'b0}};
            bidx <= 3'd0; sh <= 8'h00; rd_valid <= 1'b0; rd_data <= 8'h00;
        end
        else begin
            if (rd_valid && rd_ready) rd_valid <= 1'b0;
            case (st)
                S_IDLE: begin
                    if (rx == 1'b0) begin      // 起始位下降沿
                        hc  <= {CWH{1'b0}};
                        st  <= S_START;
                    end
                end
                S_START: begin
                    if (hc == HALFM1) begin
                        hc  <= {CWH{1'b0}};
                        cnt <= {CW{1'b0}};
                        bidx <= 3'd0;
                        st <= S_DATA;
                    end
                    else begin
                        hc <= hc + 1'b1;
                    end
                end
                S_DATA: begin
                    if (cnt == DIVM1) begin
                        cnt <= {CW{1'b0}};
                        sh  <= {rx, sh[7:1]};          // LSB first: 右移, 新位进最高位
                                                  // (8 次采样后 bit0 落在最低位)
                        if (bidx == 3'd7) begin
                            st <= S_STOP;              // 字节收齐, 停止位只做校验不装配
                        end
                        else begin
                            bidx <= bidx + 1'b1;
                        end
                    end
                    else begin
                        cnt <= cnt + 1'b1;
                    end
                end
                S_STOP: begin
                    if (cnt == DIVM1) begin
                        cnt <= {CW{1'b0}};
                        st <= S_IDLE;
                        if (rx == 1'b1) begin     // 停止位为 1 → 字节有效
                            rd_data  <= sh;
                            rd_valid <= 1'b1;
                        end
                    end
                    else begin
                        cnt <= cnt + 1'b1;
                    end
                end
                default: st <= S_IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
