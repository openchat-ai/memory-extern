// freq800_sentry_top — 哨兵(termux 侧真可闭环: PLL 时钟实体不在, 逻辑自验)
// 哨兵职责: 800 域 5bit 计数器 → led_slow(翻转可观测); lock 同步链到 50 域 → led_lock/go。
// 物理 800 时钟实体 = PC 烧录哨兵清单(notes/FREQ800-FEASIBILITY.md §4), 非本 file。
`default_nettype none
module freq800_sentry_top #(
    parameter SLOWLOG = 5       // 哨兵观测: 800 域计数位 → 翻转可观测(termux tb 3000拍必翻)
)(
    input  wire clk_800,        // 800 域(termux tb: 行为 800 时钟; PC: PLL-X800 clkout0)
    input  wire clk_50,
    input  wire rst_n,
    input  wire pll_lock,       // PC: PLL lock; termux tb: 行为 lock
    output wire led_lock,       // led[0](L25)
    output wire led_slow,       // led[1](M25): 哨兵翻转
    output wire led_go          // led[2](R26)
);
reg [SLOWLOG:0] cnt;
always @(posedge clk_800 or negedge rst_n) begin
    if (!rst_n) cnt <= 0;
    else cnt <= cnt + 1'b1;
end
reg la, lb;
always @(posedge clk_50 or negedge rst_n) begin
    if (!rst_n) begin la <= 0; lb <= 0; end
    else begin la <= pll_lock; lb <= la; end
end
assign led_lock = lb;
assign led_slow = cnt[SLOWLOG];
assign led_go   = lb;
endmodule
