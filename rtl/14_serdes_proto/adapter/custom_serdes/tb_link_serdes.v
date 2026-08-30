// ============================================================================
// tb_link_serdes.v — 多 lane SerDes 完整链路端到端
//   payload --framer_tx--> serdes_link(4 lane 回环) --framer_rx--> payload
//   验证: 多 lane 下数据 + CRC-16 + 变长 全部完整正确。
// ============================================================================

`timescale 1ns/1ps

module tb_link_serdes;
    parameter DATAW = 8;
    parameter N_LANE = 4;
    reg clk, rst_n, start, din_valid, din_len_valid;
    reg [7:0] din_data;
    reg [15:0] din_len;
    wire din_ready;
    wire m_valid, m_ready;
    wire [7:0] m_data;
    wire s_valid;
    wire [7:0] s_data;
    wire d_valid, d_done, d_crc_err;
    wire [7:0] d_data;

    integer err=0, pkts_ok=0, rb, cur_frame;

    serdes_framer_tx #(.PKT_LEN(64)) u_tx (
        .clk(clk), .rst_n(rst_n),
        .din_ready(din_ready), .din_valid(din_valid), .din_data(din_data),
        .din_len_valid(din_len_valid), .din_len(din_len),
        .start(start), .m_valid(m_valid), .m_ready(m_ready), .m_data(m_data));

    serdes_link #(.DATAW(DATAW), .N_LANE(N_LANE), .BIT_DELAY(3), .RX_DEPTH(16)) u_link (
        .clk(clk), .rst_n(rst_n),
        .in_ready(m_ready), .in_valid(m_valid), .in_data(m_data),
        .out_valid(s_valid), .out_ready(1'b1), .out_data(s_data));

    serdes_framer_rx #(.MAX_LEN(64)) u_rx (
        .clk(clk), .rst_n(rst_n),
        .s_valid(s_valid), .s_ready(), .s_data(s_data),
        .d_valid(d_valid), .d_ready(1'b1), .d_data(d_data), .d_done(d_done), .d_crc_err(d_crc_err));

    reg [7:0] tx_payload [0:63];

    // 消费者: 校验每帧 payload 内容
    always @(posedge clk) begin
        if (!rst_n) begin rb<=0; end
        else if (d_valid) begin
            if (d_data !== tx_payload[rb]) err <= err+1;
            if (d_done) begin
                if (d_crc_err) err <= err+1;
                pkts_ok <= pkts_ok+1;
                rb <= 0;
            end else rb <= rb+1;
        end
    end

    // producer (always-posedge 模式, 复用已验证)
    reg send_active; integer bi;
    always @(posedge clk) begin
        if (!rst_n) begin send_active<=0; bi<=0; din_valid<=0; din_data<=0; end
        else if (!send_active) begin
            if (start) begin send_active<=1; bi<=0; end
            din_valid<=0;
        end else begin
            if (din_ready && din_valid) begin
                bi<=bi+1;
                if (bi==din_len-1) begin send_active<=0; din_valid<=0; end
                else begin din_data<=tx_payload[bi+1]; din_valid<=1; end
            end else begin
                if (bi<din_len) begin din_data<=tx_payload[bi]; din_valid<=1; end
                else din_valid<=0;
            end
        end
    end

    integer k, f;
    always #5 clk = ~clk;
    initial begin
        clk=0; rst_n=0; start=0; din_valid=0; din_len_valid=0; din_len=0; din_data=0;
        err=0; pkts_ok=0;
        #20 rst_n=1;
        for (k=0;k<64;k=k+1) tx_payload[k]=k[7:0];
        #5;
        // 发 3 帧: 4, 16, 64 字节
        for (f=0; f<3; f=f+1) begin
            @(posedge clk);
            din_len      <= (f==0)?4:(f==1)?16:64;
            din_len_valid<= 1'b1;
            start        <= 1'b1;
            @(posedge clk);
            start        <= 1'b0;
            din_len_valid<= 1'b0;
            repeat ((f==0)?4:(f==1)?16:64) repeat(80) @(posedge clk);  // 多lane慢, 放宽
        end
        #20;
        if (err==0 && pkts_ok==3) $display("PASS: 多lane(%0d) 端到端 3 帧(4/16/64) 数据+CRC16 完整", N_LANE);
        else $display("FAIL: err=%0d pkts_ok=%0d", err, pkts_ok);
        $finish;
    end
endmodule
