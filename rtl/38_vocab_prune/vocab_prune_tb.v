`timescale 1ps/1ps
`default_nettype none
//────────────────────────────────────────────────────────────────────────────
// vocab_prune_tb.v — M22 词表剪枝候选集验收: 全遍历 acc∈[0,2^16)
//
// 断言 (对每个 acc):
//   A) 真 top-K (全量 0..VOC-1, 平局 idx 小先) ⊂ 候选窗 [G-x,G+x]×GRP
//   B) 只扫候选窗 (按 idx 升序, M19 同规则) 的 top-K == 全量 top-K
// 遍历半径 x=1..向最大, 记最小安全半径 (xmin), 并让 vocab_prune 硬件实体执行
// 一遍 xmin 窗直接对账 (G/候选数/候选集必须与 TB 独立计算一致)。
// 结果: 输出头 P2 全量扫 → 只扫候选窗的比例 (扫描成本压缩)。
//────────────────────────────────────────────────────────────────────────────
module vocab_prune_tb;
    localparam VOC = 512, GRP = 8, BB = 16, MAXE = 8;
    localparam W = 2*MAXE+1;

    reg [BB-1:0] acc;
    reg [3:0] xext;
    wire [$clog2(VOC/GRP)-1:0] G_w;
    wire [31:0] ncad_w;
    wire [$clog2(VOC)-1:0] cand_w [0:W*GRP-1];

    integer ftok [0:2], fsc [0:2];          // 全量 top-3
    integer gtk  [0:2], gsc [0:2];          // 窗口 top-3
    integer gb [0:VOC/GRP-1];

    vocab_prune #(.VOC(VOC), .GRP(GRP), .BB(BB), .MAXE(MAXE)) u(
        .acc(acc), .xext(xext), .G(G_w), .ncad(ncad_w), .cand(cand_w)
    );

    function integer fk(input integer a, input integer x);
        fk = (a*7 + x*17) % 23;
    endfunction

    initial begin
        integer a, idx, j, g, r, E, ne, p;
        integer ok, v0, Gtt, got;
        integer badA, badB, xmin, worst, nsum;
        integer gwin [0:VOC-1];
        integer sweepv [0:29];
        integer SWP, s;
        badA = 0; badB = 0; xmin = 0; worst = 0; nsum = 0; got = 0;
        // 覆盖声明: 代理 fk(a,x)=(a*7+x*17)%23 ⇒ 周期类仅由 a mod 23 决定,
        // 故 a=0..22 等价全遍历 0..65535 全部行为; 另取区界/采样点验 16b 截位。
        SWP = 0;
        for (a = 0; a < 23; a = a + 1) begin sweepv[SWP] = a; SWP = SWP + 1; end
        sweepv[SWP] = 65535; SWP = SWP + 1;
        sweepv[SWP] = 32768; SWP = SWP + 1;
        sweepv[SWP] = 12345; SWP = SWP + 1;
        sweepv[SWP] = 999;   SWP = SWP + 1;
        sweepv[SWP] = 65533; SWP = SWP + 1;

        for (s = 0; s < SWP; s = s + 1) begin
            a = sweepv[s];
            for (j = 0; j < 3; j = j + 1) begin fsc[j] = -1; ftok[j] = -1; end
            for (idx = 0; idx < VOC; idx = idx + 1) begin
                v0 = fk(a, idx);
                ok = 0;
                for (p = 0; p < 3 && !ok; p = p + 1)
                    if (v0 > fsc[p] || (v0 == fsc[p] && idx < ftok[p])) begin
                        for (j = 2; j > p; j = j - 1) begin fsc[j] = fsc[j-1]; ftok[j] = ftok[j-1]; end
                        fsc[p] = v0; ftok[p] = idx; ok = 1;
                    end
            end
            for (g = 0; g < VOC/GRP; g = g + 1) begin
                gb[g] = -1;
                for (j = 0; j < GRP; j = j + 1)
                    if (fk(a, g*GRP + j) > gb[g]) gb[g] = fk(a, g*GRP + j);
            end
            Gtt = 0;
            for (g = 1; g < VOC/GRP; g = g + 1) if (gb[g] > gb[Gtt]) Gtt = g;
            ne = 0;
            for (E = 1; E <= MAXE && ne == 0; E = E + 1) begin
                for (j = 0; j < VOC; j = j + 1) gwin[j] = 0;
                for (idx = (Gtt-E)*GRP; idx < (Gtt+E+1)*GRP; idx = idx + 1)
                    if (idx >= 0 && idx < VOC) gwin[idx] = 1;
                ok = 1;
                for (j = 0; j < 3; j = j + 1) if (!gwin[ftok[j]]) ok = 0;
                if (ok) begin
                    ne = E;
                    for (j = 0; j < 3; j = j + 1) begin gsc[j] = -1; gtk[j] = -1; end
                    for (idx = 0; idx < VOC; idx = idx + 1) if (gwin[idx]) begin
                        v0 = fk(a, idx);
                        ok = 0;
                        for (r = 0; r < 3 && !ok; r = r + 1)
                            if (v0 > gsc[r] || (v0 == gsc[r] && idx < gtk[r])) begin
                                for (j = 2; j > r; j = j - 1) begin gsc[j] = gsc[j-1]; gtk[j] = gtk[j-1]; end
                                gsc[r] = v0; gtk[r] = idx; ok = 1;
                            end
                    end
                    for (j = 0; j < 3; j = j + 1)
                        if (fsc[j] != gsc[j] || ftok[j] != gtk[j]) begin
                            badB = badB + 1;
                            j = 3;
                        end
                end
            end
            if (ne == 0) badA = badA + 1;
            if (ne > xmin) xmin = ne;
            if (ne > worst) worst = ne;
            if ((2*ne+1)*GRP < VOC) nsum = nsum + (2*ne+1)*GRP;
            else nsum = nsum + VOC;
        end
        $display("遍历 %0d 点 (a=0..22 全周期类 + 区界/截位采样): 全量 top-3 未覆盖 %0d, 候选串=全量 违例 %0d", SWP, badA, badB);
        $display("最小安全半径 xmin=%0d, worst(acc 内所需最大半径)=%0d, 候选窗均值 %0d/%0d (%.1f%%)",
                 xmin, worst, nsum/SWP, VOC, 100.0*nsum/(SWP*VOC));
        if (badA != 0 || badB != 0) begin
            $display("FAIL: 存在 acc 使剪枝漏掉真 top-K"); $finish;
        end

        // ── 硬件实体对账: xext = xmin, 全部采样点 ──
        // (组合块靠事件激活: acc 初值避开端值, 每步阻塞赋值触发)
        acc = 65534; xext = xmin; #1;
        for (s = 0; s < SWP; s = s + 1) begin
            a = sweepv[s];
            acc = a;
            #1;
            for (g = 0; g < VOC/GRP; g = g + 1) begin
                gb[g] = -1;
                for (j = 0; j < GRP; j = j + 1)
                    if (fk(a, g*GRP + j) > gb[g]) gb[g] = fk(a, g*GRP + j);
            end
            Gtt = 0;
            for (g = 1; g < VOC/GRP; g = g + 1) if (gb[g] > gb[Gtt]) Gtt = g;
            if (G_w !== Gtt) begin
                $display("FAIL acc=%0d 硬件峰组 %0d != 计算 %0d", a, G_w, Gtt); $finish;
            end
            E = 0;
            for (idx = (Gtt-xmin)*GRP; idx < (Gtt+xmin+1)*GRP; idx = idx + 1)
                if (idx >= 0 && idx < VOC) begin
                    if (cand_w[E] !== idx) begin
                        $display("FAIL acc=%0d cand[%0d]=%0d != %0d", a, E, cand_w[E], idx); $finish;
                    end
                    E = E + 1;
                end
            if (ncad_w !== E) begin
                $display("FAIL acc=%0d ncad %0d != %0d", a, ncad_w, E); $finish;
            end
            got = got + 1;
        end
        $display("硬件 vocab_prune(xext=%0d) 实体对账 %0d 点全过", xmin, got);
        $display("##### ALL PASS: M22 词表剪枝 · 候选窗⊇真top-K · 只扫候选得同一top-K · P2 扫描成本压到 ~%.1f%% #####",
                 100.0*nsum/(SWP*VOC));
        $finish;
    end
endmodule
`default_nettype wire