`timescale 1ps/1ps
`default_nettype none

// sched_exec.v — 层执行调度器 (M11): 每层 GEMM段 → attn段 → 释放, 挂真引擎链
//
// P2 主脑: 把已验收的单引擎卷进"93 层循环"的执行骨架。每层:
//   GEMM段  sel=0: 切片库(A-tile)读本层切片 → gemv_rail_ctl(帧流) → 共享 MAC
//   attn段  sel=1: 头窗 attn_window 填灌(窗自写池 a_ 侧)→ attn_inner_ctl → 共享 MAC
//   层末    释放层: rl_valid/rl_layer 电平拉高直到 wb_flow.layers_done 推进 (M9 纪律)
// 层节拍: 开层 L 需 wb_flow.layer_fill >= L+1 (切片已在库); 双缓冲由 wb_flow 管,
//         本器只保证"数据在场才执行、段绝不越序、释放恰一次"。
//
// 切片库双槽地图与 wb_flow 同规: 层 L 落槽 L&1, 词序 addr = (L&1)*GW + w。
// 引擎并列: GEMM/attn 复用同一 MAC 阵列 (时间片资源); 顶层按 phase 选喂食源。

module sched_exec #(
    parameter DW     = 32,
    parameter AW     = 8,          // 槽位码宽 (切片库/池地址)
    parameter NL     = 4,          // 层数 (P2 93)
    parameter GW     = 16,         // GEMM 段词/层 (= wb_flow SLICE_W)
    parameter GDEPTH = 16,         // GEMM 帧长 (rail TDEPTH)
    parameter ATW    = 128         // attn 窗字数/层 (= HEADS*BUFS*HBUF)
)(
    input  wire         clk,
    input  wire         rst_n,
    input  wire         go,
    output reg          busy,

    // ---- 与 wb_flow 的节拍 (layer_fill 入 / 释放出 / layer_sync 入) ----
    input  wire [31:0]  layer_fill,     // wb_flow.layer_fill
    input  wire [31:0]  layer_sync,     // wb_flow.layers_done
    output reg          rl_valid,
    output reg  [31:0]  rl_layer,
    input  wire         a_busy,         // attn_window.busy (观测; RELL 等待窗口收口)

    // ---- 池权 (GEMM=0 / attn=1) ----
    output reg          sel_o,

    // ---- 切片库读 (A-tile) ----
    output reg  [AW-1:0] slice_addr,
    input  wire [DW-1:0] slice_rdata,

    // ---- gemv_rail_ctl 喂食 (层帧流) ----
    output reg          r_valid,
    output reg  [DW-1:0] r_data,
    output reg          r_frame_done,
    output reg  [3:0]   r_addr,
    input  wire         r_take,

    // ---- attn_window 填灌 ----
    output reg          a_go,
    output reg          a_s_valid,
    output wire [DW-1:0] a_s_data,  // 组合直出 (M6 source 纪律): 词序=aww, 与窗握手同沿
    input  wire         a_s_ready,
    input  wire [31:0]  a_ww,          // window.words_written
    input  wire [31:0]  a_wr,          // window.words_read

    // ---- attn_inner_ctl ----
    output reg          c_go,
    input  wire         c_busy,
    input  wire [31:0]  c_blocks,      // ctl.blocks_done

    // ---- 段相位 (顶层阵列喂食选源 / 观测) ----
    output wire [1:0]   phase,
    output wire [2:0]   st_o,           // 当前状态 (观测)
    output wire [$clog2(NL)-1:0] layer_now,  // 当前执行层 (观测)

    // ---- 簿记 (go 会话清零) ----
    output reg [31:0]   layers_done,
    output reg [31:0]   gemm_done,
    output reg [31:0]   attn_done,
    output reg [31:0]   sel_switches,
    output reg [31:0]   barrier_waits,
    output reg [31:0]   wg_words,
    output reg [31:0]   wa_words
);

    localparam HEADS = 4, HBUF = 16, BUFS = 2, WPR = 2;
    localparam BPT   = HEADS * BUFS;          // 每层 attn 块数 = 8

    localparam LW   = $clog2(NL + 1);
    localparam GWL  = $clog2(GW + 1);
    localparam WAL  = $clog2(ATW + 1);

    localparam S_IDLE   = 3'd0;
    localparam S_FILLW  = 3'd1;
    localparam S_GEMM   = 3'd2;
    localparam S_QUI    = 3'd3;
    localparam S_GOATTN = 3'd4;
    localparam S_ATFIL  = 3'd5;
    localparam S_ATEND  = 3'd6;
    localparam S_REL    = 3'd7;

    reg [2:0]      st;
    reg [LW-1:0]   lay;
    reg [GWL-1:0]  gw;
    reg [1:0]      quic;
    reg [WAL-1:0]  aww;
    reg            go_pulsed;
    reg [31:0]     fill_ep;
    reg [31:0]     wbase;         // 本层窗数基址 (words_written 去累积化)
    reg [31:0]     rbase;         // 本层窗读基址 (words_read 去累积化)

    assign phase = (st == S_GOATTN || st == S_ATFIL || st == S_ATEND || st == S_REL)
                   ? 2'd1 : 2'd0;
    assign st_o      = st;
    assign layer_now = lay;

    function automatic [15:0] se_in(input integer L, input integer blk,
                                    input integer r, input integer j);
        begin
            se_in = ((L * 7919 + blk * 100 + r * 10 + j * 3 + 7) % 254) + 1;
        end
    endfunction

    function automatic [DW-1:0] wordval(input integer L, input integer K);
        integer blk, w, r, hlf;
        begin
            blk = K / HBUF; w = K % HBUF;
            r = w / WPR; hlf = w % WPR;
            wordval = {se_in(L, blk, r, 2*hlf+1), se_in(L, blk, r, 2*hlf)};
        end
    endfunction

    // ---- 切片库读地址 (组合): 双槽地图层 L 落槽 L&1 ----
    always @* begin
        slice_addr = ((lay[0] ? GW : 0) + gw);
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st            <= S_IDLE;
            busy          <= 1'b0;
            lay           <= 0;
            gw            <= 0;
            quic          <= 0;
            aww           <= 0;
            go_pulsed     <= 1'b0;
            fill_ep       <= 0;          // 填灌纪元基数 (跨会话持久, 视 layer_fill 回卷重对齐)
            wbase         <= 0;
            rbase         <= 0;
            rl_valid      <= 1'b0;
            rl_layer      <= 0;
            sel_o         <= 1'b0;
            r_valid       <= 1'b0;
            r_data        <= 0;
            r_frame_done  <= 1'b0;
            r_addr        <= 0;
            a_go          <= 1'b0;
            a_s_valid     <= 1'b0;
            c_go          <= 1'b0;
            layers_done   <= 0;
            gemm_done     <= 0;
            attn_done     <= 0;
            sel_switches  <= 0;
            barrier_waits <= 0;
            wg_words      <= 0;
            wa_words      <= 0;
        end else begin
            case (st)

                S_IDLE: begin
                    if (go) begin
                        busy     <= 1'b1;
                        lay      <= 0;
                        gw       <= 0;
                        quic     <= 0;
                        aww      <= 0;
                        go_pulsed<= 1'b0;
                        fill_ep  <= layer_fill;   // 录下当前灌库前沿 (会话交接时的旧值)
                        sel_o    <= 1'b0;
                        rl_valid <= 1'b0;
                        layers_done   <= 0;
                        gemm_done     <= 0;
                        attn_done     <= 0;
                        sel_switches  <= 0;
                        barrier_waits <= 0;
                        wg_words      <= 0;
                        wa_words      <= 0;
                        st       <= S_FILLW;
                    end
                end

                // ---- 等本层切片在库 ----
                S_FILLW: begin
                    if (layer_fill < fill_ep) begin
                        // 填灌纪元回卷 → 新会话已重启 (旧前沿尾数值残余), 重对齐
                        fill_ep <= layer_fill;
                    end else if ((layer_fill - fill_ep) >= (lay + 1)) begin
                        gw <= 0;
                        st <= S_GEMM;
                    end else begin
                        barrier_waits <= barrier_waits + 1;
                    end
                end

                // ---- GEMM 段: 切片库字 → rail 帧流 → MAC ----
                S_GEMM: begin
                    if (gw < GW) begin
                        r_valid      <= 1'b1;
                        r_data       <= slice_rdata;   // 组合读切片库
                        r_addr       <= gw[3:0];
                        r_frame_done <= (gw == GW - 1);
                        gw           <= gw + 1;
                    end else begin
                        r_valid      <= 1'b0;
                        r_frame_done <= 1'b0;
                        gemm_done    <= gemm_done + 1;
                        wg_words     <= wg_words + GW;
                        quic         <= 0;
                        st           <= S_QUI;
                    end
                end

                // ---- 段间沉降: MAC 归零护栏 + 池权静默 ----
                S_QUI: begin
                    r_valid <= 1'b0;
                    if (quic == 2'd2) begin
                        quic  <= 0;
                        st    <= S_GOATTN;
                    end else begin
                        quic  <= quic + 1;
                    end
                end

                // ---- attn 段: 发窗与内积 go ----
                S_GOATTN: begin
                    sel_o <= 1'b1;
                    if (!go_pulsed) begin
                        a_go      <= 1'b1;
                        c_go      <= 1'b1;
                        go_pulsed <= 1'b1;
                    end else begin
                        a_go   <= 1'b0;
                        c_go   <= 1'b0;
                        aww    <= 0;
                        wbase  <= a_ww;            // 窗写累计基址 (去累积化)
                        rbase  <= a_wr;            // 窗读累计基址
                        sel_switches <= sel_switches + 1;
                        st     <= S_ATFIL;
                    end
                end

                // ---- 填灌头窗 (窗自写池 a_) ----
                S_ATFIL: begin
                    if (a_s_ready && aww < ATW) begin
                        aww <= aww + 1;
                        if (aww == ATW - 1) st <= S_ATEND;
                    end
                end

                // ---- 等 attn 链收工 ----
                S_ATEND: begin
                    if ((a_ww - wbase) >= ATW && (a_wr - rbase) >= ATW && !c_busy &&
                        c_blocks >= (attn_done + 1) * BPT) begin
                        attn_done <= attn_done + 1;
                        wa_words  <= wa_words + ATW;
                        st        <= S_REL;
                    end
                end

                // ---- 释放层 → 下一层 ----
                S_REL: begin
                    sel_o    <= 1'b0;
                    rl_valid <= 1'b1;
                    rl_layer <= lay;
                    if (layer_sync > lay) begin
                        rl_valid <= 1'b0;
                        layers_done <= layers_done + 1;
                        if (lay + 1 < NL) begin
                            lay  <= lay + 1;
                            gw   <= 0;
                            aww  <= 0;
                            go_pulsed <= 1'b0;   // 下一层需重新发 go 脉冲
                            st   <= S_FILLW;
                        end else begin
                            busy <= 1'b0;
                            st   <= S_IDLE;
                        end
                    end
                end

                default: st <= S_IDLE;
            endcase

            a_s_valid <= (st == S_ATFIL) ? (aww < ATW) : 1'b0;
        end
    end

    // attn 填灌数据: 组合直出 (M6 source 纪律) —— 词序必须取自窗自身的计数
    // (words_written), 经层内基址 wbase 去累积化; 严禁用本器计数器驱动
    // 数据: 窗在授写沿采样 s_data, 与窗自己的计数同沿, 无滞后。否则字序错位。
    assign a_s_data = wordval(lay, a_ww - wbase);

endmodule