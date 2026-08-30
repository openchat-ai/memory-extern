// ============================================================================
// path_mux.v — 按 links_detect 锁定的路径, 选通统一权重流出口(GEMV)
//
// 两条路径的缓存控制器各自产出"统一权重流"(wtv_*/wtd_*), 本模块按 sel 选通
// 其一作为对外唯一出口 wt_valid/wt_data, 并把 GEMV 的回程 ready 反向门控回
// 对应路径(未选中路径被 ready 刹停, 不吞数据)。locked=0(尚未识别) 时强制
// 不输出, 防止识别期权重流混入 GEMV。
//
// GEMV(engine_core/gemv_engine) 只认这一个 wt_valid/wt_data/wt_ready 口,
// 因此无论 SSD 落在哪条路径(本地/主机), GEMV 全程无感知 —— 自动切换成立。
// ============================================================================

`timescale 1ns/1ps

module path_mux #(
    parameter DW = 32          // 权重流字位宽(与 gemv_engine wt_data 一致)
)(
    input  wire clk,
    input  wire rst_n,

    // ---- 控制器: 锁定 + 路径选择 ----
    input  wire sel,           // 0=路径1(本地), 1=路径2(主机)
    input  wire locked,

    // ---- 路径1 缓存控制器输出(本地 SerDes/板上M.2) + 回程 ready ----
    input  wire [DW-1:0] wtd_a,
    input  wire        wtv_a,
    output wire        wtr_a,

    // ---- 路径2 缓存控制器输出(主机 PCIe/主机M.2) + 回程 ready ----
    input  wire [DW-1:0] wtd_b,
    input  wire        wtv_b,
    output wire        wtr_b,

    // ---- 统一出口 <-> GEMV ----
    output wire        wt_valid,
    output wire [DW-1:0] wt_data,
    input  wire        wt_ready_gnv
);

    // 未锁定 -> 不放任何权重, 暂停两路
    // 锁定 -> 只放选中路径; 未选中路径 ready=0 刹停
    assign wt_valid = locked & (sel ? wtv_b : wtv_a);
    assign wt_data  = sel ? wtd_b : wtd_a;

    // 选中路径收到 GEMV ready; 未选中路径停
    assign wtr_a = locked & ~sel & wt_ready_gnv;
    assign wtr_b = locked &  sel & wt_ready_gnv;

endmodule
