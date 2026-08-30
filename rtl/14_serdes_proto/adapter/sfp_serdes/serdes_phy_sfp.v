// ============================================================================
// serdes_phy_sfp.v — SFP+/SerDes 物理层适配器 (L0, 高速档, 可拔插)
//
// 与 serdes_phy.v「同一接口, 不同实现」—— 验证架构的"可插拔接口适配器"：
//   serdes_link(L0.5, 字节轮流分发/聚合) 实例化本模块, 协议层零改动,
//   底层即从「逐位 LVCMOS 模型」换成「SFP+/SerDes 硬核背板」。
//
// 高速语义 (对应 GW5AST-138 的 SerDes 收发器, 270Mbps~12.5Gbps/lane):
//   - 词级适配器。每个 DATAW-bit 平行词(8b/10b 编码)上线,
//     每 lane N*10G 串行 bit 载 N*8G 净荷 (如 10.3125G 线率 => ~8.25G 净荷)。
//   - TX/RX IP 并行口本就是 valid/ready/data 语义, 与 serdes_phy 同构 => link 不改。
//   - 真实实现: 在下方注释处例化 Gowin_TX_IP / Gowin_RX_IP 占用所选 SerDes 通道,
//     并把串行差分接到 SFP+ 座。本模型用"词级延迟管线 + RX 弹性 FIFO"仿真回环。
// ============================================================================

`timescale 1ns/1ps

module serdes_phy_sfp #(
    parameter integer DATAW     = 8,
    parameter integer LINE_RATE = 10312500,   // Kbps, 文档用 (10.3125G)
    parameter integer RX_DEPTH  = 16,
    parameter integer LINK_LAT  = 4           // 链路+CDR 词级往返延迟(拍)
)(
    input  wire        clk,
    input  wire        rst_n,

    // ---- TX 侧: 并行词入口 (接 serdes_link lane_tx_*) ----
    input  wire                tx_valid,
    output wire                tx_ready,
    input  wire [DATAW-1:0]   tx_data,

    // ---- RX 侧: 并行词出口 (接 serdes_link lane_rx_*) ----
    output wire                rx_valid,
    input  wire                rx_ready,
    output wire [DATAW-1:0]   rx_data,
    output wire                rx_pending,

    // ---- SerDes IP 状态/诊断 (真实收发器) ----
    output wire                tx_ip_ready,
    output wire                rx_ip_aligned,
    input  wire                rx_polarity
);

    // =========================================================================
    // TX: 理想背板, TX IP 恒可收 (真实链上若有 FIFO 需在此合并背压)
    // =========================================================================
    reg [DATAW-1:0] tx_pipe;
    assign tx_ip_ready  = 1'b1;
    assign tx_ready     = tx_ip_ready;
    always @(posedge clk) begin
        if (!rst_n) tx_pipe <= {DATAW{1'b0}};
        else if (tx_valid && tx_ready) tx_pipe <= tx_data;
    end

    // =========================================================================
    // 链路: 词级延迟管线 (取代真实 CDR/走线延迟), 保序无损
    //   数据与有效位同管线推进 => RX 写口的 valid 与 data 严格时间对齐
    // =========================================================================
    reg [LINK_LAT-1:0][DATAW-1:0] chain;
    reg [LINK_LAT-1:0]             cvalid;
    reg tx_loaded_s;               // tx_pipe 已装载(pending 进入管线)
    integer li;
    always @(posedge clk) begin
        if (!rst_n) begin
            tx_loaded_s <= 1'b0;
            cvalid      <= 0;
            for (li = 0; li < LINK_LAT; li = li + 1) chain[li] <= {DATAW{1'b0}};
        end else begin
            tx_loaded_s <= tx_valid && tx_ready;
            // 数据与有效位同步移入管线
            chain[0] <= tx_pipe;
            cvalid[0] <= tx_loaded_s;
            for (li = 1; li < LINK_LAT; li = li + 1) begin
                chain[li]  <= chain[li-1];
                cvalid[li] <= cvalid[li-1];
            end
        end
    end
    wire [DATAW-1:0] link_word   = chain[LINK_LAT-1];
    wire             link_word_v = cvalid[LINK_LAT-1];

    // 对齐: 词连续无空隙 => 一旦有词即视为已对齐 (真实场景 = comma 对齐完成)
    assign rx_ip_aligned = |cvalid || |wcount;

    // =========================================================================
    // RX: 弹性 FIFO (吸收链路抖动 + 下游背压), 写=词到达, 读=rx_ready
    //   rx_valid/data 语义与 serdes_phy 完全一致 (电平 valid + 组合读头)
    // =========================================================================
    reg [DATAW-1:0] rx_fifo [0:RX_DEPTH-1];
    reg [$clog2(RX_DEPTH)-1:0] wr_ptr, rd_ptr, wcount;

    assign rx_valid    = (wcount != 0);
    assign rx_pending  = (wcount != 0);
    assign rx_data     = rx_fifo[rd_ptr];

    wire do_wr = link_word_v && (wcount < RX_DEPTH);
    wire do_rd = rx_ready    && (wcount != 0);

    always @(posedge clk) begin
        if (!rst_n) begin
            wr_ptr <= 0; rd_ptr <= 0; wcount <= 0;
        end else begin
            if (do_wr) rx_fifo[wr_ptr] <= link_word;
            if (do_wr) wr_ptr <= wr_ptr + 1'b1;
            if (do_rd) rd_ptr <= rd_ptr + 1'b1;
            case ({do_wr, do_rd})
                2'b10: wcount <= wcount + 1'b1;
                2'b01: wcount <= wcount - 1'b1;
                default: ;
            endcase
        end
    end

endmodule
