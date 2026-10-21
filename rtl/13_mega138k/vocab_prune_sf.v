`timescale 1ns/1ps
`default_nettype none
//────────────────────────────────────────────────────────────────────────────
// vocab_prune.v — M22 词表剪枝候选集生成器 (FAST 替身, 纯组合 assign)
//
// 契约 (board-1g-k3-frozen.md §9 embed/output 接入 "词表剪枝候选集验证随 PC 数据"):
//   输出头每 decode 步要读 12.8MB 全量 logits 扫 top-K; P2 冻词表≈320K, 全量扫
//   过贵 ⇒ 先按**廉价代理**缩出候选窗口, 输出头只扫候选 (冷门词不再逐字读全量)。
//   本件 = 代理: 词表按 GRP 一组, 每组先用组内峰代理分 (此处 = acc 派生 logits 的
//   组内最大值), 取峰组 G, 候选窗 = [G-xe, G+xe]×GRP (xe 半径钳到 MAXE, 窗边界
//   裁剪到 [0,VOC))。M22 在 FAST 全周期类遍历上证明: 窗口⊇真 top-K, 故 M19 只扫
//   候选仍得同一 top-K。真实 logits 分布另随 PC 数据核验; 本件固化机制与最小安全窗。
//   (全组合 assign 实现: 组峰→峰组链→窗口/候选表, 无 always, 避免电平敏感坑)
//────────────────────────────────────────────────────────────────────────────
module vocab_prune_sf #(
    parameter VOC  = 512,     // 词表规模 (FAST 替身; P2≈320K)
    parameter GRP  = 8,       // 组大小
    parameter BB   = 16,      // acc 位宽
    parameter MAXE = 8,       // 窗口半径上限
    parameter FKXG = 0        // 远峰梯度 (M63: 默认0保持原合同; >0 线性抬升远词位, 激活 lbw 右支/远端钳) 
)(
    input  wire [BB-1:0] acc,      // 引擎累加 (logits 派生的代理输入)
    input  wire [3:0] xext,        // 候选窗半径 (0..MAXE)
    output wire [$clog2(VOC/GRP)-1:0] G,     // 峰组
    output wire [31:0] ncad,  // 候选数
    output wire [CAP*$clog2(VOC)-1:0] cand_p   // SF3-P2: cand 打包 (ys0.68 无数组端口)
);
    localparam NG = VOC/GRP;
    localparam CAP = (2*MAXE+1)*GRP;

    // ── 假打分 fk(a,x) = (7a + 17x) mod 23 [+ FKXG*x] ─────────────────────
    // 硬件化改写 (2026-10-21): 原写法把 fk 整个展开成 34bit 乘加 + 34bit 取模,
    //   NG=VOC/GRP=64 时 = 1024 份取模 → Gowin 综合出 53 万 LUT,
    //   整包 board_decode_top 撞 RP0006 (533,752 > 器件 138,240)。
    // 改用模运算分配律 (数学恒等, 已穷举验证 a∈0..65535 × x∈0..1023 无一例外):
    //   (7a + 17x) mod 23 = ((7a mod 23) + (17x mod 23)) mod 23
    //   → 7a mod 23 全局只算一次 (19bit, 常量除法 → 乘法移位)
    //   → 17x mod 23: x = g*GRP+i 是编译期常量 → 常量表, 零逻辑
    //   → 每实例只剩 6bit 加 + 一次条件减
    // 语义逐位不变: 同样的 fk 值、同样的组内峰(平局取小号先)、同样的 grp[]。
    wire [18:0] acc7 = {3'b0, acc} * 19'd7;   // acc ≤ 65535 → ≤ 458745
    wire [4:0]  p23  = acc7 % 23;             // 全局唯一取模

    // 每候选 fk 值 (fv) + 组内前缀峰链 (gm), 组边界重置
    wire [15:0] fv [0:NG*GRP-1];
    wire [15:0] gm [0:NG*GRP-1];
    genvar t;
    generate
        for (t = 0; t < NG*GRP; t = t + 1) begin: fk_all
            localparam integer XCON = t;              // x = g*GRP + i (编译期常量)
            localparam [5:0]   QCON = (XCON*17) % 23; // 17x mod 23 → 常量表
            localparam [15:0]  FKG  = FKXG * XCON;    // FKXG 项 (FKXG=0 时折叠为 0)
            wire [5:0]  s    = {1'b0, p23} + QCON;    // p23+QCON ≤ 44
            wire [5:0]  sd   = s - 6'd23;             // s ≥ 23 时有效 (0..21)
            wire [15:0] fmod = (s >= 6'd23) ? {10'b0, sd} : {10'b0, s};
            assign fv[t] = fmod + FKG;
        end
    endgenerate
    generate
        for (t = 0; t < NG*GRP; t = t + 1) begin: mx_all
            if (t % GRP == 0) assign gm[t] = fv[t];   // 组首: 峰链重置
            else assign gm[t] = (fv[t] > gm[t-1]) ? fv[t] : gm[t-1]; // 严格 > → 平局取小号先
        end
    endgenerate

    wire [31:0] grp [0:NG-1];
    genvar g;
    generate
        for (g = 0; g < NG; g = g + 1) begin: grp_g
            assign grp[g] = gm[(g+1)*GRP - 1];        // 组内峰 = 组尾的峰链值
        end
    endgenerate

    // 峰组: 前缀链 argmax
    wire [$clog2(NG)-1:0] Gm [0:NG-1];
    assign Gm[0] = 0;
    generate
        for (g = 1; g < NG; g = g + 1) begin: gch_g
            assign Gm[g] = (grp[g] > grp[Gm[g-1]]) ? g : Gm[g-1];
        end
    endgenerate
    assign G = Gm[NG-1];

    // 窗口: [lbw, ubw) ∩ [0,VOC), 半径钳 MAXE
    wire [3:0] xe = (xext > MAXE[3:0]) ? MAXE[3:0] : xext;
    wire [31:0] lbw = (G > xe) ? (G - xe)*GRP : 0;
    wire [31:0] ubw = ((G + xe + 1)*GRP > VOC) ? VOC : (G + xe + 1)*GRP;
    assign ncad = (ubw > lbw) ? (ubw - lbw) : 0;

    genvar i;
    generate
        for (i = 0; i < CAP; i = i + 1) begin: cand_g
            assign cand_p[i*$clog2(VOC) +: $clog2(VOC)] = (i < ncad) ? (lbw + i) : lbw;
        end
    endgenerate
endmodule
`default_nettype wire