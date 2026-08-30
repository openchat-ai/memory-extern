// ============================================================================
// tb_phy_rx_backpressure.v — 验证 serdes_phy RX 背压(FIFO)真实有效
//   TX 发 N=40 个字词, RX 消费者让 rx_ready 周期拉低(3 拍收 2 拍停),
//   证明: 数据被 FIFO 缓存、背压期间不丢失、顺序不乱。
// ============================================================================

`timescale 1ns/1ps

module tb_phy_rx_backpressure;
    parameter DATAW = 8;
    parameter N     = 40;

    reg clk=0, rst_n=0, tx_valid=0;
    reg [7:0] tx_data=0;
    wire tx_ready, rx_valid;
    wire [7:0] rx_data;
    reg rx_ready=1;
    integer sent=0, c=0;
    integer rcvd=0, err=0;

    // 期望序列 0..N-1, 回放校验
    always #5 clk = ~clk;

    serdes_phy #(.DATAW(DATAW), .N_LANE(1), .BIT_DELAY(3), .RX_DEPTH(16)) u_phy (
        .clk(clk), .rst_n(rst_n),
        .tx_valid(tx_valid), .tx_ready(tx_ready), .tx_data(tx_data),
        .rx_valid(rx_valid), .rx_ready(rx_ready), .rx_data(rx_data));

    // TX 源: 持续发 N 个字 0..N-1
    always @(posedge clk) begin
        if (!rst_n) begin tx_valid<=0; tx_data<=0; sent<=0; end
        else if (sent<N) begin
            if (tx_ready) begin tx_data<=sent[7:0]; tx_valid<=1; sent<=sent+1; end
        end
    end

    // RX 消费者背压: 3 拍收(ready=1) 2 拍停(ready=0)
    always @(posedge clk) begin
        if (!rst_n) c<=0;
        else begin
            if (c==4) c<=0; else c<=c+1;
            rx_ready <= (c<3);
        end
    end

    // 回放校验: RX 输出的字必须严格 = 0,1,2,...
    // 注: phy 的 rx_valid 为电平(FIFO 非空), 须以 valid&&ready 握手取走, 避免停拍重复计数。
    always @(posedge clk) begin
        if (rst_n && rx_valid && rx_ready) begin
            if (rx_data !== rcvd[7:0]) err <= err + 1;
            rcvd <= rcvd + 1;
        end
    end

    initial begin
        #20 rst_n=1;
        while (rcvd < N) #10;
        #50;
        if (err==0 && rcvd==N) $display("PASS: phy RX 背压 N=%0d 字无丢失、顺序正确", N);
        else $display("FAIL: rcvd=%0d err=%0d", rcvd, err);
        $finish;
    end
endmodule
