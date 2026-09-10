`timescale 1ps/1ps
`default_nettype none

// M9 wb_flow——层流调度 + 权重广播灌池(GEMM 段 g_ 侧主控)
//
// 基线 §5: 每层切片 = [S[L] 3MB][权重 632MB], 严格层序从家拉、逐层恰好一次,
// 批同步 barrier; 层与层间双缓冲——预取下一层要藏进当前层计算下。
// 本件 = P2 "93 层循环"骨架的 灌入+释放 两端:
//   · 家拉口 s_*(host/NVMe 模拟源)→ g_* 写池口; 词落池即广播(MAC/头窗读同一片)
//   · 双槽地图: 层 L 落槽 L&1, 只写 [槽基, 槽基+SLICE_W) —— 两槽交替
//   · 允许灌 L+1 当 rel >= L-1(前置槽让出)⇒ fill 至多领先 release 一层 = 真双缓冲
//   · 越序罪证: 释放层号 ≠ 已释放计数 → release_bad 置位(防下游乱序推翻层流前提)
//   · 簿记: overlap_cnt(预取藏进计算: 新层首词入池时前置层未释放)
//          barrier_stalls(槽位挡: 有词无槽的等待拍)  words_this(本层已灌)
//
// 纪律: 撤 valid/we 一律非阻塞; 计数位宽容 clog2(+1); 消费侧握手=电平 r_take。

module wb_flow #(
    parameter DW       = 32,   // 切片词宽(池口粒度)
    parameter AW       = 8,    // 池地址宽(须 ≥ 2*SLICE_W)
    parameter SLICE_W  = 16,   // 每层切片字数
    parameter NL       = 8     // 层数(实配 93)
)(
    input  wire               clk,
    input  wire               rst_n,
    input  wire               go,
    output reg                busy,

    // 家拉口(电平手拉手; 源=TB 组合逻辑, 同 M6 source 纪律)
    input  wire               s_valid,
    input  wire [DW-1:0]      s_data,
    output wire               s_ready,

    // 池写口(g_ 侧, GEMM 段持权)
    input  wire               g_rdy,
    output reg                g_valid,
    output reg                g_we,
    output reg  [AW-1:0]      g_addr,
    output reg  [DW-1:0]      g_wdata,

    // 下游层释放(严格层序; rl_layer 必须 == 已释放计数)
    input  wire               rl_valid,
    input  wire [$clog2(NL)-1:0] rl_layer,
    output reg                release_bad,

    // 簿记/观测
    output reg  [31:0]        layer_fill,   // 正在灌层(目标)
    output reg  [31:0]        layers_done,  // 已释放层数(== rel)
    output reg  [31:0]        words_this,   // 本层已灌字数
    output reg  [31:0]        overlap_cnt,  // 预取藏进计算 拍次/层次
    output reg  [31:0]        barrier_stalls// 槽位挡 拍数
);
    localparam LW = $clog2(SLICE_W + 1);   // 容终值
    localparam LB = $clog2(NL + 1);        // 层号位宽容终值 (lay 可达 NL)
    localparam RB = $clog2(NL + 1);        // 释放计数位宽容终值

    reg                    session;
    reg [LB-1:0]           lay;
    reg [LW-1:0]           fw;
    reg [RB-1:0]           rel;

    wire [31:0] lay32 = lay;   // 宽化便于 32 位比较, 与窄 reg 恒等
    wire [31:0] fw32  = fw;
    wire [31:0] rel32 = rel;

    wire allow_fill = session && (lay32 < NL) && ((lay32 == 0) || (rel32 + 1 >= lay32));
    wire [AW-1:0] waddr = (lay32[0] ? SLICE_W : 0) + fw32;

    assign s_ready = allow_fill;   // 电平征身: 与设备采样同拍, 源据此出词

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            session <= 0;
            busy    <= 0;
            lay     <= 0;
            fw      <= 0;
            rel     <= 0;
            g_valid <= 0;
            g_we    <= 0;
            g_addr  <= 0;
            g_wdata <= 0;
            release_bad <= 0;
            overlap_cnt <= 0;
            barrier_stalls <= 0;
            layer_fill <= 0;
            layers_done <= 0;
            words_this  <= 0;
        end
        else begin
            g_valid <= 0;
            g_we    <= 0;

            if (go && !session) begin
                session <= 1;
                busy    <= 1;
                lay     <= 0;
                fw      <= 0;
                rel     <= 0;
                release_bad <= 0;
                overlap_cnt <= 0;
                barrier_stalls <= 0;
            end
            else if (session) begin
                // ---- 释放口(与灌词互不影响; 电平保持至真 ack=幂等语义) ----
                if (rl_valid) begin
                    if (rl_layer == rel32[LB-1:0]) begin   // 期望的下一层: 消费推进
                        if (rel32 < NL) begin
                            rel <= rel + 1;
                            if (rel32 == NL - 1) begin     // 末层释放 = 整圈完工
                                session <= 0;
                                busy    <= 0;
                            end
                        end
                    end
                    else if (rl_layer > rel32[LB-1:0])
                        release_bad <= 1;   // 越序罪证: 释放超前于已消费计数
                    // 旧号(重复/滞后)静默幂等 —— 等真 ack 前电平保持属正常
                end

                // ---- 灌词(词即广播) ----
                if (allow_fill && s_valid && g_rdy) begin
                    g_valid <= 1;
                    g_we    <= 1;
                    g_addr  <= waddr;
                    g_wdata <= s_data;
                    if (fw32 == 0 && lay32 >= 1 && rel32 < lay32)
                        overlap_cnt <= overlap_cnt + 1;  // 前置层未释放=预取藏计算
                    if (fw32 == SLICE_W - 1) begin
                        lay <= lay + 1;                  // 切下一层(只增, 恰好一次)
                        fw  <= 0;
                    end
                    else
                        fw <= fw + 1;
                end
                else if (!allow_fill && s_valid && lay32 < NL)
                    barrier_stalls <= barrier_stalls + 1;
            end

            layer_fill <= lay;
            layers_done <= rel;
            words_this  <= fw;
        end
    end
endmodule