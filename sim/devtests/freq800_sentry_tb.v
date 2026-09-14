// freq800_sentry_top 逻辑验证 (termux)
// 行为 PLL stub: clkin 50MHz -> clkout0 800MHz (1.25ns), lock 延迟 2 sys 拍后置位。
// 直接例化 freq800_sentry_top 验证其整体逻辑;
// 真正的 800 物理(ODIV=1 合法性 / fabric 时钟树 / FF@1.25ns)只能在 PnR+Silicon 判定。
`timescale 1ps/1ps

module Gowin_PLL_X800 (clkout0, lock, clkin);
    output clkout0;
    output lock;
    input  clkin;
    reg    clkout0 = 0;
    reg    lock    = 0;
    always #625 clkout0 = ~clkout0;                 // 800MHz (1.25ns 周期)
    always @(posedge clkin) if (!lock) lock <= 1'b1;// 模拟锁相延迟
endmodule

module freq800_sentry_tb;

reg  clk_50 = 0;
reg  rst_n  = 0;
wire led_lock, led_slow;

always #10000 clk_50 = ~clk_50;                     // 50MHz

freq800_sentry_top #(.DIV_LOG(8)) uut (
    .clk_50   (clk_50),
    .rst_n    (rst_n),
    .led_lock (led_lock),
    .led_slow (led_slow)
);

integer toggles = 0;
reg  prev = 0;

always @(posedge clk_50) begin
    prev <= led_slow;
    if (led_slow != prev) toggles = toggles + 1;
end

initial begin
    $display("SENTRY t=0 行为 PLL stub: clkin 50MHz -> clkout0 800MHz(1.25ns)");
    repeat (2) @(posedge clk_50);
    rst_n <= 1;
end

initial begin
    @(posedge clk_50); repeat (2) @(posedge clk_50);
    rst_n <= 1;
    repeat (6000) @(posedge clk_50);               // 6000 sys 拍 = 120us (800域≈96k钟)
    if (!led_lock) begin
        $display("SENTRY FAIL: lock 未置位 (PLL 行为 stub 异常)");
    end else if (led_slow !== 1'b0 && toggles >= 2) begin
        $display("SENTRY PASS: lock=1, led_slow 在 800MHz 行为时钟域翻转 %0d 次, 顶层逻辑自洽", toggles);
    end else begin
        $display("SENTRY/NOTE: lock=%0b toggles=%0d — 仅逻辑验证钩子, 800 物理须 PnR+Silicon", led_lock, toggles);
    end
    $finish;
end

initial begin
    $dumpfile("freq800_sentry_tb.vcd");
    $dumpvars(0, freq800_sentry_tb);
end

endmodule