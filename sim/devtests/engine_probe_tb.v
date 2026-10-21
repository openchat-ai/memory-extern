`timescale 1ps/1ps
// engine_probe_tb — 板级配置下实测: 引擎(attn/GEMV)路径哪些信号真会动
// 目的: 把"引擎活动"引到 LED 之前, 先证明哪些信号在 board_decode_top 的
//       全 tie-off 配置下真在翻转/递增 (否则引了也是常亮=无信息)。
// 判据: 打印每个探针的 变化次数 与 末值; 变化次数=0 的不能拿来做判活。
module engine_probe_tb;
    reg clk = 0, rst_n = 0;
    wire [5:0] led;
    integer i;
    integer c_go, c_a_go, c_a_s_valid, c_aw_busy, c_ctl_busy, c_ctl_o_valid;
    integer c_gemm_done, c_attn_done, c_layers_done, c_sel_sw, c_barrier;
    integer c_wg, c_wa, c_aw_ww, c_aw_wr, c_ctl_words, c_ctl_rows, c_ctl_blocks;
    integer c_arr, c_rail_words, c_rail_frames, c_st;
    reg [31:0] prev_gemm, prev_attn, prev_wg, prev_wa, prev_awww, prev_awwr;
    reg [31:0] prev_ctlw, prev_ctlr, prev_ctlb, prev_railw, prev_railf;
    reg [15:0] prev_arr;
    reg [2:0]  prev_st;

    board_decode_top U(.sys_clk(clk), .rst_n(rst_n), .led(led));
    always #5 clk = ~clk;

    // 引擎内部探针 (层级引用)
    wire        e_a_go    = U.U.ex_a_go;
    wire        e_a_sval = U.U.ex_a_s_valid;
    wire        e_aw_busy= U.U.aw_busy;
    wire        e_ctl_bus= U.U.ctl_busy;
    wire        e_ctl_ov = U.U.ctl_o_valid;
    wire [2:0]  e_st     = U.U.ex_st;
    wire [31:0] e_gemm   = U.U.ex_gemm_done;
    wire [31:0] e_attn   = U.U.ex_attn_done;
    wire [31:0] e_lay    = U.U.ex_layers_done;
    wire [31:0] e_sel    = U.U.ex_sel_sw;
    wire [31:0] e_bar    = U.U.ex_barrier;
    wire [31:0] e_wg     = U.U.ex_wg_words;
    wire [31:0] e_wa     = U.U.ex_wa_words;
    wire [31:0] e_awww   = U.U.aw.words_written;
    wire [31:0] e_awwr   = U.U.aw.words_read;
    wire [31:0] e_ctlw   = U.U.ctl_words;
    wire [31:0] e_ctlr   = U.U.ctl_rows;
    wire [31:0] e_ctlb   = U.U.ctl_blocks_done;
    wire [15:0] e_arr    = U.U.arr_acc_out;
    wire [31:0] e_railw  = U.U.rail_words;
    wire [31:0] e_railf  = U.U.rail_frames;
    wire        e_ctlbus = U.U.ctl_busy;
    wire        e_awbus  = U.U.aw_busy;
    wire [31:0] e_wbase  = U.U.u_ex.wbase;
    wire [31:0] e_rbase  = U.U.u_ex.rbase;
    wire [31:0] e_aww_s  = U.U.u_ex.aww;
    // sched_exec 端口实况 (FSM 真正看到的值)
    wire [31:0] x_a_ww   = U.U.u_ex.a_ww;
    wire [31:0] x_a_wr   = U.U.u_ex.a_wr;
    wire [31:0] x_cblk   = U.U.u_ex.c_blocks;
    wire        x_cbusy  = U.U.u_ex.c_busy;
    wire [2:0]  x_st     = U.U.u_ex.st_o;
    wire [31:0] x_atd    = U.U.u_ex.attn_done;
    wire [31:0] x_aww_w  = U.U.aw_words_written;
    wire [31:0] x_awr_w  = U.U.aw_words_read;

    always @(posedge clk) if (rst_n) begin
        if (e_a_go    !== prev_go_p)  c_a_go     = c_a_go + 1;
        if (e_a_sval !== 1'b0)       c_a_s_valid= c_a_s_valid + 1;
        if (e_aw_busy!== 1'b0)       c_aw_busy  = c_aw_busy + 1;
        if (e_ctl_bus!== 1'b0)       c_ctl_busy = c_ctl_busy + 1;
        if (e_ctl_ov !== 1'b0)       c_ctl_o_valid = c_ctl_o_valid + 1;
        if (e_st     !== prev_st)    c_st       = c_st + 1;
        if (e_gemm   !== prev_gemm)  c_gemm_done  = c_gemm_done + 1;
        if (e_attn   !== prev_attn)  c_attn_done  = c_attn_done + 1;
        if (e_lay    !== prev_lay0)  c_layers_done= c_layers_done+ 1;
        if (e_sel    !== prev_sel0)  c_sel_sw     = c_sel_sw + 1;
        if (e_bar    !== prev_bar0)  c_barrier    = c_barrier + 1;
        if (e_wg     !== prev_wg)    c_wg         = c_wg + 1;
        if (e_wa     !== prev_wa)    c_wa         = c_wa + 1;
        if (e_awww   !== prev_awww)  c_aw_ww      = c_aw_ww + 1;
        if (e_awwr   !== prev_awwr)  c_aw_wr      = c_aw_wr + 1;
        if (e_ctlw   !== prev_ctlw)  c_ctl_words  = c_ctl_words + 1;
        if (e_ctlr   !== prev_ctlr)  c_ctl_rows   = c_ctl_rows + 1;
        if (e_ctlb   !== prev_ctlb)  c_ctl_blocks = c_ctl_blocks + 1;
        if (e_arr    !== prev_arr)   c_arr        = c_arr + 1;
        if (e_railw  !== prev_railw) c_rail_words = c_rail_words + 1;
        if (e_railf  !== prev_railf) c_rail_frames= c_rail_frames+ 1;
        prev_st = e_st; prev_gemm = e_gemm; prev_attn = e_attn; prev_lay0 = e_lay;
        prev_sel0 = e_sel; prev_bar0 = e_bar; prev_wg = e_wg; prev_wa = e_wa;
        prev_awww = e_awww; prev_awwr = e_awwr; prev_ctlw = e_ctlw;
        prev_ctlr = e_ctlr; prev_ctlb = e_ctlb; prev_arr = e_arr;
        prev_railw = e_railw; prev_railf = e_railf;
        prev_go_p = e_a_go;
    end

    reg prev_go_p; reg [31:0] prev_lay0, prev_sel0, prev_bar0;

    reg [31:0] peak_layers = 0;
    reg [31:0] prev_go_cnt;
    integer go_pulses;
    always @(posedge clk) if (rst_n) begin
        if (e_lay > peak_layers) peak_layers = e_lay;
    end

    initial begin
        c_go=0; c_a_go=0; c_a_s_valid=0; c_aw_busy=0; c_ctl_busy=0; c_ctl_o_valid=0;
        c_gemm_done=0; c_attn_done=0; c_layers_done=0; c_sel_sw=0; c_barrier=0;
        c_wg=0; c_wa=0; c_aw_ww=0; c_aw_wr=0; c_ctl_words=0; c_ctl_rows=0; c_ctl_blocks=0;
        c_arr=0; c_rail_words=0; c_rail_frames=0; c_st=0;
        prev_gemm=0; prev_attn=0; prev_lay0=0; prev_sel0=0; prev_bar0=0;
        prev_wg=0; prev_wa=0; prev_awww=0; prev_awwr=0; prev_ctlw=0; prev_ctlr=0;
        prev_ctlb=0; prev_arr=0; prev_railw=0; prev_railf=0; prev_st=0; prev_go_p=0;
        repeat (10) @(posedge clk); rst_n = 1;
        repeat (20000) @(posedge clk);
        $display("==== 引擎探针 (20000 拍, 板级 tie-off 配置) ====");
        $display("a_go 变化次数        = %0d", c_a_go);
        $display("a_s_valid 高拍数     = %0d", c_a_s_valid);
        $display("aw_busy 高拍数       = %0d", c_aw_busy);
        $display("ctl_busy 高拍数      = %0d", c_ctl_busy);
        $display("ctl_o_valid 高拍数   = %0d", c_ctl_o_valid);
        $display("ex_st 变化次数       = %0d   末值=%0d", c_st, e_st);
        $display("gemm_done 变化次数   = %0d   末值=%0d", c_gemm_done, e_gemm);
        $display("attn_done 变化次数   = %0d   末值=%0d", c_attn_done, e_attn);
        $display("layers_done 变化次数 = %0d   末值=%0d", c_layers_done, e_lay);
        $display("sel_switches 变化次数= %0d   末值=%0d", c_sel_sw, e_sel);
        $display("barrier 变化次数     = %0d   末值=%0d", c_barrier, e_bar);
        $display("wg_words 变化次数    = %0d   末值=%0d", c_wg, e_wg);
        $display("wa_words 变化次数    = %0d   末值=%0d", c_wa, e_wa);
        $display("aw.words_written 变化= %0d   末值=%0d", c_aw_ww, e_awww);
        $display("aw.words_read 变化  = %0d   末值=%0d", c_aw_wr, e_awwr);
        $display("ctl_words 变化次数   = %0d   末值=%0d", c_ctl_words, e_ctlw);
        $display("ctl_rows 变化次数    = %0d   末值=%0d", c_ctl_rows, e_ctlr);
        $display("ctl_blocks_done 变化 = %0d   末值=%0d", c_ctl_blocks, e_ctlb);
        $display("arr_acc_out 变化次数 = %0d   末值=%h", c_arr, e_arr);
        $display("rail_words 变化次数  = %0d   末值=%0d", c_rail_words, e_railw);
        $display("rail_frames 变化次数 = %0d   末值=%0d", c_rail_frames, e_railf);
        $display("---- 末态电平 ----");
        $display("ctl_busy 末值 = %b   aw_busy 末值 = %b   ex_st 末值 = %0d", e_ctlbus, e_awbus, e_st);
        $display("attn_done=%0d  gemm_done=%0d  layers_done=%0d", e_attn, e_gemm, e_lay);
        $display("wbase=%0d rbase=%0d aww=%0d  (a_ww-wbase=%0d, a_wr-rbase=%0d)",
                 e_wbase, e_rbase, e_aww_s, e_awww - e_wbase, e_awwr - e_rbase);
        $display("ctl_blocks_done=%0d  (BPT=%0d, 需要 >= (attn_done+1)*BPT = %0d)",
                 e_ctlb, 8, (e_attn + 1) * 8);
        $display("---- sched_exec 端口实况 ----");
        $display("u_ex.a_ww=%0d (core.aw_words_written=%0d)  u_ex.a_wr=%0d (core.aw_words_read=%0d)",
                 x_a_ww, x_aww_w, x_a_wr, x_awr_w);
        $display("u_ex.c_blocks=%0d  u_ex.c_busy=%b  u_ex.st_o=%0d  u_ex.attn_done=%0d",
                 x_cblk, x_cbusy, x_st, x_atd);
        $display("条件: (a_ww-wbase)=%0d >= %0d ? %0d | (a_wr-rbase)=%0d >= %0d ? %0d | !c_busy=%0d | c_blocks>=%0d ? %0d",
                 x_a_ww - e_wbase, 128, (x_a_ww - e_wbase) >= 128,
                 x_a_wr - e_rbase, 128, (x_a_wr - e_rbase) >= 128,
                 !x_cbusy,
                 (x_atd + 1) * 8, x_cblk >= (x_atd + 1) * 8);
        $display("---- 自释放 (侧支#8) 效果 ----");
        $display("layers_done 峰值 = %0d  (NL=4, 期望 4)", peak_layers);
        $display("a_go 变化次数 = %0d (每 2 次 = 1 个 go 脉冲)", c_a_go);
        $display("板级 LED[5:0] = %b  (bit4=attn PASS, bit5=GEMM&4层 PASS)", led);
        $finish;
    end
endmodule
