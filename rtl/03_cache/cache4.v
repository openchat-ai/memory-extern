`timescale 1ns/1ps
// 03_cache — 4 路组相联 LRU 缓存（k3_cache 微型版）。
// 4 路 × 4 组 = 16 槽，tag 低 2bit 选组。rank 模型 LRU（真 LRU）：
//   每路一个 2bit rank（组内唯一，0=MRU .. 3=LRU）。
//   hit  → 该路 rank 归 0，比它新的路下移 +1
//   miss → LRU 路(rank==3) 写 tag，rank 归 0，其余路 rank+1
//
// 重要（本次踩坑）：iverilog 对「同一 always 内先阻塞读多维数组、
// 后非阻塞写同数组」调度有 bug → 被判成命中/数据前进一拍。
// 规避：全部阻塞赋值（时钟沿上 `=` 一次算完），无 `<=`，无跨沿保持，
// 判定与更新天然原子（读旧快照、写新快照均在沿内完成）。
module cache4 #(
    parameter AW   = 10,       // tag 位宽（含组索引位）
    parameter DW   = 32,       // 数据字位宽
    parameter SETS = 4,        // 组数（2 的幂）
    parameter WAYS = 4         // 路数
)(
    input  wire         clk,
    input  wire         rst,
    input  wire         req,
    input  wire         we,
    input  wire [AW-1:0] tag,
    input  wire [DW-1:0] wdata,
    input  wire         pf_req,              // 预取请求有效（同一沿发起）
    input  wire [AW-1:0] pf_tag,             // 预取目标 id（低 INDBITS 位选组）
    output reg  [DW-1:0] rdata,
    output reg          hit,
    output reg  [$clog2(WAYS)-1:0] way,
    output reg  [31:0]  hits,
    output reg  [31:0]  misses,
    output reg  [31:0]  pf_hits,             // 命中且该槽是预取装入的（预取直接命中）
    output reg  [31:0]  pf_installs          // 实际装入的预取数（去重）
);

    localparam INDBITS = $clog2(SETS);   // 组索引位
    localparam RANKW  = $clog2(WAYS);    // rank 位宽 (0=MRU .. WAYS-1=LRU)

    reg [AW-1:0] tgt [0:SETS-1][0:WAYS-1];
    reg [DW-1:0] dat [0:SETS-1][0:WAYS-1];
    reg          val [0:SETS-1][0:WAYS-1];
    reg [RANKW-1:0] rnk [0:SETS-1][0:WAYS-1];
    reg          pfm [0:SETS-1][0:WAYS-1];   // 预取标记：此槽的 tag 是预取装入的

    integer i, j;
    reg [INDBITS-1:0] idx;
    integer hw;
    integer hw_rank;
    reg    is_hit;
    integer lw;
    reg    pf_found;
    integer pf_hw;

    // 单 always：沿上读旧快照（tgt/val/rnk 即"旧状态"），阻塞 `=` 结算并提交。
    // 无 `<=`，故判定与更新之间绝无非阻塞调度的"中间态"。
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            for (i = 0; i < SETS; i = i + 1)
                for (hw = 0; hw < WAYS; hw = hw + 1) begin
                    tgt[i][hw] = 0;
                    dat[i][hw] = 0;
                    val[i][hw] = 0;
                    pfm[i][hw] = 0;
                    rnk[i][hw] = hw[RANKW-1:0];   // way0 MRU .. wayWAYS-1 LRU
                end
            hit    = 0;
            way    = 0;
            hits   = 0;
            misses = 0;
            pf_hits = 0;
            pf_installs = 0;
        end else if (req) begin
            idx = tag[INDBITS-1:0];

            // —— 读旧快照判定（当前沿的 tgt/val 是上一沿提交的 = 旧状态）
            is_hit = 1'b0;
            hw = 0;
            for (i = 0; i < WAYS; i = i + 1)
                if (val[idx][i] && tgt[idx][i] == tag) begin
                    is_hit = 1'b1;
                    hw = i;
                end
            hw_rank = is_hit ? rnk[idx][hw] : 0;
            lw = 0;
            for (i = 0; i < WAYS; i = i + 1)
                if (rnk[idx][i] == WAYS - 1) lw = i;

            // —— 沿结算（读 rdata：旧快照数据）
            rdata = 0;
            if (is_hit) begin
                hit   = 1;
                way   = hw[RANKW-1:0];
                hits  = hits + 1;
                rdata = dat[idx][hw];
                if (we) dat[idx][hw] = wdata;
            end else begin
                hit    = 0;
                way    = lw[RANKW-1:0];
                misses = misses + 1;
            end

            // —— rank / 替换更新（全部阻塞，同一沿内当前 tgt 已提交）
            for (i = 0; i < WAYS; i = i + 1) begin
                if (is_hit && i == hw) begin
                    rnk[idx][i] = 0;
                end else if (is_hit && rnk[idx][i] < hw_rank) begin
                    rnk[idx][i] = rnk[idx][i] + 1'b1;
                end else if (!is_hit && i == lw) begin
                    tgt[idx][i] = tag;
                    val[idx][i] = 1'b1;
                    if (we) dat[idx][i] = wdata;
                    rnk[idx][i] = 0;
                end else if (!is_hit) begin
                    rnk[idx][i] = rnk[idx][i] < WAYS - 1 ? rnk[idx][i] + 1'b1 : rnk[idx][i];
                end
            end

            // —— 预取（本沿访问结算后执行：不干扰访问判定的旧快照）
            //    命中标记：访问命中时若该槽是预取装入 → pf_hits++
            if (is_hit && pfm[idx][hw]) begin
                pf_hits = pf_hits + 1;
                pfm[idx][hw] = 0;              // 消费标记（已是真访问）
            end
            if (pf_req) begin
                idx = pf_tag[INDBITS-1:0];
                pf_found = 1'b0;
                pf_hw = 0;
                for (i = 0; i < WAYS; i = i + 1)
                    if (val[idx][i] && tgt[idx][i] == pf_tag) pf_found = 1'b1;
                if (!pf_found) begin
                    lw = 0;
                    for (i = 0; i < WAYS; i = i + 1)
                        if (rnk[idx][i] == WAYS - 1) lw = i;
                    tgt[idx][lw] = pf_tag;     // 预取装入（覆盖 LRU 槽）
                    val[idx][lw] = 1'b1;
                    pfm[idx][lw] = 1'b1;       // 标预取
                    rnk[idx][lw] = 0;          // 视为刚使用
                    for (i = 0; i < WAYS; i = i + 1)
                        if (i != lw && rnk[idx][i] < WAYS - 1)
                            rnk[idx][i] = rnk[idx][i] + 1'b1;
                    pf_installs = pf_installs + 1;
                end
            end
        end
    end

endmodule