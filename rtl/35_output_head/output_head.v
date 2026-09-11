`timescale 1ns/1ps
`default_nettype none
//────────────────────────────────────────────────────────────────────────────
// output_head.v — M19 输出头件: 每 decode 步扫词表 logits 流, 取 top-K (argmax 族)
//
// 契约 (board-1g-k3-frozen.md §9 embed/output 接入):
//   输出头 = 词汇税: 每词要读 12.8MB 全量 logits 扫 top-K (P1 从 DDR 流读,
//   此处 = 流式端). 本件: 会话 TN 个 token, 每个 token 扫 VOC 个 logits
//   (FAST 替身; P2=VOCAB≈320K), 维护 top-K 表 {score desc, 下标小者先} 平局稳定,
//   全流扫完 → S_DONE 依序吐 K 个 (out_valid/out_take 手拉手 = token 出口);
//   TN 个 token → token_done → round++ 等 go。
//   背压: 扫描期上游断流 (in_valid 低) → 停拍记 stall 不丢不序;
//         吐期下游慢取 → 停拍记 stall; 表本身含即时 tid (读到即已入选, 无延迟窗口)。
//────────────────────────────────────────────────────────────────────────────
module output_head #(
    parameter TN   = 3,      // 会话 token 数
    parameter VOC  = 32,     // 词表规模 (P2≈320K, 流式)
    parameter K    = 3,      // 保留 top-K (P2 冻结词表剪枝后候选集)
    parameter BB   = 16,     // logits 位宽
    parameter RNDW = 6       // round 计数位宽
)(
    input  wire clk, rst_n, go,
    // ── 词表 logits 流 (每 token 依号 0..VOC-1) ──
    input  wire       in_valid,
    input  wire [BB-1:0]      in_logit,
    output wire       in_take,
    // ── top-K 出口 (token 选择) ──
    output reg         out_valid,
    output reg [BB-1:0]             out_score,
    output reg [$clog2(VOC)-1:0]    out_token,
    input  wire       out_take,
    // ── 状态/统计 ──
    output wire       token_done,
    output wire [WV-1:0] cur_word,                     // 扫描位置观测 (源配对)
    output reg  [$clog2(TN)-1:0] tok_idx = 0,
    output reg  [RNDW-1:0]    round   = 0,
    output reg  [31:0]        stalls  = 0,
    output reg  [31:0]        scanned = 0
);
    localparam WV = $clog2(VOC);
    localparam [BB-1:0] SSENT = {1'b1, {(BB-1){1'b0}}};   // 最小有符号数 (哨兵)

    localparam S_IDLE = 2'd0, S_SCAN = 2'd1, S_DONE = 2'd2;
    reg [1:0] st = S_IDLE;
    reg [WV-1:0]  cnt;               // 扫描位置 = 当前词下标
    reg [$clog2(K)-1:0] op;          // 吐出中的排名
    reg [BB-1:0]          tk_score [0:K-1];
    reg [WV-1:0]          tk_idx   [0:K-1];
    reg td_p = 0;

    integer newidx [0:K-1];          // 组合暂存新表
    integer newscr [0:K-1];

    integer j_inv;

    assign in_take     = (st == S_SCAN) && in_valid;
    assign token_done  = td_p;
    assign cur_word    = cnt;
    always @(*) out_score = tk_score[op];
    always @(*) out_token = tk_idx[op];

    task automatic tk_init();
        integer j;
        for (j = 0; j < K; j = j + 1) begin
            tk_score[j] <= SSENT;
            tk_idx[j]   <= 0;
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        integer j, p, ok;
        if (!rst_n) begin
            st <= S_IDLE; cnt <= 0; op <= 0;
            tok_idx <= 0; round <= 0; stalls <= 0; scanned <= 0;
            out_valid <= 0; td_p <= 0;
            for (j = 0; j < K; j = j + 1) begin
                tk_score[j] <= SSENT;
                tk_idx[j]   <= 0;
            end
        end else begin
            case (st)
                S_IDLE: begin
                    td_p <= 0;
                    if (go) begin
                        st <= S_SCAN; cnt <= 0;
                        tk_init();
                    end
                end
                S_SCAN: begin
                    td_p <= 0;
                    if (in_valid) begin
                        scanned <= scanned + 1;
                        // 插入 top-K: 有符号分值, 平局 idx 小者先 (stable)
                        p = K; ok = 0;
                        for (j = 0; j < K && !ok; j = j + 1) begin
                            if (($signed(in_logit) > $signed(tk_score[j])) ||
                                (($signed(in_logit) == $signed(tk_score[j])) && cnt < tk_idx[j])) begin
                                p = j; ok = 1;
                            end
                        end
                        if (p < K) begin
                            for (j = 0; j < p; j = j + 1) begin
                                newidx[j] = tk_idx[j];
                                newscr[j] = tk_score[j];
                            end
                            newidx[p] = cnt;
                            newscr[p] = in_logit;
                            for (j = p + 1; j < K; j = j + 1) begin
                                newidx[j] = tk_idx[j - 1];
                                newscr[j] = tk_score[j - 1];
                            end
                            for (j = 0; j < K; j = j + 1) begin
                                tk_idx[j]   <= newidx[j];
                                tk_score[j] <= newscr[j];
                            end
                        end
                        if (cnt == VOC-1) begin
                            st <= S_DONE; op <= 0; out_valid <= 1;
                        end else cnt <= cnt + 1;
                    end else stalls <= stalls + 1;      // 扫描期上游断流
                end
                S_DONE: begin
                    if (out_valid && out_take) begin
                        if (op == K-1) begin
                            out_valid <= 0;
                            if (tok_idx == TN-1) begin
                                td_p <= 1; round <= round + 1;
                                st <= S_IDLE;
                            end else begin
                                tok_idx <= tok_idx + 1;
                                st <= S_SCAN; cnt <= 0;
                                tk_init();
                            end
                        end else op <= op + 1;
                    end else if (out_valid && !out_take)
                        stalls <= stalls + 1;            // 吐期下游慢取
                end
                default: st <= S_IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire