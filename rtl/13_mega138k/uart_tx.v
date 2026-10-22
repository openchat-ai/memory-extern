`timescale 1ns/1ps
`default_nettype none
//────────────────────────────────────────────────────────────────────────────
// uart_tx.v — 115200 8N1 字节发送器 (板级 UART 输出通道)
// 用途: board_decode_top 把内部计数器以文本行吐到板载调试器的 UART 侧
//       (同一根 USB JTAG&UART 线, 不需要任何额外接线)
// 位时序 (DIV = 拍/位):
//   起始位 [0,1)  数据位0 [1,2) ... 数据位7 [8,9)  停止位 [9,10)  空闲 [10,11)
//   字节间高电平空隙 ≥ 2 位时间 (停止位 + S_END 空闲位) —— 关键:
//   接收端采样完停止位 (9.5 位时间处) 后要再过一个位时间才回到 S_IDLE,
//   若下一个起始沿来得太早 (10 位时间处) 就会被漏检 → 整字节错一位。
//   多给一个空闲位后, 起始沿最早在 11 位时间处, 接收端那时已就绪。
// 发送端为"就绪握手"式: wr_en 在 ready=1 时被接受, 一次一个字节
//   → 上层天然被反压, 不需要 FIFO
// 注: 代码风格按 Gowin 前端挑刺规避 (不用 SV 转换 N'(x); else 单独成行且带 begin/end)
//────────────────────────────────────────────────────────────────────────────
module uart_tx #(
    parameter CLK_HZ = 50000000,
    parameter BAUD   = 115200
)(
    input  wire       clk,
    input  wire       rst_n,
    output reg        tx,          // 空闲为 1 (UART 极性: 逻辑低=起始位)
    input  wire       wr_en,       // 写一个字节 (仅在 ready 时有效)
    input  wire [7:0] data,
    output wire       ready        // 1 = 可以接受新字节
);
    localparam integer DIV = CLK_HZ / BAUD;     // 434 @50MHz/115200
    localparam CW = (DIV <= 1) ? 1 : $clog2(DIV);
    localparam [CW-1:0] DIVM1 = DIV - 1;

    localparam [2:0] S_IDLE  = 3'd0,
                     S_START = 3'd1,
                     S_DATA  = 3'd2,
                     S_STOP  = 3'd3,
                     S_END   = 3'd4;   // 停止位后的一个空闲位时间

    reg [2:0]  st;
    reg [7:0]  sh;        // 移位寄存器: 最低位先发
    reg [CW-1:0] cnt;     // 位周期计数
    reg [2:0]  nbits;     // 还没发出的数据位数 (S_START 之后 = 7)

    assign ready = (st == S_IDLE);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_IDLE; tx <= 1'b1; sh <= 8'h00; cnt <= {CW{1'b0}}; nbits <= 3'd0;
        end
        else begin
            case (st)
                S_IDLE: begin
                    tx <= 1'b1;
                    if (wr_en) begin
                        tx    <= 1'b0;      // 起始位
                        sh    <= data;
                        cnt   <= {CW{1'b0}};
                        nbits <= 3'd7;     // 数据位 1..7 待发 (bit0 在 S_START 发)
                        st    <= S_START;
                    end
                end
                S_START: begin
                    if (cnt == DIVM1) begin
                        cnt  <= {CW{1'b0}};
                        tx   <= sh[0];        // 数据位 0
                        sh   <= {1'b0, sh[7:1]};
                        st   <= S_DATA;
                    end
                    else begin
                        cnt <= cnt + 1'b1;
                    end
                end
                S_DATA: begin
                    if (cnt == DIVM1) begin
                        cnt <= {CW{1'b0}};
                        tx  <= sh[0];
                        sh  <= {1'b0, sh[7:1]};
                        if (nbits == 3'd1) begin
                            nbits <= 3'd0;
                            st    <= S_STOP;   // 8 个数据位已发完, 下一拍起是停止位
                        end
                        else begin
                            nbits <= nbits - 1'b1;
                        end
                    end
                    else begin
                        cnt <= cnt + 1'b1;
                    end
                end
                S_STOP: begin
                    if (cnt == DIVM1) begin
                        cnt <= {CW{1'b0}};
                        tx  <= 1'b1;          // 停止位
                        st  <= S_END;
                    end
                    else begin
                        cnt <= cnt + 1'b1;
                    end
                end
                S_END: begin
                    if (cnt == DIVM1) begin
                        cnt <= {CW{1'b0}};
                        tx  <= 1'b1;          // 空闲位 (给接收端留重同步时间)
                        st  <= S_IDLE;
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
