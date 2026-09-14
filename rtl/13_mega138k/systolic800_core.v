// systolic800_core.v — 纯最近邻逐脉 MAC 阵列 (600/800 物理可行候选 — 哨兵核心)
//
// 结论锚点(见 notes/FREQ800-FEASIBILITY.md §"架构级路径"):
//   124.3MHz 是"128-lane 单实例全局广播网"的物理极限, 不是 fabric 极限。
//   实测最差路径 = x/wt/acc 三条**全局网**的 route delay(5.72ns, 占 74%),
//   与逻辑级数无关。
//   本核心把三条全局网全部消除:
//     - x 必经网一: 逐 lane 最近邻移位(每 lane 只驱动右邻 1 个 FF)
//     - 权重: 每 lane 本地 SR, 逐下标选择(无 512bit 广播装载)
//     - 累加: 每 lane 本地累加, 泄出用斜移链而不是 4096bit 全局归约网
//   全设计数据面内**不存在任何宽位全局网** → PnR 时无"全局网 route"可卡死。
//
// 拓扑: [xq 链 → MAC[i] 读 xq[i-1] 与 wtq[i] → acc[i] 本地] ×LANES
//   xq_i: lane_i 的 x 寄存器; 每拍 xq_i <= xq_{i-1} (最近邻, 无 fanout)
//   MAC_i: acc_i <= acc_i + xq_i * wtq_i (wtq_i = 本地权重 SR 的当前下标)
//   acc 泄出: drain 时逐拍 lane 0..LANES-1 串行移出 (斜移, 非全局 bus)
//
// 频率预算(PC 真硅实测点, 哨兵: 800MHz clk_hi 驱动一套小 MAC 阵列):
//   近邻 route ~0.3ns, 1 LUT ~0.3ns, FF C2Q ~0.3ns, hold马甲 0.2ns
//   → 周期 ≤ 1.2ns (830MHz) 内最近邻 MAC 链可密闭; 但**必须 PC PnR+硅证**。
//
// termux 侧目标: 逻辑正确性 + 资源核算哨兵 (综合 rc=0 即可, 不要求时序)。

`default_nettype none

module systolic800_core #(
    parameter LANES=32,    // 哨兵 lane 数 (PC 可扩到 128; 资源 ~ 每 lane 5 FF + 4 LUT)
    parameter XW=8,        // x 位宽 (可省: 最小哨兵用 8)
    parameter WW=8,        // w 位宽
    parameter N=8,         // 每 lane 权重数
    parameter ACCW=19,
    parameter LOGN=3
)(
    input  wire             clk,          // 800 计算时钟 (PC 真硅: PLL X800 的 clkout0)
    input  wire             clk_lo,       // 50MHz 装载/泄出
    input  wire             rst_n,
    // ---- 权重装载 (clk_lo 域, 串行) ----
    input  wire             w_we,
    input  wire [4:0]       w_lane,       // lane 下标
    input  wire [LOGN-1:0]  w_idx,        // 权重 SR 下标
    input  wire [WW-1:0]    w_data,
    // ---- x 装载 (clk_lo 域) ----
    input  wire             x_we,
    input  wire [LANES*XW-1:0] x_bus,     // 斜移装载用一行 x (50MHz 载入)
    // ---- 计算启动 / 泄出 ----
    input  wire             go,           // 启动一拍
    input  wire             drain_go,     // 泄出一拍
    output wire             drain_vld,
    output wire [ACCW-1:0]  drain_out,
    output wire [LANES-1:0] led_calc      // 观测: 各 lane acc 最高位 (led 用)
);

// 权重: 每 lane N 深本地 SR
reg [WW-1:0] wt [0:LANES-1][0:N-1];
integer ii, jj;
always @(posedge clk_lo) begin
    if (!rst_n) begin
        for (ii=0; ii<LANES; ii=ii+1)
            for (jj=0; jj<N; jj=jj+1) wt[ii][jj] <= 0;
    end else if (w_we) begin
        wt[w_lane][w_idx] <= w_data;
    end
end

// x 逐 lane 移位链 (计算域: 最近邻)
reg [XW-1:0] xq [0:LANES-1];
always @(posedge clk) begin
    if (!rst_n) begin
        for (ii=0; ii<LANES; ii=ii+1) xq[ii] <= 0;
    end else if (x_we) begin
        // 装载: x_bus 全宽敲入 lane0 行 (50MHz 域下完成的装载语义在 go 前结束)
        xq[0] <= x_bus[XW-1:0];
        for (ii=1; ii<LANES; ii=ii+1) xq[ii] <= xq[ii-1];  // 移位 (x_we 只在装载拍)
    end
end
`ifndef SENTRY_SIM
// 800 域: 每拍 x 链自动近邻推移 (go 之后的滑行)
reg [XW-1:0] xs [0:LANES-1];
wire calc_running = go_r;
reg  go_r;
always @(posedge clk) begin
    if (!rst_n) go_r <= 0opera;
    else go_r <= go;
