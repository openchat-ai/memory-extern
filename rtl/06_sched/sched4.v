`timescale 1ns/1ps
// 06_sched — 三级预取调度器 RTL 模型，索引哈希槽阵列版（sched4）。
//
// 与 sched3（全相联 CAM）的对照：
//   sched3: 每个槽存完整 tag，访问时 13 个比较器全并行找匹配（CAM 全展开，
//           综合 10283 cells / 605 FF，README 点名"不是实现模板"）。
//   sched4: 槽按索引直接寻址（SRAM-like）。L1 = L1S 组 × L1W 路，
//           组内 WAYS 个 tag 寄存器 + WAYS 个比较器（index 决定组，组内小比较）。
//           消灭全相联比较网络，面积主要剩寄存器阵列 + 少量比较器。
//
// 索引哈希: idx = tag[INDBITS-1:0]，即 tag 低位选组（k3 trace 实测分布均匀）。
// 路内查找: 组内每路存完整 tag，命中只在该组 WAYS 路内比较。
// 替换:    每组独立 LRU（rank 模型，与 cache4 同训），miss 只在组内淘汰。
//
// 统计端口保持与 sched3 相同签名（s_hit/s_miss/s_l0/s_l1/s_pf/s_pref/s_prefok），
// 便于 check.sh 回归直接对拍。L0 仍为 pinned 4 槽全相联（只有 4 个比较器，成本可忽略）。
module selfsched4 #(
    parameter AW   = 16,
    parameter L0N  = 4,
    parameter L1S  = 4,          // L1 组数
    parameter L1W  = 2,          // L1 路数（组内）
    parameter P1S  = 4,          // L1.5 组数
    parameter P1W  = 1           // L1.5 路数（组内）
)(
    input  wire          clk,
    input  wire          rst,
    input  wire          req,
    input  wire [AW-1:0] tag,
    input  wire          pf_req,
    input  wire [AW-1:0] pf_tag,
    input  wire          hot_wen,
    input  wire [1:0]    hot_addr,
    input  wire [AW-1:0] hot_data,
    output reg  [31:0]   s_hit,
    output reg  [31:0]   s_miss,
    output reg  [31:0]   s_l0,
    output reg  [31:0]   s_l1,
    output reg  [31:0]   s_pf,
    output reg  [31:0]   s_pref,
    output reg  [31:0]   s_prefok
);

    localparam L1IDX = $clog2(L1S);   // L1 组索引位
    localparam P1IDX = $clog2(P1S);   // L1.5 组索引位
    localparam L1RK  = L1W > 1 ? $clog2(L1W) : 1;   // L1 组内 rank 位宽（≥1）
    localparam P1RK  = P1W > 1 ? $clog2(P1W) : 1;   // L1.5 组内 rank 位宽（≥1）

    // —— L0 热表（pinned，全相联，仅 4 比较器）
    reg [AW-1:0]  hot[0:L0N-1];
    reg           hot_v[0:L0N-1];

    // —— L1 组相联 LRU: tgt[s][w], val[s][w], rnk[s][w]（组内 0=MRU .. W-1=LRU）
    reg [AW-1:0]  l1t [0:L1S-1][0:L1W-1];
    reg           l1v [0:L1S-1][0:L1W-1];
    reg [L1RK-1:0] l1r [0:L1S-1][0:L1W-1];

    // —— L1.5 组相联预取池（同样索引哈希）
    reg [AW-1:0]  pft [0:P1S-1][0:P1W-1];
    reg           pfv [0:P1S-1][0:P1W-1];
    reg [P1RK-1:0] pfr [0:P1S-1][0:P1W-1];

    integer i, j, k;
    reg [L1IDX-1:0] l1idx;
    reg [P1IDX-1:0] p1idx;
    reg    found;
    reg    path0, path1, pathp;
    integer hw;          // 命中路
    integer lw;          // 替换路
    integer maxr;

    // 全部阻塞赋值：沿上读旧快照、写新快照，天然原子（与 cache4/sched3 同训）。
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            for (i = 0; i < L0N; i = i + 1) begin hot[i] = 0; hot_v[i] = 0; end
            for (i = 0; i < L1S; i = i + 1)
                for (j = 0; j < L1W; j = j + 1) begin
                    l1t[i][j] = 0; l1v[i][j] = 0; l1r[i][j] = j[L1RK-1:0];
                end
            for (i = 0; i < P1S; i = i + 1)
                for (j = 0; j < P1W; j = j + 1) begin
                    pft[i][j] = 0; pfv[i][j] = 0; pfr[i][j] = j[P1RK-1:0];
                end
            s_hit = 0; s_miss = 0; s_l0 = 0; s_l1 = 0; s_pf = 0;
            s_pref = 0; s_prefok = 0;
        end else begin

            // ============ L0 热表在线加载 ============
            if (hot_wen) begin
                hot[hot_addr] = hot_data;
                hot_v[hot_addr] = 1'b1;
            end

            // ============ 预取装入（同沿先做，不参与本拍访问判定）============
            if (pf_req) begin
                p1idx = pf_tag[P1IDX-1:0];
                // 去重：L0（全相联小比较）
                found = 0;
                for (i = 0; i < L0N; i = i + 1)
                    if (hot_v[i] && hot[i] == pf_tag) found = 1;
                // L1（组内比较）
                if (!found)
                    for (j = 0; j < L1W; j = j + 1)
                        if (l1v[l1idx_sel(pf_tag)][j] && l1t[l1idx_sel(pf_tag)][j] == pf_tag) found = 1;
                // 预取池组内
                if (!found)
                    for (j = 0; j < P1W; j = j + 1)
                        if (pfv[p1idx][j] && pft[p1idx][j] == pf_tag) found = 1;
                if (!found) begin
                    // 组内找空槽 else 组内 LRU 路
                    lw = -1;
                    for (j = 0; j < P1W; j = j + 1)
                        if (!pfv[p1idx][j]) begin lw = j; j = P1W + 1; end
                    if (lw < 0) begin
                        maxr = -1; lw = 0;
                        for (j = 0; j < P1W; j = j + 1)
                            if (pfr[p1idx][j] > maxr) begin maxr = pfr[p1idx][j]; lw = j; end
                    end
                    pft[p1idx][lw] = pf_tag;
                    pfv[p1idx][lw] = 1'b1;
                    pfr[p1idx][lw] = 0;
                    for (j = 0; j < P1W; j = j + 1)
                        if (j != lw && pfr[p1idx][j] < P1W - 1)
                            pfr[p1idx][j] = pfr[p1idx][j] + 1'b1;
                    s_pref = s_pref + 1;
                end
            end

            // ============ 访问判定（沿前已提交的状态）============
            if (req) begin
                l1idx = tag[L1IDX-1:0];
                p1idx = tag[P1IDX-1:0];
                path0 = 0; path1 = 0; pathp = 0; found = 0;

                for (i = 0; i < L0N; i = i + 1)
                    if (hot_v[i] && hot[i] == tag) begin path0 = 1; found = 1; end

                if (!found)
                    for (j = 0; j < L1W; j = j + 1)
                        if (l1v[l1idx][j] && l1t[l1idx][j] == tag) begin path1 = 1; found = 1; end

                if (!found)
                    for (j = 0; j < P1W; j = j + 1)
                        if (pfv[p1idx][j] && pft[p1idx][j] == tag) begin pathp = 1; found = 1; end

                if (path0) begin
                    s_l0 = s_l0 + 1;
                    s_hit = s_hit + 1;
                end else if (path1) begin
                    s_l1 = s_l1 + 1;
                    s_hit = s_hit + 1;
                    // L1 组内 recency 更新（命中路归 0，其余 +1）
                    hw = -1;
                    for (j = 0; j < L1W; j = j + 1)
                        if (l1v[l1idx][j] && l1t[l1idx][j] == tag) hw = j;
                    l1r[l1idx][hw] = 0;
                    for (j = 0; j < L1W; j = j + 1)
                        if (j != hw && l1r[l1idx][j] < L1W - 1)
                            l1r[l1idx][j] = l1r[l1idx][j] + 1'b1;
                end else if (pathp) begin
                    s_pf  = s_pf + 1;
                    s_prefok = s_prefok + 1;
                    s_hit = s_hit + 1;
                    // 移入 L1（命中路所在组），清预取池对应条目
                    hw = -1;
                    for (j = 0; j < P1W; j = j + 1)
                        if (pfv[p1idx][j] && pft[p1idx][j] == tag) hw = j;
                    if (hw >= 0) pfv[p1idx][hw] = 0;
                    lw = -1;
                    for (j = 0; j < L1W; j = j + 1)
                        if (!l1v[l1idx][j]) begin lw = j; j = L1W + 1; end
                    if (lw < 0) begin
                        maxr = -1; lw = 0;
                        for (j = 0; j < L1W; j = j + 1)
                            if (l1r[l1idx][j] > maxr) begin maxr = l1r[l1idx][j]; lw = j; end
                    end
                    if (lw >= 0) begin
                        l1t[l1idx][lw] = tag;
                        l1v[l1idx][lw] = 1'b1;
                        l1r[l1idx][lw] = 0;
                        for (j = 0; j < L1W; j = j + 1)
                            if (j != lw && l1r[l1idx][j] < L1W - 1)
                                l1r[l1idx][j] = l1r[l1idx][j] + 1'b1;
                    end
                end else begin
                    s_miss = s_miss + 1;
                    // miss：装入 L1 组内空槽 else 组内 LRU 路
                    lw = -1;
                    for (j = 0; j < L1W; j = j + 1)
                        if (!l1v[l1idx][j]) begin lw = j; j = L1W + 1; end
                    if (lw < 0) begin
                        maxr = -1; lw = 0;
                        for (j = 0; j < L1W; j = j + 1)
                            if (l1r[l1idx][j] > maxr) begin maxr = l1r[l1idx][j]; lw = j; end
                    end
                    if (lw >= 0) begin
                        l1t[l1idx][lw] = tag;
                        l1v[l1idx][lw] = 1'b1;
                        l1r[l1idx][lw] = 0;
                        for (j = 0; j < L1W; j = j + 1)
                            if (j != lw && l1r[l1idx][j] < L1W - 1)
                                l1r[l1idx][j] = l1r[l1idx][j] + 1'b1;
                    end
                end
            end
        end
    end

    // 组索引选择（函数：取 tag 低位）
    function automatic [L1IDX-1:0] l1idx_sel;
        input [AW-1:0] t;
        begin l1idx_sel = t[L1IDX-1:0]; end
    endfunction

endmodule
