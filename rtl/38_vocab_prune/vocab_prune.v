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
module vocab_prune #(
    parameter VOC  = 512,     // 词表规模 (FAST 替身; P2≈320K)
    parameter GRP  = 8,       // 组大小
    parameter BB   = 16,      // acc 位宽
    parameter MAXE = 8,       // 窗口半径上限
    parameter FKXG = 0        // 远峰梯度 (M63: 默认0保持原合同; >0 线性抬升远词位, 激活 lbw 右支/远端钳) 
)(
    input  [BB-1:0] acc,      // 引擎累加 (logits 派生的代理输入)
    input  [3:0] xext,        // 候选窗半径 (0..MAXE)
    output wire [$clog2(VOC/GRP)-1:0] G,     // 峰组
    output wire [31:0] ncad,  // 候选数
    output wire [$clog2(VOC)-1:0] cand [0:(2*MAXE+1)*GRP-1]
);
    localparam NG = VOC/GRP;
    localparam CAP = (2*MAXE+1)*GRP;

    function integer fk(input integer a, input integer x);
        fk = (a*7 + x*17) % 23 + (FKXG * x);
    endfunction
    // 组内峰 (平局取小号先)
    function integer gpeak(input integer g, input integer a);
        integer b;
        integer i;
        b = fk(a, g*GRP);
        for (i = 1; i < GRP; i = i + 1)
            if (fk(a, g*GRP + i) > b) b = fk(a, g*GRP + i);
        gpeak = b;
    endfunction

    wire [31:0] grp [0:NG-1];
    genvar g;
    generate
        for (g = 0; g < NG; g = g + 1) begin: grp_g
            assign grp[g] = gpeak(g, acc);
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
            assign cand[i] = (i < ncad) ? (lbw + i) : lbw;
        end
    endgenerate
endmodule
`default_nettype wire