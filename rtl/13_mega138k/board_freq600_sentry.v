`default_nettype none
// board_freq600_sentry — 600 哨兵板级顶层 (key-LED 诊断复用版)
// PLL-X600(50M→600M) + freq800_sentry_top(复用, 纯计数器哨兵); 3 key + 3 LED:
// 视图同 800 版(见 board_freq800_sentry.v), 唯一区别 PLL 实体 + 时钟名 clk_600
module board_freq600_sentry (
    input  wire sys_clk,
    input  wire rst_n,
    input  wire key1,
    input  wire key2,
    input  wire key3,
    output wire led_lock,
    output wire led_slow,
    output wire led_go
);

// 复用3 LED (J14/R26/M25) 输出到可疑脚, 上层用诊断视图重驱动
// ── 内部信号 ──
wire clk_600;
wire pll_lock;

Gowin_PLL_X600 u_pll (
    .clkout0(clk_600),
    .lock   (pll_lock),
    .clkin  (sys_clk)
);

wire [27:0] cnt;

freq800_sentry_top #(
    .SLOWLOG(5)
) u_sentry (
    .clk_800 (clk_600),
    .clk_50  (sys_clk),
    .rst_n   (rst_n),
    .pll_lock(pll_lock),
    .cnt_o   (cnt)
);

// ── clk_50 心跳计数器 ──
reg [27:0] hb;
always @(posedge sys_clk or negedge rst_n) begin
    if (!rst_n) hb <= 0;
    else hb <= hb + 1'b1;
end

// ── 同步链(从 sentry 重建: la/lb 是 sentry 内部, 这里重采样一份供 101 视图) ──
reg la_dbg, lb_dbg;
always @(posedge sys_clk or negedge rst_n) begin
    if (!rst_n) begin la_dbg <= 0; lb_dbg <= 0; end
    else begin la_dbg <= pll_lock; lb_dbg <= la_dbg; end
end

// ── key-LED 诊断多路复用 (归一化: 1=亮, 0=灭) ──
wire [2:0] k = {~key3, ~key2, ~key1};   // 按下检测(共阳低亮)
reg lock_s, slow_s, go_s;

always @(*) begin
    casez (k)
        3'b000: begin lock_s = pll_lock;  slow_s = cnt[5];   go_s = cnt[4];  end
        3'b001: begin lock_s = cnt[3];    slow_s = cnt[2];   go_s = cnt[1];  end
        3'b010: begin lock_s = cnt[7];    slow_s = cnt[6];   go_s = cnt[5];  end
        3'b011: begin lock_s = cnt[27];   slow_s = cnt[26];  go_s = cnt[25]; end
        3'b100: begin lock_s = hb[25];    slow_s = hb[24];   go_s = hb[23];  end
        3'b101: begin lock_s = pll_lock;  slow_s = lb_dbg;   go_s = la_dbg;  end
        3'b110: begin lock_s = hb[17];    slow_s = hb[16];   go_s = hb[15];  end
        3'b111: begin lock_s = pll_lock;  slow_s = pll_lock; go_s = pll_lock; end
    endcase
end

// 最后 1=亮: LED 共阳低亮 → 输出 = ~信号翻转
assign led_lock = ~lock_s;
assign led_slow = ~slow_s;
assign led_go   = ~go_s;

endmodule