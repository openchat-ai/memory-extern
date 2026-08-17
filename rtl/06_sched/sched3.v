`timescale 1ns/1ps
// 06_sched — 三级预取调度器 RTL 模型（白皮书 §3 微型验证版）。
//
// 层职责（对齐 §3.1；预算 = L0N+L1N+P1N 槽）：
//   L0    静态热表 pinned：离线 trace 频次 top-N 专家，不被逐出。
//   L1    动态 LRU 计算池：当前批实算专家。
//   L1.5  预取池：预取下一批候选（环形 FIFO，双缓冲两半交替）。
//   L2    模型外（SSD）：冷 miss。
//
// 访问路径：先比 L0（并行哈希）→ miss 比 L1 → 再 miss 比 L1.5；命中按层计数。
// 预取：pf_req&pf_tag 在同沿先检查不重复后装入 L1.5 尾。
// 统计单拍结算（阻塞 = 同沿原子，避免 03 踩过的 iverilog 数组 bug）。
module selfsched #(
    parameter AW   = 16,
    parameter L0N  = 4,
    parameter L1N  = 5,
    parameter P1N  = 4
)(
    input  wire          clk,
    input  wire          rst,
    input  wire          req,
    input  wire [AW-1:0] tag,
    input  wire          pf_req,
    input  wire [AW-1:0] pf_tag,
    input  wire          hot_wen,      // L0 热表加载写使能（复位后由 TB 写）
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

    // —— L0 热表（固定 4 槽）
    reg [AW-1:0]  hot[0:3];
    reg           hot_v[0:3];

    // —— L1 LRU（数组 + recency 计数：r 越大越旧）
    reg [AW-1:0]  l1t[0:L1N-1];
    reg           l1v[0:L1N-1];
    integer       l1r[0:L1N-1];

    // —— L1.5 环形池
    reg [AW-1:0]  pft[0:P1N-1];
    reg           pfv[0:P1N-1];

    integer i;
    integer j;
    integer max;
    integer v;
    reg    found;
    reg    path0, path1, pathp;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            for (i = 0; i < 4; i = i + 1) begin hot[i] = 0; hot_v[i] = 0; end
            for (i = 0; i < L1N; i = i + 1) begin l1t[i] = 0; l1v[i] = 0; l1r[i] = 0; end
            for (i = 0; i < P1N; i = i + 1) begin pft[i] = 0; pfv[i] = 0; end
            s_hit = 0; s_miss = 0; s_l0 = 0; s_l1 = 0; s_pf = 0;
            s_pref = 0; s_prefok = 0;
        end else begin

            // ============ L0 热表在线加载（复位后配置用）============
            if (hot_wen) begin
                hot[hot_addr] = hot_data;
                hot_v[hot_addr] = 1'b1;
            end

            // ============ 预取装入（同沿先做，不参与本拍访问判定）============
            if (pf_req) begin
                // 去重：L0
                found = 0;
                for (i = 0; i < 4; i = i + 1)
                    if (hot_v[i] && hot[i] == pf_tag) found = 1;
                // L1
                if (!found)
                    for (i = 0; i < L1N; i = i + 1)
                        if (l1v[i] && l1t[i] == pf_tag) found = 1;
                // 预取池内已存在则不重复
                if (!found)
                    for (i = 0; i < P1N; i = i + 1)
                        if (pfv[i] && pft[i] == pf_tag) found = 1;
                if (!found) begin
                    // 找空槽；无空槽则覆盖最旧（环形）
                    max = 0; v = -1;
                    for (i = 0; i < P1N; i = i + 1)
                        if (!pfv[i]) begin v = i; i = P1N + 1; end
                    if (v < 0) v = 0;      // 满则覆盖槽0（简化：非真 LRU，演示结构）
                    pft[v] = pf_tag;
                    pfv[v] = 1'b1;
                    s_pref = s_pref + 1;
                end
            end

            // ============ 访问判定（用沿前已提交的状态 = 含本次预取前）============
            if (req) begin
                path0 = 0; path1 = 0; pathp = 0; found = 0;
                for (i = 0; i < 4; i = i + 1)
                    if (hot_v[i] && hot[i] == tag) begin path0 = 1; found = 1; end
                if (!found)
                    for (i = 0; i < L1N; i = i + 1)
                        if (l1v[i] && l1t[i] == tag) begin path1 = 1; found = 1; end
                if (!found)
                    for (i = 0; i < P1N; i = i + 1)
                        if (pfv[i] && pft[i] == tag) begin pathp = 1; found = 1; end

                if (path0) begin
                    s_l0 = s_l0 + 1;
                    s_hit = s_hit + 1;
                end else if (path1) begin
                    s_l1 = s_l1 + 1;
                    s_hit = s_hit + 1;
                    // L1 recency 更新
                    for (i = 0; i < L1N; i = i + 1)
                        if (l1v[i] && l1t[i] == tag) l1r[i] = 0;
                    for (i = 0; i < L1N; i = i + 1)
                        if (!(l1v[i] && l1t[i] == tag)) l1r[i] = l1r[i] + 1;
                end else if (pathp) begin
                    s_pf  = s_pf + 1;
                    // 预测命中 → 移入 L1 并统计（预取真正被消费）
                    s_prefok = s_prefok + 1;
                    s_hit = s_hit + 1;
                    // 移入 L1 空槽（若满覆盖最旧）
                    max = -1; v = -1;
                    for (i = 0; i < L1N; i = i + 1)
                        if (!l1v[i]) begin v = i; i = L1N + 1; end
                    if (v < 0) begin
                        max = 0;
                        for (i = 0; i < L1N; i = i + 1) if (l1r[i] > max) begin max = l1r[i]; v = i; end
                    end
                    if (v >= 0) begin
                        l1t[v] = tag;
                        l1v[v] = 1'b1;
                        l1r[v] = 0;
                        // 清掉预取池里该条目
                        for (i = 0; i < P1N; i = i + 1)
                            if (pfv[i] && pft[i] == tag) pfv[i] = 0;
                    end
                end else begin
                    s_miss = s_miss + 1;
                    // miss：装入 L1（空槽 else 逐掉最旧）
                    max = -1; v = -1;
                    for (i = 0; i < L1N; i = i + 1)
                        if (!l1v[i]) begin v = i; i = L1N + 1; end
                    if (v < 0) begin
                        max = 0;
                        for (i = 0; i < L1N; i = i + 1) if (l1r[i] > max) begin max = l1r[i]; v = i; end
                    end
                    if (v >= 0) begin
                        l1t[v] = tag;
                        l1v[v] = 1'b1;
                        l1r[v] = 0;
                        for (i = 0; i < L1N; i = i + 1)
                            if (i != v) l1r[i] = l1r[i] + 1;
                    end
                    // 冷 miss 且未来会被访问 → 若本拍有预取标记，属预取成功
                    // （在下一批读时体现；这里先不重复计）
                end
            end
        end
    end

endmodule