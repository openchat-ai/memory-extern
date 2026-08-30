// ============================================================================
// tb_custom_serdes.v — 自定义 SerDes 适配器回环自测
//
//   payload[byte] --fram_tx--> serdes_phy(回环) --fram_rx--> payload[byte]
//
// 验证: 自定义 SerDes 适配器(L0 phy + L1 帧封装/解封)能正确往返字节负载。
// 使用"时钟驱动的字节源 + 固定周期验证", 避免 wait/start 竞态死锁。
// ============================================================================

`timescale 1ns/1ps

module tb_custom_serdes;

    parameter DATAW   = 8;
    parameter PKT_LEN = 32;

    reg clk, rst_n;

    // ---- 发起端(producer): 帧封装输入 ----
    reg start;
    reg din_valid;
    reg [7:0] din_data;
    wire din_ready;
    reg din_len_valid;
    reg [15:0] din_len;

    // ---- framer -> phy ----
    wire phy_tx_valid;
    wire phy_tx_ready;
    wire [7:0] phy_tx_data;

    // ---- phy -> deframer ----
    wire phy_rx_valid;
    reg  phy_rx_ready;
    wire [7:0] phy_rx_data;

    // ---- deframer 输出 ----
    wire d_valid;
    reg  d_ready;
    wire [7:0] d_data;
    wire d_done;

    reg [7:0] tx_payload [0:PKT_LEN-1];

    // ==========================================================================
    // 时钟驱动的字节源: 与 framer 的 din_ready 握手逐字节 push
    // ==========================================================================
    reg send_active;
    integer byte_idx;
    always @(posedge clk) begin
        if (!rst_n) begin
            send_active <= 1'b0;
            byte_idx    <= 0;
            din_valid   <= 1'b0;
            din_data    <= 8'h00;
        end else begin
            if (!send_active) begin
                if (start) begin
                    send_active <= 1'b1;
                    byte_idx    <= 0;
                end
                din_valid <= 1'b0;
            end else begin
                // 处于发送中: 逐字节交付, 尊重 din_ready
                if (din_ready && din_valid) begin
                    // 本字节已被消费
                    byte_idx <= byte_idx + 1;
                    if (byte_idx == PKT_LEN-1) begin
                        send_active <= 1'b0;
                        din_valid   <= 1'b0;
                    end else begin
                        din_data  <= tx_payload[byte_idx+1];
                        din_valid <= 1'b1;
                    end
                end else begin
                    // 等待 framer 就绪
                    if (byte_idx < PKT_LEN) begin
                        din_data  <= tx_payload[byte_idx];
                        din_valid <= 1'b1;
                    end else
                        din_valid <= 1'b0;
                end
            end
        end
    end

    serdes_framer_tx #(.PKT_LEN(PKT_LEN))
        u_tx (.clk(clk), .rst_n(rst_n),
              .din_ready(din_ready), .din_valid(din_valid), .din_data(din_data),
              .din_len_valid(din_len_valid), .din_len(din_len),
              .start(start), .m_valid(phy_tx_valid), .m_ready(phy_tx_ready), .m_data(phy_tx_data));

    serdes_phy #(.DATAW(DATAW), .N_LANE(1), .BIT_DELAY(3))
        u_phy (.clk(clk), .rst_n(rst_n),
               .tx_valid(phy_tx_valid), .tx_ready(phy_tx_ready), .tx_data(phy_tx_data),
               .rx_valid(phy_rx_valid), .rx_ready(phy_rx_ready), .rx_data(phy_rx_data));

    serdes_framer_rx #(.MAX_LEN(512))
        u_rx (.clk(clk), .rst_n(rst_n),
              .s_valid(phy_rx_valid), .s_ready(phy_rx_ready), .s_data(phy_rx_data),
              .d_valid(d_valid), .d_ready(d_ready), .d_data(d_data), .d_done(d_done));

    // ==========================================================================
    // 接收端消费者: 逐字节收, 校验, 数完成包
    // ==========================================================================
    integer rx_byte;      // 本包内字节序号
    integer pkts_ok;
    integer err_cnt;
    always @(posedge clk) begin
        if (!rst_n) begin
            rx_byte <= 0; pkts_ok <= 0; err_cnt <= 0;
            d_ready <= 1'b0;
        end else begin
            d_ready <= 1'b1;   // 消费者随时可收
            if (d_valid) begin
                if (d_data !== tx_payload[rx_byte]) err_cnt <= err_cnt + 1;
                if (d_done) begin
                    // done 与最后一个 payload 字节同拍; 此时已收满 PKT_LEN 字节
                    pkts_ok <= pkts_ok + 1;
                    rx_byte <= 0;
                end else begin
                    rx_byte <= rx_byte + 1;
                end
            end
        end
    end

    // ==========================================================================
    // 主控: 发 NUM_PKT 包, 每包后等固定周期, 最终校验
    // ==========================================================================
    localparam NUM_PKT = 3;
    integer k;
    integer pkt_i;
    always #5 clk = ~clk;
    initial begin
        clk = 0; rst_n = 0;
        start = 0;
        din_len = PKT_LEN;
        din_len_valid = 0;
        #20 rst_n = 1;
        for (k = 0; k < PKT_LEN; k = k + 1)
            tx_payload[k] = k[7:0];
        // 每包发送间隔充分(每字节 phy 约 9 cycles)
        for (pkt_i = 0; pkt_i < NUM_PKT; pkt_i = pkt_i + 1) begin
            @(posedge clk);
            din_len <= PKT_LEN;
            din_len_valid <= 1'b1;
            start <= 1'b1;
            @(posedge clk);
            start <= 1'b0;
            din_len_valid <= 1'b0;
            repeat (PKT_LEN*16) @(posedge clk);   // 足够时间让包走完回环
        end
        #200;
        if (pkts_ok == NUM_PKT && err_cnt == 0)
            $display("PASS: custom_serdes loopback %0d/%0d packets OK, payload intact", pkts_ok, NUM_PKT);
        else
            $display("FAIL: pkts_ok=%0d/%0d err_cnt=%0d", pkts_ok, NUM_PKT, err_cnt);
        $finish;
    end

endmodule
