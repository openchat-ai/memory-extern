// 800MHz 可行性哨兵 (freq800_sentry)
// 实验目的(PC 侧): 确认 Gowin PLL 能否直出 800、fabric 时钟树能否承载 800、
//                  800 域 FF 是否能在 1.25ns 周期可靠翻转。
// 物理真 800 只有 PnR/Silicon 能判; termux 侧仅验证哨兵逻辑本身(分频/回采/判活)。
// 观测:
//   led_lock : PLL lock(50MHz 域) 常亮=锁相
//   led_slow : 800MHz 域递减计数, 分频到 ~0.75Hz (DIV_LOG=30) 驱动 LED
//              若 800 域 FF 在 1.25ns 周期崩溃 → led_slow 停摆/无周期(判活点)
//   哨兵尺寸: 1 个 PLL + 1 个 N 位计数器, 资源 <0.05%

module freq800_sentry_top (
    input  wire clk_50,   // P16 板载 50MHz
    input  wire rst_n,    // K16
    output wire led_lock, // 与现有板 LED 复用: led[0]
    output wire led_slow  // led[1]
);

parameter DIV_LOG = 30;  // 综合现场用 30 (~0.75Hz); tb 模拟用 8

wire clk_800;
wire lock;

Gowin_PLL_X800 u_pll (
    .clkout0(clk_800),
    .lock   (lock),
    .clkin  (clk_50)
);

reg [DIV_LOG:0] cnt;

always @(posedge clk_800 or negedge rst_n) begin
    if (!rst_n)
        cnt <= {DIV_LOG+1{1'b0}};
    else
        cnt <= cnt + 1'b1;
end

assign led_lock = lock;
assign led_slow = cnt[DIV_LOG];

endmodule