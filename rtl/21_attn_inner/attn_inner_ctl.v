`timescale 1ns/1ps
`default_nettype none
//----------------------------------------------------------------------------
// attn_inner_ctl.v — attn 段头窗内积控制器 (M6)
//
// 接 attn_window 的 S 头窗读流 (r_valid/r_data/r_take), 逐块计算:
//   每块 = 一颗头的 S (128×128 bf16, 缩尺 HEADS×BUFS×HBUF 字),
//   行序流: word = {S[i][2j+1], S[i][2j]} (每字 2 枚 16bit);
//   每行点积 o[i] = Σ_j q_h[j]·S[i][j] (dot 长 FEED = 2×WPR)。
//
// MAC 阵列无清口且随流累加 → 用"前后差分"取行积: 行首采样 acc_a,
// 行尾采样 acc_b, o = (acc_b - acc_a) mod 2^16 (累加线性, 差分即行积)。
//
// 纪律 (M4 沉淀): 非喂食沿 act/weight 归零护栏; q 为 act 模板、S 为权重。
// word 全量收进本地 wbuf (全局字序号), 喂食读绝对行地址, 天然跨块无覆写。
//----------------------------------------------------------------------------
module attn_inner_ctl #(
    parameter DW     = 32,
    parameter HEADS  = 4,
    parameter HBUF   = 16,       // 每块字数 (M5 缩尺)
    parameter BUFS   = 2,
    parameter WPR    = 2         // 每行几个字 (每字 2 枚 16bit)
)(
    input  wire          clk,
    input  wire          rst_n,
    input  wire          go,
    output reg           busy,

    // ---- S 头窗读流 (接 attn_window 读侧) ----
    input  wire          r_valid,
    input  wire [DW-1:0] r_data,
    output reg           r_take,

    // ---- q 模板向量 (FEED 枚 16bit; 上游按头提供) ----
    input  wire [15:0]   q_vec [0:(2*WPR)-1],

    // ---- 阵列累加入 (接 gemv_array_128.acc_out) ----
    input  wire [15:0]   acc_out_in,

    // ---- 当前块号 (观测/上游按头供 q) ----
    output wire [31:0]   blk_now,

    // ---- MAC 阵列食物 ----
    output reg  [15:0]   act_in,
    output reg  [15:0]   weight_in,

    // ---- 输出流: 每行一颗 o ----
    output reg           o_valid,
    output reg  [15:0]   o_data,
    output reg  [31:0]   o_head,     // 头号 (块号)
    output reg  [31:0]   o_row,      // 行号 (块内)

    // ---- 状态 ----
    output reg  [31:0]   words_rcvd,
    output reg  [31:0]   rows_done,
    output reg  [31:0]   blocks_done
);

    function integer clog2(input integer n);
        integer k;
        begin
            k = 0;
            while ((1 << k) < n) k = k + 1;
            clog2 = k;
        end
    endfunction

    localparam FEED      = 2 * WPR;                 // 行点积长 (4)
    localparam ROWS_PB   = HBUF / WPR;              // 每块行数 (8)
    localparam WA        = HEADS * BUFS * HBUF;     // 全窗字数 (128)
    localparam ROWS_TOT  = WA / WPR;                // 全窗行数 (64)
    localparam WAL       = clog2(WA + 1);      // 收字计数须容下终值 WA (防 127->0)
    localparam ROWL      = clog2(ROWS_TOT);
    localparam ROWW      = clog2(ROWS_PB);          // 块内行号位

    reg [WAL-1:0]     wc;              // 已收字数
    reg [DW-1:0]      wbuf [0:WA-1];   // 本地字缓冲 (全局序; 真机=窗本体)
    reg [ROWL-1:0]    ra;              // 当前行 (绝对序)
    reg [3:0]         idx;             // 喂食序号 0..FEED (FEED=收尾档)
    reg               feeding;         // 喂食相位
    reg               pend_o;          // 行尾待出
    reg               session;

    // acc 采样 (16 位差分)
    reg [15:0]        acc_a16, acc_b16;

    assign blk_now = (ra / ROWS_PB);                // 当前块 (组合)
    wire [31:0] row_now = ra % ROWS_PB;             // 当前行 (块内)

    // 喂食元素: 按目标序号 t 取 (发布 feed(t) 时 t = 首发/idx+1)
    function [15:0] elemf(input integer t);
        integer wi;
        begin
            wi = (ra * WPR) + (t >> 1);
            elemf = (t[0]) ? wbuf[wi][31:16] : wbuf[wi][15:0];
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_take <= 0; act_in <= 0; weight_in <= 0;
            o_valid <= 0; o_data <= 0; o_head <= 0; o_row <= 0;
            wc <= 0; ra <= 0; idx <= 0;
            feeding <= 0; pend_o <= 0;
            acc_a16 <= 0; acc_b16 <= 0;
            session <= 0; busy <= 0;
            words_rcvd <= 0; rows_done <= 0; blocks_done <= 0;
        end else if (session) begin
            r_take <= 1'b1;  act_in <= 0; weight_in <= 0; o_valid <= 0;
            // r_take: 电平取走 (M5 引擎读侧需电平 ready 才消费; 单拍脉冲会错过)

            // ---- 收字 (无条件的流收) ----
            if (r_valid) begin
                wbuf[wc] <= r_data;
                wc <= wc + 1'b1;
                words_rcvd <= words_rcvd + 1'b1;
            end

            // ---- 行尾出 o ----
            if (pend_o) begin
                pend_o <= 0;
                o_valid <= 1'b1;
                o_data  <= (acc_b16 - acc_a16);      // 差分取行积
                o_head  <= blk_now;
                o_row   <= row_now;
                rows_done <= rows_done + 1'b1;
                ra <= ra + 1'b1;
                if (row_now == ROWS_PB - 1)
                    blocks_done <= blocks_done + 1'b1;
                if (ra == ROWS_TOT - 1) begin
                    busy <= 1'b0;
                    session <= 1'b0;
                end
            end

            // ---- 喂食 FSM (沿后一拍才进阵列; idx 即喂食序, FEED=收尾档) ----
            if (!feeding && !pend_o) begin           // pend_o 沿 = 行推进沿, 跳过防旧 ra 错位
                if (wc >= (ra + 1) * WPR) begin      // 本行 WPR 字已收齐
                    feeding <= 1'b1;
                    idx     <= 4'd0;
                    acc_a16 <= acc_out_in;           // 行首采样 (任何乘积之前)
                    act_in    <= q_vec[0];           // feed0 发布
                    weight_in <= elemf(0);
                end
                // 非喂食态只做启动判定, 不再有其它分支 (防瞎发 feed1)
            end else if (feeding) begin
                if (idx == FEED) begin               // 收尾档: 全部乘积已落 -> 行尾采样
                    feeding  <= 1'b0;
                    idx      <= 4'd0;
                    acc_b16  <= acc_out_in;
                    pend_o   <= 1'b1;
                end else if (idx == FEED - 1) begin  // 末次已发布, 等其落阵
                    idx      <= idx + 1'b1;
                end else begin                       // 发布 feed(idx+1)
                    idx      <= idx + 1'b1;
                    act_in   <= q_vec[idx + 1];
                    weight_in<= elemf(idx + 1);
                end
            end
        end else begin
            // 待命: go 沿触发
            r_take <= 0; act_in <= 0; weight_in <= 0; o_valid <= 0;
            if (go && !busy) begin
                busy <= 1'b1;
                session <= 1'b1;
            end
        end
    end
endmodule
`default_nettype wire