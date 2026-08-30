// ============================================================================
// serdes_framer_rx.v — 自定义 SerDes 帧解封 (L1, RX 方向)
//
// 从 serdes_phy(DATAW=8)接收字节流, 识别 magic, 读长度, 抽取 payload,
// 以字节 valid/data 交付给消费者, 并在包尾给 done 脉冲。
// 帧尾固定附 2 字节 CRC-16-CCITT(高字节先); CRC 不符置 d_crc_err。
// 与 serdes_framer_tx 成对, 走同一线格式。
// ============================================================================

`timescale 1ns/1ps

module serdes_framer_rx #(
    parameter [15:0] MAX_LEN = 512
)(
    input  wire        clk,
    input  wire        rst_n,

    // ---- 上游: 从 phy 来的字节流 ----
    input  wire        s_valid,
    output wire        s_ready,
    input  wire [7:0]  s_data,

    // ---- 下游: 解出的 payload 字节 ----
    output reg         d_valid,
    input  wire        d_ready,
    output reg  [7:0]  d_data,
    output reg         d_done,
    output reg         d_crc_err    // 本包 CRC 校验失败(脉冲)
);

    localparam [2:0]
        S_SYNC0=0, S_SYNC1=1, S_LENH=2, S_LENL=3, S_PAY=4, S_CRC_H=5, S_CRC_L=6;

    reg [2:0] st;
    reg [15:0] pkt_len;
    reg [15:0] cnt;
    reg        c_crc_en;
    reg        c_crc_init;
    reg [15:0] crc_rx;     // 链路传来的 CRC 拼接

    wire [15:0] crc_out;

    crc16 u_crc (
        .clk(clk), .rst_n(rst_n),
        .crc_en(c_crc_en), .crc_din(s_data), .crc_init(c_crc_init), .crc_out(crc_out)
    );

    assign s_ready = 1'b1;   // 总是能收字节

    always @(*) begin
        c_crc_en   = (st == S_PAY) && s_valid;
        c_crc_init = ~rst_n;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            st        <= S_SYNC0;
            cnt       <= 16'd0;
            pkt_len   <= 16'd0;
            d_valid   <= 1'b0;
            d_data    <= 8'h00;
            d_done    <= 1'b0;
            d_crc_err <= 1'b0;
            crc_rx    <= 16'd0;
        end else begin
            d_valid   <= 1'b0;
            d_done    <= 1'b0;
            d_crc_err <= 1'b0;
            if (s_valid) begin
                case (st)
                    S_SYNC0: if (s_data == 8'h5A) st <= S_SYNC1;
                    S_SYNC1: if (s_data == 8'h5A) st <= S_LENH;
                             else st <= S_SYNC0;
                    S_LENH:  begin pkt_len[15:8] <= s_data; st <= S_LENL; end
                    S_LENL:  begin pkt_len[7:0]  <= s_data; cnt <= 0; st <= S_PAY; end
                    S_PAY:   begin
                        if (d_ready) begin
                            d_data  <= s_data;
                            d_valid <= 1'b1;
                            cnt     <= cnt + 16'd1;
                            if (cnt == pkt_len-1) begin
                                d_done <= 1'b1;
                                st     <= S_CRC_H;      // 负载收完, 进入 CRC 校验
                            end
                        end
                    end
                    S_CRC_H: begin
                        crc_rx[15:8] <= s_data;          // CRC 高字节
                        st           <= S_CRC_L;
                    end
                    S_CRC_L: begin
                        crc_rx[7:0] <= s_data;           // CRC 低字节
                        if ({crc_rx[15:8], s_data} !== crc_out)
                            d_crc_err <= 1'b1;           // 与本地计算的 CRC 比对
                        st <= S_SYNC0;
                    end
                    default: st <= S_SYNC0;
                endcase
            end
        end
    end

endmodule
