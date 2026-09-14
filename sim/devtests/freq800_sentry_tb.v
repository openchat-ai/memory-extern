`timescale 1ns/1ps
module freq800_sentry_tb;
reg clk_800 = 0, clk_50 = 0, rst_n = 0, pll_lock = 0;
always #0.625 clk_800 = ~clk_800;      // 800MHz 行为
always #10    clk_50  = ~clk_50;
wire led_lock, led_slow, led_go;
freq800_sentry_top uut (.clk_800(clk_800), .clk_50(clk_50), .rst_n(rst_n),
    .pll_lock(pll_lock), .led_lock(led_lock), .led_slow(led_slow), .led_go(led_go));
reg [31:0] n_tog = 0; reg prev = 0;
always @(posedge clk_800) begin
    if (led_slow !== prev) begin
        if (prev === 1'b0) n_tog <= n_tog + 1;
        prev <= led_slow;
    end
end
reg [31:0] cyc;
initial begin
    $dumpfile("/data/data/com.termux/files/home/sram/.build/freq800_sentry_tb.vcd");
    $dumpvars(0, uut);
    repeat (3) @(posedge clk_50); rst_n <= 1; pll_lock <= 1;
    for (cyc = 0; cyc < 3000; cyc = cyc + 1) @(posedge clk_800);
    if (led_lock === 1'b1 && led_go === 1'b1 && n_tog >= 1)
        $display("SENTRY-PASS: lock=1 led_go=1 slow 翻转=%0d (哨兵在 800 行为域自洽); 800实体=PLL-X800(PC硅)", n_tog);
    else
        $display("SENTRY-FAIL: lock=%0b go=%0b 翻转=%0d", led_lock, led_go, n_tog);
    $finish;
end
endmodule