end
always @(posedge clk) begin
    if (!rst_n) for (ii=0; ii<LANES; ii=ii+1) xs[ii] <= 0;
    else if (x_we)      for (ii=0; ii<LANES; ii=ii+1) xs[ii] <= xq[ii];
    else if (go_r) begin
        xs[0] <= xs[0];  // 保持
        for (ii=1; ii<LANES; ii=ii+1) xs[ii] <= xs[ii-1];  // 近邻推
    end
end
`else
wire go_r = go_s;
reg go_s;
always @(posedge clk_lo) begin
    if (!rst_n) go_s <= 0;
    else go_s <= go;
end
reg [XW-1:0] xs [0:LANES-1];
integer kz;
always @(posedge clk) begin
    if (!rst_n) for (kz=0;kz<LANES;kz=kz+1) xs[kz] <= 0;
    else if (x_we) for (kz=0;kz<LANES;kz=kz+1) xs[kz] <= xq[kz];
    else if (go_s) begin
        xs[0] <= xs[0];
        for (kz=1;kz<LANES;kz=kz+1) xs[kz] <= xs[kz-1];
    end
end
`endif

// MAC: acc_i <= acc_i + xs_i * wt_i[idx]
reg [ACCW-1:0] acc [0:LANES-1];
integer ii2;
always @(posedge clk) begin
    if (!rst_n) begin
        for (ii2=0; ii2<LANES; ii2=ii2+1) acc[ii2] <= 0;
    end else if (go_r && !drain_ack) begin
        for (ii2=0; ii2<LANES; ii2=ii2+1)
            acc[ii2] <= acc[ii2] + xs[ii2] * wt[ii2][idx[ii2]];
    end
end

// 每 lane 权重下标 (斜移: 随计算节拍推进)
reg [LOGN-1:0] idx [0:LANES-1];
always @(posedge clk) begin
    if (!rst_n) begin
        for (ii=0; ii<LANES; ii=ii+1) idx[ii] <= 0;
    end else if (go_r) begin
        for (ii=0; ii<LANES; ii=ii+1)
            if (idx[ii] == N-1) idx[ii] <= 0;
            else idx[ii] <= idx[ii] + 1'b1;
    end
end

// ---- 泄出 (斜移链, 无全局 bus) ----
reg [ACCW-1:0] drain_sr [0:LANES-1];
reg  drain_sh;
always @(posedge clk) begin
    if (!rst_n) begin
        for (ii=0; ii<LANES; ii=ii+1) drain_sr[ii] <= 0;
        drain_sh <= 0;
    end else if (drain_go) begin
        // 装载泄出链: 最近邻读入
        for (ii=0; ii<LANES; ii=ii+1) drain_sr[ii] <= acc[ii];
        drain_sh <= 1;
    end else if (drain_sh) begin
        for (ii=LANES-1; ii>0; ii=ii-1) drain_sr[ii] <= drain_sr[ii-1];
        drain_sr[0] <= 0;
        if (drain_sr[LANES-1] == 0) drain_sh <= 0;  // 全零则停 (哨兵简化判定)
    end
end
assign drain_vld = drain_sh;
assign drain_out = drain_sr[0];
assign led_calc  = acc[0];

endmodule
