`timescale 1ns/1ps
`default_nettype none
//----------------------------------------------------------------------------
// attn_window.v — attn 段 S 头窗引擎 (§6: S 头窗 8头×32KB×2 双缓冲 = 512KB)
//
// 占用 MAC 热池的 attn 侧 (sram_pool_arb 的 a_* 口)。一块一块地:
//   fill : 从 S[L] 段流 (s_*) 灌入池, 顺序遍历 头h × 缓冲b × 字w;
//   read : 按块序把已填完的块吐给 attn 计算 (r_valid/r_take, 手拉手)。
//
// 双缓冲编排: 读侧只进入**已完工**的块 (nr < blocks_filled), 天然落后填充
// 一整块 —— 上一块在被计算方消费时, 下一块正灌入池。
//
// 池口时序 (单口池): 引擎在"发号沿"把请求登记输出 (reg), 池子**下一沿**
// 才采样接受 (登记地址), 数据在其后再一沿才稳定。故:
//   - 计数/推进都在发号沿做 (池子无回溯, 字序自洽);
//   - 读数据用 st1/st2 移位锁到"发出后第 2 沿"再采 (恰好读回自身地址)。
//----------------------------------------------------------------------------
module attn_window #(
    parameter AW     = 8,
    parameter DW     = 32,
    parameter HEADS  = 4,       // 头窗头数 (冻结口径 8)
    parameter HBUF   = 16,      // 每头每缓冲字数 (32KB = 8192 word @ DW=32)
    parameter BUFS   = 2        // 双缓冲
)(
    input  wire          clk,
    input  wire          rst_n,

    input  wire          go,
    output reg           busy,

    // ---- attn 口 (接 sram_pool_arb a_*) ----
    output reg           a_valid,
    output reg           a_we,
    output reg  [AW-1:0] a_addr,
    output reg  [DW-1:0] a_wdata,
    input  wire          a_rdy,
    input  wire [DW-1:0] a_rdata,

    // ---- S[L] 段流 (DMA/主机喂入) ----
    input  wire          s_valid,
    input  wire [DW-1:0] s_data,
    output reg           s_ready,

    // ---- 输出流 (attn 计算消费) ----
    output reg           r_valid,
    input  wire          r_take,
    output reg  [DW-1:0] r_data,

    // ---- 状态 ----
    output reg  [31:0]   words_written,
    output reg  [31:0]   words_read,
    output reg  [31:0]   fills_done,
    output reg  [31:0]   reads_done,
    output reg  [31:0]   reads_in_overlap    // 读在飞时仍在灌 (双缓冲生效计数)
);

    function integer clog2(input integer n);
        integer k;
        begin
            k = 0;
            while ((1 << k) < n) k = k + 1;
            clog2 = k;
        end
    endfunction

    localparam HW   = clog2(HEADS);          // 头号位
    localparam HBW  = clog2(HBUF);           // 块内字位
    localparam FBW  = clog2(BUFS);           // 缓冲位 (1)
    localparam NBUF = HEADS * BUFS;
    localparam NBW  = clog2(NBUF);           // 块号位

    reg [NBW-1:0] nf, nr;
    reg [HBW-1:0] fw, rw;
    reg [clog2(NBUF+1)-1:0] blocks_filled;   // 容得下 NBUF 本身
    reg           fill_active;
    reg           read_active;
    reg           fill_done, read_done;
    reg           presented;                 // 已呈现、待消费
    reg           grant_w;                   // round-robin: 1=写优先
    reg           session;                   // 会话锁存: go 只作触发沿
    reg [1:0]     read_cnt;                  // 读单飞: 3=已发出 1=可采 0=空闲

    // 块序 n -> (h, b): h=n/BUFS, b=n%BUFS; 地址 {h, b, w}
    wire [HW-1:0] f_h = nf[FBW +: HW];
    wire [HW-1:0] r_h = nr[FBW +: HW];
    wire          f_b = nf[0];
    wire          r_b = nr[0];

    wire [AW-1:0] f_addr = (f_h << (FBW + HBW)) | (f_b << HBW) | fw;
    wire [AW-1:0] r_addr = (r_h << (FBW + HBW)) | (r_b << HBW) | rw;

    wire wrq = fill_active && s_valid;
    wire rrq = read_active && !presented && (read_cnt == 2'b00) && (nr < blocks_filled);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_valid <= 0; a_we <= 1'b1; a_addr <= 0; a_wdata <= 0;
            s_ready <= 0; r_valid <= 0; r_data <= 0;
            nf <= 0; nr <= 0; fw <= 0; rw <= 0;
            blocks_filled <= 0;
            fill_active <= 0; read_active <= 0; fill_done <= 0; read_done <= 0;
            presented <= 0;
            grant_w <= 1'b1;
            session <= 0; read_cnt <= 2'b00;
            busy <= 0;
            words_written <= 0; words_read <= 0;
            fills_done <= 0; reads_done <= 0;
            reads_in_overlap <= 0;
        end else if (session) begin
            // 会话中: go 已无关, 持续推进整窗战役
            a_valid <= 0;
            s_ready <= 0;
            r_valid <= 0;

            // 读计数递减: 3(已发出)->1(可采)->0; 采数沿见下
            if (read_cnt == 2'b11)      read_cnt <= 2'b01;
            else if (read_cnt == 2'b01) read_cnt <= 2'b00;

            // ---- 仲裁分发 (拍级 round-robin, 池口借 a_rdy) ----
            if (a_rdy) begin
                if (wrq && (!rrq || !grant_w)) begin      // 写 (发号沿推进计数)
                    a_valid <= 1'b1; a_we <= 1'b1;
                    a_addr  <= f_addr;
                    a_wdata <= s_data;
                    s_ready <= 1'b1;
                    words_written <= words_written + 1'b1;
                    if (fw == HBUF - 1) begin
                        nf <= nf + 1'b1;
                        blocks_filled <= blocks_filled + 1'b1;
                        fills_done <= fills_done + 1'b1;
                        if (nf == NBUF - 1) begin
                            fill_done <= 1'b1;
                            fill_active <= 1'b0;
                        end
                    end
                    fw <= fw + 1'b1;
                end else if (rrq && (!wrq || grant_w)) begin // 读 (发号沿登记地址)
                    a_valid <= 1'b1; a_we <= 1'b0;
                    a_addr  <= r_addr;
                    read_cnt <= 2'b11;      // 发出->(下沿池接受)->(再下沿采数)
                    if (fill_active)
                        reads_in_overlap <= reads_in_overlap + 1'b1;
                end
                if (wrq && rrq) grant_w <= ~grant_w;
            end

            // ---- 读采数: 发出后第 2 沿, a_rdata 恰为本地址 ----
            if (read_cnt == 2'b01) begin
                r_data   <= a_rdata;
                r_valid  <= 1'b1;
                presented<= 1'b1;
                words_read <= words_read + 1'b1;
            end

            // ---- 消费 ----
            if (presented && r_take) begin
                presented <= 1'b0;
                if (rw == HBUF - 1) begin
                    nr <= nr + 1'b1;
                    reads_done <= reads_done + 1'b1;
                    if (nr == NBUF - 1) begin
                        read_done <= 1'b1;
                        read_active <= 1'b0;
                    end
                end
                rw <= rw + 1'b1;
            end

            if (fill_done && read_done) begin
                busy <= 1'b0;
                session <= 1'b0;             // 收口回待命 (go 已撤, 不重触发)
            end
        end else begin
            // 待命: go 沿触发新会话
            a_valid <= 0; s_ready <= 0; r_valid <= 0;
            if (go && !busy) begin
                busy <= 1'b1;
                session <= 1'b1;
                fill_active <= 1'b1;
                read_active <= 1'b1;
            end
        end
    end
endmodule
`default_nettype wire