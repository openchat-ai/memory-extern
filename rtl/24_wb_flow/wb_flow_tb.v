`timescale 1ps/1ps
`default_nettype none

// M9 wb_flow TB——层流调度 + 权重广播灌池 验收
//
// 场景:
//   R0  零滞后: 每层灌完立即释放 → 严格层序/SLICE_W 恰好一次/池图像对账
//   R1  滞后6拍: 释放慢 → 预取重叠(overlap)与槽位挡(barrier)吃满
//   R2  变速: 源 1-in-3 间断 + 每层 0..9 随机滞后 → 不丢不乱, 镜像逐拍对账
//   RB  越序罪证: 期望层 0 却给 2 → release_bad 锁定且不推进
//   R3  续跑: 再走一整轮, release_bad 须随 go 清零
//
// 每轮终态断言: wp==TOT(无丢词) / layers_done==NL / 双槽池图像==gold
// / overlap_cnt·barrier_stalls 与镜像逐拍模型严格相等。
// 结构性不变量(层灌入恰领先释放一层): overlap==NL-1。

module wb_flow_tb;
    parameter DW = 32, AW = 8, SW = 16, NL = 8;
    localparam LB = $clog2(NL);
    localparam TOT = NL * SW;

    reg clk = 0, rst_n = 0, go = 0;
    reg rl_valid = 0;
    reg [LB-1:0] rl_layer = 0;
    reg churn_en = 0;
    reg [31:0] wp = 0;                   // 源侧已递词数 (接受沿自增, 图案随之顺移)
    always @(posedge clk or negedge rst_n)
        if (!rst_n) wp <= 0;
        else if (s_ready && s_valid) wp <= wp + 1;
    reg [1:0] mask3 = 0;
    reg [7:0] rng = 8'h9e;

    wire busy, s_ready, s_valid, g_rdy, release_bad;
    wire g_valid, g_we;
    wire [AW-1:0] g_addr;
    wire [DW-1:0] s_data, g_wdata;
    wire [31:0] layer_fill, layers_done, words_this, overlap_cnt, barrier_stalls;
    wire [31:0] g_ops, a_ops, switches;

    // 逐写日志: 每次池接受沿捕捉 (地址,数据), 与本轮词序重构的期望逐条比对
    reg [AW-1:0] wadr [0:255];
    reg [DW-1:0] wdat [0:255];
    integer wcnt = 0;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) wcnt <= 0;
        else if (g_valid) begin
            wadr[wcnt] <= g_addr;
            wdat[wcnt] <= g_wdata;
            wcnt       <= wcnt + 1;
        end

    // ---- 源: 组合逻辑, 词序=wp(与设备采样同拍, M6 source 纪律) ----
    function automatic [31:0] pwr(input [31:0] L, input [31:0] w);
        begin
            pwr = (L * 104729 + w * 131 + 7) & 32'h00FFFFFF;
        end
    endfunction
    assign s_valid = (wp < TOT) && (~churn_en || (mask3 != 2'd2));
    assign s_data  = pwr(wp / SW, wp % SW);

    always #5 clk = ~clk;

    wb_flow #(
        .DW(DW), .AW(AW), .SLICE_W(SW), .NL(NL)
    ) u_flow (
        .clk(clk), .rst_n(rst_n),
        .go(go), .busy(busy),
        .s_valid(s_valid), .s_data(s_data), .s_ready(s_ready),
        .g_rdy(g_rdy), .g_valid(g_valid), .g_we(g_we),
        .g_addr(g_addr), .g_wdata(g_wdata),
        .rl_valid(rl_valid), .rl_layer(rl_layer), .release_bad(release_bad),
        .layer_fill(layer_fill), .layers_done(layers_done),
        .words_this(words_this), .overlap_cnt(overlap_cnt),
        .barrier_stalls(barrier_stalls)
    );

    sram_pool_arb #(.AW(AW), .DW(DW)) u_pool (
        .clk(clk), .rst_n(rst_n),
        .sel(1'b0),                   // GEMM 段持权
        .g_valid(g_valid), .g_we(g_we), .g_addr(g_addr),
        .g_wdata(g_wdata), .g_rdy(g_rdy), .g_rdata(),
        .a_valid(1'b0), .a_we(1'b0), .a_addr('0), .a_wdata('0),
        .a_rdy(), .a_rdata(),
        .g_ops(g_ops), .a_ops(a_ops), .switches(switches)
    );

    // ---- 镜像逐拍模型(设备侧规则的独立复算) ----
    integer mlay, mfw, mrel, m_ov, m_bar;
    reg msess;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            msess = 0; mlay = 0; mfw = 0; mrel = 0; m_ov = 0; m_bar = 0;
        end
        else begin
            if (go && !msess) begin
                msess = 1; mlay = 0; mfw = 0; mrel = 0; m_ov = 0; m_bar = 0;
            end
            else if (msess) begin
                // 先按本沿的旧 rel 判 allow(镜像模块非阻塞语义: 释放与灌词同沿不互相放行)
                if ((mlay == 0 || mrel + 1 >= mlay) && (mlay < NL) && s_valid && g_rdy) begin
                    if (mfw == 0 && mlay >= 1 && mrel < mlay) m_ov = m_ov + 1;
                    if (mfw == SW - 1) begin mlay = mlay + 1; mfw = 0; end
                    else mfw = mfw + 1;
                end
                else if (!((mlay == 0) || (mrel + 1 >= mlay)) && (mlay < NL) && s_valid)
                    m_bar = m_bar + 1;
                if (rl_valid && (rl_layer == mrel)) mrel = mrel + 1;
                if (mrel == NL) msess = 0;
            end
        end
    end

    // ---- 驱动任务 ----
    task automatic start_round;
        begin
            wp = 0; mask3 = 0; wcnt = 0;    // 每轮清账
            go = 1;                          // 电平拉高, 直到模块起手再撤(避同沿竞争)
            while (!busy) @(posedge clk);
            go = 0;
        end
    endtask

    task automatic prng;
        begin
            rng = {rng[6:0], rng[6] ^ rng[5] ^ rng[4] ^ rng[3]};
        end
    endtask

    task automatic release_one(input integer k, input integer lag);
        integer d;
        begin
            if (k < NL - 1) while (layer_fill <= k) @(posedge clk);
            else            while (layer_fill <  NL) @(posedge clk);
            for (d = 0; d < lag; d = d + 1) @(posedge clk);
            rl_valid = 1; rl_layer = k;      // 电平拉高, 直到登记释放再撤(避同沿竞争)
            while (layers_done <= k) @(posedge clk);
            rl_valid = 0;
        end
    endtask

    task automatic check_close(input string name);
        integer L, w, i;
        reg ok;
        begin
            ok = 1;
            if (wp !== TOT)              ok = 0;
            if (layers_done !== NL)      ok = 0;
            if (release_bad !== 1'b0 && name != "RB") ok = 0;
            if (release_bad !== 1'b1 && name == "RB") ok = 0;
            if (overlap_cnt !== m_ov)    ok = 0;
            if (barrier_stalls !== m_bar) ok = 0;
            // 逐写日志 == 词序重构的 (地址,数据) 期望 (免疫双槽覆写)
            if (wcnt !== TOT) ok = 0;
            for (i = 0; i < TOT && ok; i = i + 1) begin
                L = i / SW;  w = i % SW;
                if (wadr[i] !== ((L & 1) ? SW : 0) + w) ok = 0;
                if (wdat[i] !== pwr(L, w)) ok = 0;
            end
            if (ok)
                $display("%s 层序=0..%0d 恰一次 逐写%0d/%0d对账 overlap=%0d barrier=%0d  镜像✓",
                         name, NL-1, wcnt, TOT, overlap_cnt, barrier_stalls);
            else begin
                $display("%s FAIL: wp=%0d/%0d done=%0d wcnt=%0d ov=%0d/m%0d bar=%0d/m%0d bad=%b",
                         name, wp, TOT, layers_done, wcnt, overlap_cnt, m_ov,
                         barrier_stalls, m_bar, release_bad);
                $fatal(1);
            end
        end
    endtask

    initial begin
        integer k;
        repeat (3) @(posedge clk); #1; rst_n = 1;   // 复位沉降 3 沿再释放

        // ---- R0 零滞后 ----
        churn_en = 0;
        start_round;
        for (k = 0; k < NL; k = k + 1) release_one(k, 0);
        while (busy) @(posedge clk);
        if (overlap_cnt !== NL - 1 || barrier_stalls !== 0 || layers_done !== NL) begin
            $display("R0 FAIL: overlap=%0d bar=%0d done=%0d", overlap_cnt, barrier_stalls, layers_done);
            $fatal(1);
        end
        check_close("R0");

        // ---- R1 滞后40拍(穿透16词填装, 但被双缓冲吸收/隔离) ----
        churn_en = 0;
        start_round;
        for (k = 0; k < NL; k = k + 1) release_one(k, 40);
        while (busy) @(posedge clk);
        if (overlap_cnt == 0 || barrier_stalls == 0) begin
            $display("R1 FAIL: overlap=%0d barrier=%0d (期望后者 >0 均有预取)", overlap_cnt, barrier_stalls);
            $fatal(1);
        end
        check_close("R1");

        // ---- R2 变速: 源 1-in-3 + 随机滞后 0..9 ----
        churn_en = 1;
        start_round;
        for (k = 0; k < NL; k = k + 1) begin
            prng;
            release_one(k, rng & 5'd9);
        end
        while (busy) @(posedge clk);
        check_close("R2");

        // ---- RB 越序罪证: 期望 0 却给 2 (busy 起来后发, 避 go 拍初始化分支) ----
        churn_en = 0;
        start_round;
        rl_valid = 1; rl_layer = 2;          // 电平拉高, 直到越序旗落锁再撤
        while (!release_bad) @(posedge clk);
        rl_valid = 0;
        for (k = 0; k < NL; k = k + 1) release_one(k, 1);
        while (busy) @(posedge clk);
        check_close("RB");

        // ---- R3 续跑: 越序旗须随 go 清零, 再整轮 ----
        start_round;
        for (k = 0; k < NL; k = k + 1) release_one(k, 2);
        while (busy) @(posedge clk);
        if (release_bad !== 1'b0) begin
            $display("R3 FAIL: 越序旗未随 go 清零");
            $fatal(1);
        end
        check_close("R3");

        $display("##### ALL PASS: M9 wb 层流 权重广播灌池 严格层序 #####");
        $finish;
    end

    initial begin
        #2000000;
        $display("M9 FAIL: 超时");
        $finish;
    end
endmodule
