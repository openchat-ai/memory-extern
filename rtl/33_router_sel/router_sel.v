`timescale 1ns/1ps
`default_nettype none
//────────────────────────────────────────────────────────────────────────────
// router_sel.v — M17 router 先行: top-T 专家选择件 (P2 装配前端)
//
// 契约 (board-1g-k3-frozen.md §9 router 先行):
//   每层 gate 装载 + e_score 流到齐 → 选 top-16 才能拉专家实体
//   (先选后抽, 读 12.8MB gate+score 后才动实体流)  —— 本件 = "选" 的时序核心:
//   层内候选专家数 EX, 流序 = 专家下标 0..EX-1 (e_score 装载语义, 隐含 idx),
//   每来一分作 top-T 表插入 (最高在前, 平局 idx 小者先);
//   层收齐 → 吐表 (out_valid/out_take 手拉手) → layer_done(barrier) → 下一层;
//   NL 层完工 → token_done → round++ 等 go。credit 弹性背压: 表吐期拒灌 (放行门
//   关), 上游连拍挂起记 stall 不丢不序不乱 (M 系列同口径)。
//────────────────────────────────────────────────────────────────────────────
module router_sel #(
    parameter EX  = 32,      // 候选专家/层 (P2 实体库侧 每层全候选)
    parameter TOP = 8,       // 选择条数 (P2 冻结口径 top-16)
    parameter SW  = 16,      // e_score 宽度
    parameter NL  = 3        // 座席层/会话
)(
    input  clk, rst_n, go,
    output reg busy,
    input  credit,                            // 上游信用门 (M 系列口径)
    input  s_valid,                           // e_score 流 (1 拍/专家, 层内 0..EX-1)
    input  [SW-1:0] s_score,
    output wire out_valid,                    // top-T 表逐条吐装配 (组合: 表序=已排好)
    output wire [($clog2(EX)-1):0] out_idx,
    output wire [SW-1:0] out_score,
    input  out_take,
    output reg layer_done, token_done,
    output reg [7:0] round,
    output wire [IX-1:0] cur_idx,             // 当前灌收专家号 (观测/源配对, M16 s_sel 同构)
    output reg [31:0] layers,                 // 完工层累计
    output reg [31:0] selected,               // 已吐条数
    output reg [31:0] stalls                  // 被堵停拍 (吐期上游连拍 or 灌期信用断)
);

    localparam IX   = $clog2(EX);
    localparam NLW  = $clog2(NL);
    localparam S_IDLE = 2'd0, S_COLL = 2'd1, S_EMIT = 2'd2;

    integer ii, pp;                          // 插入/移位循环计数 (模块级, 可综合循环)

    reg [1:0]   st;
    reg [NLW-1:0] lay;
    reg [IX-1:0]  idx;                       // 层内流序专家号 (灌收即锁到表)
    reg [IX-1:0]  op;                        // 吐表游标
    reg [IX:0]    tc;                        // 表内条数 (≤ TOP)

    reg [SW-1:0]  t_score [0:TOP-1];         // top-T 表 (0 = 最优)
    reg [IX-1:0]  t_idx   [0:TOP-1];

    wire accept = (st == S_COLL) && s_valid && credit;
    wire emitting = (st == S_EMIT) && (op < TOP);

    assign out_valid = emitting;
    assign out_idx   = t_idx[op];
    assign out_score = t_score[op];
    assign cur_idx   = idx;
    assign out_idx   = t_idx[op];
    assign out_score = t_score[op];
    assign cur_idx   = idx;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_IDLE; busy <= 0; lay <= 0; idx <= 0; op <= 0; tc <= 0;
            layer_done <= 0; token_done <= 0; round <= 0;
            layers <= 0; selected <= 0; stalls <= 0;
            for (ii = 0; ii < TOP; ii = ii + 1) begin
                t_score[ii] <= 0; t_idx[ii] <= 0;
            end
        end else begin
            layer_done <= 0; token_done <= 0;
            case (st)
                S_IDLE: if (go) begin
                    lay <= 0; idx <= 0; tc <= 0; op <= 0;
                    layers <= 0; selected <= 0; stalls <= 0;
                    st <= S_COLL; busy <= 1;
                end

                S_COLL: begin
                    if (accept) begin
                        // ---- top-T 插入 (key = {score, ~idx} 降序, 平局 idx 小者先) ----
                        pp = -1;
                        for (ii = 0; ii < TOP; ii = ii + 1)
                            if (ii < tc[IX-1:0] &&
                                {s_score, ~idx} > {t_score[ii], ~t_idx[ii]}) begin
                                if (pp < 0) pp = ii;
                            end
                        if (pp < 0 && tc < TOP) pp = tc;
                        if (pp >= 0) begin
                            for (ii = TOP - 1; ii > pp; ii = ii - 1) begin
                                t_score[ii] <= t_score[ii-1];
                                t_idx[ii]   <= t_idx[ii-1];
                            end
                            t_score[pp] <= s_score;
                            t_idx[pp]   <= idx;
                            if (tc < TOP) tc <= tc + 1;
                        end
                        if (idx + 1 == EX) begin
                            st <= S_EMIT; op <= 0;
                        end
                        else idx <= idx + 1;
                    end
                end

                S_EMIT: begin
                    if (op < TOP && out_take) begin
                        selected <= selected + 1;
                        if (op == TOP - 1) begin
                            layer_done <= 1;
                            layers <= layers + 1;
                            for (ii = 0; ii < TOP; ii = ii + 1) begin
                                t_score[ii] <= 0; t_idx[ii] <= 0;
                            end
                            if (lay + 1 == NL) begin
                                token_done <= 1; round <= round + 1;
                                st <= S_IDLE; busy <= 0; lay <= 0;
                            end else begin
                                lay <= lay + 1; idx <= 0; tc <= 0; op <= 0;
                                st <= S_COLL;
                            end
                        end else begin
                            op <= op + 1;
                        end
                    end
                end

                default: st <= S_IDLE;
            endcase

            // ---- 被堵停拍: 吸期 (S_COLL) 信用断 → 上游连拍吃不下 (M 系列同口径) ----
            if (st == S_COLL && s_valid && !credit)
                stalls <= stalls + 1;
        end
    end
endmodule
`default_nettype wire