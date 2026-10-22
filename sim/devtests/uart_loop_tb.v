`timescale 1ps/1ps
// uart_loop_tb — uart_tx → uart_rx 直接环回, 隔离位时序/位序问题
// 高速档 BAUD=6250000 (DIV=8) → 每个字节 80 拍, 仿真快
module uart_loop_tb;
    localparam BAUD = 6250000;
    localparam DIV  = 8;

    reg clk = 0, rst_n = 0;
    wire tx_line, rx_line;
    reg  [7:0] tx_data;
    reg        tx_wr;
    wire       tx_ready;
    wire       rx_valid;
    wire [7:0] rx_data;

    uart_tx #(.CLK_HZ(50000000), .BAUD(BAUD)) U_TX (
        .clk(clk), .rst_n(rst_n), .tx(tx_line),
        .wr_en(tx_wr), .data(tx_data), .ready(tx_ready)
    );
    uart_rx #(.CLK_HZ(50000000), .BAUD(BAUD)) U_RX (
        .clk(clk), .rst_n(rst_n), .rx(rx_line),
        .rd_ready(1'b1), .rd_valid(rx_valid), .rd_data(rx_data)
    );

    always #5 clk = ~clk;

    assign rx_line = tx_line;      // 环回: TX 输出直接接 RX 输入

    reg [7:0] pat [0:7];
    integer i, nrecv, errors;

    initial begin
        pat[0] = 8'h55; pat[1] = 8'hAA; pat[2] = 8'h41; pat[3] = 8'h0A;
        pat[4] = 8'hF0; pat[5] = 8'h0F; pat[6] = 8'hF1; pat[7] = 8'h00;
        tx_data = 0; tx_wr = 0; nrecv = 0; errors = 0;
        repeat (10) @(posedge clk);
        rst_n = 1;
        for (i = 0; i < 8; i = i + 1) begin
            @(posedge clk);
            while (!tx_ready) @(posedge clk);
            tx_data = pat[i];
            tx_wr = 1;
            @(posedge clk);
            tx_wr = 0;
            repeat (200) @(posedge clk);
        end
        repeat (500) @(posedge clk);
        $display("=== uart_loop: 收到 %0d 字节, errors=%0d ===", nrecv, errors);
        if (errors == 0) $display("uart_loop PASS");
        else $display("uart_loop FAIL");
        $finish;
    end

    // 接收计数
    always @(posedge clk) if (rst_n && rx_valid) begin
        nrecv = nrecv + 1;
        if (rx_data !== pat[(nrecv-1) % 8]) begin
            $display("MISMATCH #%0d: 期望 %02x 实收 %02x", nrecv, pat[(nrecv-1) % 8], rx_data);
            errors = errors + 1;
        end
    end

    // 内部状态跟踪 (前 60 拍)
    integer dbgc;
    initial dbgc = 0;
    always @(posedge clk) if (rst_n) begin
        if (dbgc < 60) begin
            $display("  cyc=%0d | TX st=%0d cnt=%0d tx=%b sh=%02x | RX st=%0d hc=%0d cnt=%0d bidx=%0d sh=%02x rx=%b rv=%b",
                     dbgc, U_TX.st, U_TX.cnt, tx_line, U_TX.sh,
                     U_RX.st, U_RX.hc, U_RX.cnt, U_RX.bidx, U_RX.sh, rx_line, rx_valid);
            dbgc = dbgc + 1;
        end
    end
endmodule
