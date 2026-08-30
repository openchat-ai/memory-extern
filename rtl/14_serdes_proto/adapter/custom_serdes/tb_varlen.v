// ============================================================================
// tb_varlen.v — 验证 framer_tx 支持"每帧可变长度" (自适应负载, 通用核心目标)
//   连续发 3 帧, 长度分别 4 / 16 / 64 字节, 帧头 len 随帧变化,
//   经 phy 回环 + framer_rx 解出。producer 用独立 always@(posedge) 状态机
//   (复用 tb_custom_serdes 已验证模式), 消费者独立校验每帧 payload + CRC。
// ============================================================================

`timescale 1ns/1ps

module tb_varlen;
    parameter DATAW = 8;
    reg clk, rst_n;
    reg start, din_valid, din_len_valid;
    reg [7:0] din_data;
    reg [15:0] din_len;
    wire din_ready;
    wire phy_tx_valid, phy_tx_ready, phy_rx_valid;
    wire [7:0] phy_tx_data, phy_rx_data;
    wire d_valid, d_done, d_crc_err;
    wire [7:0] d_data;

    integer err;
    integer cur_frame, rb;
    integer exp_lens [0:2];
    reg [7:0] tx_payload [0:63];

    // ---- producer: 独立 posedge 状态机, 一次发一帧 ----
    reg send_active;
    integer byte_idx;
    integer send_len;        // 本帧发送目标字节数
    always @(posedge clk) begin
        if (!rst_n) begin
            send_active <= 1'b0;
            byte_idx    <= 0;
            din_valid   <= 1'b0;
            din_data    <= 8'h00;
            send_len    <= 0;
        end else begin
            if (!send_active) begin
                if (start) begin
                    send_active <= 1'b1;
                    byte_idx    <= 0;
                    send_len    <= din_len;   // 锁定本帧长度
                end
                din_valid <= 1'b0;
            end else begin
                if (din_ready && din_valid) begin
                    byte_idx <= byte_idx + 1;
                    if (byte_idx == send_len-1) begin
                        send_active <= 1'b0;
                        din_valid   <= 1'b0;
                    end else begin
                        din_data  <= tx_payload[byte_idx+1];
                        din_valid <= 1'b1;
                    end
                end else begin
                    if (byte_idx < send_len) begin
                        din_data  <= tx_payload[byte_idx];
                        din_valid <= 1'b1;
                    end else
                        din_valid <= 1'b0;
                end
            end
        end
    end

    serdes_framer_tx #(.PKT_LEN(64)) u_tx (
        .clk(clk), .rst_n(rst_n),
        .din_ready(din_ready), .din_valid(din_valid), .din_data(din_data),
        .din_len_valid(din_len_valid), .din_len(din_len),
        .start(start), .m_valid(phy_tx_valid), .m_ready(phy_tx_ready), .m_data(phy_tx_data));

    serdes_phy #(.DATAW(DATAW), .N_LANE(1), .BIT_DELAY(3)) u_phy (
        .clk(clk), .rst_n(rst_n),
        .tx_valid(phy_tx_valid), .tx_ready(phy_tx_ready), .tx_data(phy_tx_data),
        .rx_valid(phy_rx_valid), .rx_ready(1'b1), .rx_data(phy_rx_data));

    serdes_framer_rx #(.MAX_LEN(64)) u_rx (
        .clk(clk), .rst_n(rst_n),
        .s_valid(phy_rx_valid), .s_ready(), .s_data(phy_rx_data),
        .d_valid(d_valid), .d_ready(1'b1), .d_data(d_data), .d_done(d_done), .d_crc_err(d_crc_err));

    // ---- consumer: 校验每帧 payload 内容 + len + CRC ----
    always @(posedge clk) begin
        if (!rst_n) begin
            rb <= 0; cur_frame <= 0;
            exp_lens[0]=4; exp_lens[1]=16; exp_lens[2]=64;
        end else if (d_valid) begin
            if (d_data !== tx_payload[rb]) err <= err + 1;
            if (d_done) begin
                if (rb != exp_lens[cur_frame]-1) err <= err + 1;
                if (d_crc_err) err <= err + 1;
                rb <= 0;
                if (cur_frame < 2) cur_frame <= cur_frame + 1;
            end else
                rb <= rb + 1;
        end
    end

    integer k, f;
    always #5 clk = ~clk;
    initial begin
        clk=0; rst_n=0; start=0; din_valid=0; din_len_valid=0; din_len=0; din_data=0; err=0;
        #20 rst_n=1;
        for (k=0;k<64;k=k+1) tx_payload[k]=k[7:0];
        #5;
        for (f=0; f<3; f=f+1) begin
            @(posedge clk);
            din_len      <= (f==0)?4:(f==1)?16:64;
            din_len_valid<= 1'b1;
            start        <= 1'b1;
            @(posedge clk);
            start        <= 1'b0;
            din_len_valid<= 1'b0;
            // 每帧等够时间让整帧(含 CRC)走完回环: 每字节 ~16 拍
            repeat ((f==0)?4:(f==1)?16:64) begin
                repeat (40) @(posedge clk);
            end
        end
        #20;
        if (err==0) $display("PASS: 变长帧 3 帧(4/16/64) payload内容+len+CRC 全部正确");
        else $display("FAIL: err=%0d", err);
        $finish;
    end
endmodule
