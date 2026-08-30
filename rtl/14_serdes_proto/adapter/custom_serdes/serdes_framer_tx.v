// ============================================================================
// serdes_framer_tx.v — 自定义 SerDes 帧封装 (L1, TX 方向)
//
// 把"字节流负载"封装成自定义 SerDes 线格式并逐字节喂给 serdes_phy(DATAW=8):
//     magic[8] = 0x5A   magic[8] = 0x5A
//     len[16]          = pkt_len(负载字节数, 发起端给定)
//     payload[8*len]   = 从发起端(din)逐字节抽
//     crc[16]          = 负载的 CRC-16-CCITT, 帧尾固定附 2 字节(高字节先)
//
// 一状态一拍发一个字节, 依赖 m_ready 推进(背压安全)。负载阶段从 din 拉取。
// ============================================================================

`timescale 1ns/1ps

module serdes_framer_tx #(
    parameter [15:0] PKT_LEN = 64
)(
    input  wire        clk,
    input  wire        rst_n,
    output wire        din_ready,
    input  wire        din_valid,
    input  wire [7:0]  din_data,
    input  wire        din_len_valid,   // start 同拍有效: 本帧负载字节数
    input  wire [15:0] din_len,
    input  wire        start,
    output reg         m_valid,
    input  wire        m_ready,
    output reg  [7:0]  m_data
);

    // 数据输出用组合逻辑: 一旦进入某状态, 同拍 m_data 即为该状态要发的字节,
    // 且 m_valid 也由当前状态组合推出(不依赖非阻塞时钟), 避免状态首拍错失字节。
    localparam [3:0]
        S_IDLE=0, S_MAGIC0=1, S_MAGIC1=2, S_LENH=3, S_LENL=4, S_PAY=5, S_CRC_H=6, S_CRC_L=7;

    reg [3:0] st;   // 状态编码见下
    reg [15:0] pkt_len;
    reg [15:0] cnt;
    reg        c_crc_en;
    reg        c_crc_init;

    wire [15:0] crc_out;

    crc16 u_crc (
        .clk(clk), .rst_n(rst_n),
        .crc_en(c_crc_en), .crc_din(din_data), .crc_init(c_crc_init), .crc_out(crc_out)
    );

    always @(*) begin
        case (st)
            S_MAGIC0, S_MAGIC1: m_data = 8'h5A;
            S_LENH:   m_data = pkt_len[15:8];
            S_LENL:   m_data = pkt_len[7:0];
            S_PAY:    m_data = din_data;
            S_CRC_H:  m_data = crc_out[15:8];
            S_CRC_L:  m_data = crc_out[7:0];
            default:  m_data = 8'h00;
        endcase
        m_valid = (st != S_IDLE);
        if (st == S_PAY) m_valid = din_valid;
    end

    // 仅在负载阶段从发起端拉字节(且下游就绪)
    assign din_ready = (st == S_PAY) && m_ready;

    // CRC 使能: 仅在负载阶段且该字节被下游真正消费时推进
    always @(*) begin
        c_crc_en   = (st == S_PAY) && m_ready && din_valid;
        c_crc_init = (st == S_IDLE) && start;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            st      <= S_IDLE;
            pkt_len <= 16'd0;
            cnt     <= 16'd0;
        end else begin
            case (st)
                S_IDLE: begin
                    if (start) begin
                        pkt_len <= din_len_valid ? din_len : PKT_LEN;   // 自适应: 每帧取实际长度
                        cnt     <= 16'd0;
                        st      <= S_MAGIC0;
                    end
                end

                S_MAGIC0: if (m_ready) st <= S_MAGIC1;
                S_MAGIC1: if (m_ready) st <= S_LENH;
                S_LENH:   if (m_ready) st <= S_LENL;
                S_LENL:   if (m_ready) st <= S_PAY;

                S_PAY: begin
                    if (m_ready && din_valid) begin
                        cnt <= cnt + 16'd1;
                        if (cnt == pkt_len-1) st <= S_CRC_H;
                    end
                end

                S_CRC_H: if (m_ready) st <= S_CRC_L;
                S_CRC_L: if (m_ready) st <= S_IDLE;

                default: st <= S_IDLE;
            endcase
        end
    end

endmodule
