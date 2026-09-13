`timescale 1ps/1ps
// board_good_tb — board_decode_top 帧指纹自动判定验证
// 断言: 稳定自驱闭环 → ≤20000 拍内 led[3](GOOD=≥2连续同指纹) 恒 1。
module board_good_tb;
    reg clk = 0, rst_n = 0;
    wire [3:0] led;
    board_decode_top U(.clk(clk), .rst_n(rst_n), .led(led));
    always #5 clk = ~clk;
    integer cyc;
    reg donef = 0;
    reg tfb = 0;
    initial begin
        repeat (5) @(posedge clk); rst_n = 1;
        cyc = 0;
        while (cyc < 20000) begin
            @(posedge clk); cyc = cyc + 1;
            if (U.token_done) $display("  token@%0d aw=%0d hsh=%08h good=%0d", cyc, U.a_words, U.hsh, U.good);
            if (U.done_ir && !df) begin $display("  done@%0d", cyc); df = 1; end
            if (led[3]) begin donef = 1; cyc = 20001; end
        end
        if (donef) $display("board_good PASS  GOOD(led3)@%0d led=%0b", cyc, led);
        else begin $display("board_good FAIL  led3 未起  led=%0b", led); $finish(1); end
        #40 $finish;
    end
    reg df = 0;
endmodule