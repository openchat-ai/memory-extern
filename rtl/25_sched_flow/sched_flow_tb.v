`timescale 1ps/1ps
`default_nettype none

// sched_flow_tb.v — M10 专家装配调度接入验收
//
// 顶层真件: wb_flow(层流水灌权重) + sched_flow(装配调度皮层) + selfsched4(三级预取)
// + sram_pool_arb(B) —— sched_flow 把每层 router top-16 的实体标签喂入 sched4,
// 层号推进由 wb_flow.layers_done(node_layer_sync) 双缓冲栅栏节拍(不越界)。
//
// 场景:
//   R0  谱A(跨层热门复用): 每层首词 101(必查头), 1..3 词 102..104 跨层复用,
//       其余 LFSR 随机。层尾预取最热 PF 个 → 下一层 3 词命中预取池。
//       对账: 逐词日志(层, 词, tag)==gold; 查询 128 词严格层序; prefok 高。
//   R1  谱B(纯随机无复用): 预取张力全无 → prefok 趋零; 结构自洽不变。
//   R2  变速: tag 源 1-in-3 + wb_flow 家源变速 + 随机释放滞后 → layer_sync 对齐不破。
//   R3  续跑: go 清零后整轮重跑 clean。

module sched_flow_tb;
    // —— 配置 (与 M9 wb_flow / selfsched4 匹配) ——
    parameter DW   = 32, AWB   = 8, SW   = 16, NL  = 8;
    parameter AW   = 16, K     = 16, PF   = 4;
    localparam TOT  = NL * SW;
    localparam TAG8 = NL * K;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg go_flow = 0, go_sf = 0;
    reg rl_valid = 0;
    reg [31:0] rl_layer = 0;
    reg churn_en = 0;
    reg [2:0] mask3 = 0;
    reg [7:0] rng = 8'h9e;

    // ---- wb_flow 家源 (M9 同款) ----
    reg [31:0] wp = 0;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) wp <= 0;
        else if (s_ready_flow && s_valid) wp <= wp + 1;

    wire busy_flow, s_ready_flow, s_valid, g_rdy, release_bad;
    wire g_valid, g_we, s_valid_wb, t_valid;
    wire [AWB-1:0] g_addr;
    wire [DW-1:0] s_data, g_wdata;
    wire [31:0] layer_fill, layers_done, words_this, overlap_cnt, barrier_stalls;
    wire [31:0] g_ops, a_ops, switches;

    function automatic [32:0] pwr(input [31:0] L, input [31:0] w);
        begin
            pwr = (L * 104729 + w * 131 + 7) & 32'h00FFFFFF;
        end
    endfunction
    assign s_valid = (wp < TOT) && (~churn_en || (mask3 != 2'd2));
    assign s_valid_wb = s_valid;
    assign s_data  = pwr(wp / SW, wp % SW);

    // ---- sched_flow / selfsched4 网 ----
    wire busy_sf, t_ready, q_req, pf_req, hot_wen;
    wire [AW-1:0] t_data, q_tag, pf_tag, hot_data;
    wire [1:0] hot_addr;
    wire [31:0] layer_now_sf, q_done, pf_done, layers_done_sf;
    wire [31:0] s_hit, s_miss, s_l0, s_l1, s_pf, s_pref, s_prefok;

    // tag 源词指针: 收 1 词自增, 满 K 回绕 (新层自动续)
    reg [5:0] tw = 0;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) tw <= 0;
        else if (t_ready && t_valid) tw <= (tw == K - 1) ? 0 : tw + 1;

    reg use_spect_b = 0;
    function automatic [15:0] th(input [31:0] L, input [31:0] i);
        begin
            if (use_spect_b)
                th = (L * 7919 + i * 104729) & 16'hFFFF;
            else if (i == 0)
                th = 16'd101;
            else if (i < 4)
                th = 16'd101 + i;          // 102..104 跨层复用 (层尾预取目标)
            else
                th = ((L * 1009 + i * 977) & 16'hFF00) | (i & 15);
        end
    endfunction
    // tag 源按层节拍铰链: 层 L 的 16 词在本层灌入 (layer_fill>=L) 后才可得
    // (基线 router gate/实体装配随层载荷, 天然与 wb_flow 同拍)
    assign t_valid = (tw < K) && (~churn_en || (mask3 != 2'd3)) && busy_sf
                     && (layer_fill >= layer_now_sf);
    assign t_data  = th(layer_now_sf, tw);

    // 逐查询日志 (层[3:0], 词[3:0], tag[15:0]) 对账严格层序 + 图案
    reg [31:0] ql [0:255];
    integer qcnt = 0;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) qcnt <= 0;
        else if (q_req) begin
            `ifdef M10_DBG
            $display("  %0t q_req: lay=%0d tw=%0d tag=%04x", $time, layer_now_sf, tw, q_tag);
            `endif
            ql[qcnt] <= {layer_now_sf[3:0], tw[3:0], q_tag};
            qcnt     <= qcnt + 1;
        end

    // R2 变速节拍: 全局 1-in-3 停顿 (wb 家源 mask3==2, tag 源 mask3==3 各停一拍)
    always @(posedge clk or negedge rst_n)
        if (!rst_n) mask3 <= 0;
        else        mask3 <= mask3 + 1;

    // ---- 真件例化 ----
    wb_flow #(.DW(DW), .AW(AWB), .SLICE_W(SW), .NL(NL)) u_flow (
        .clk(clk), .rst_n(rst_n),
        .go(go_flow), .busy(busy_flow),
        .s_valid(s_valid_wb), .s_data(s_data), .s_ready(s_ready_flow),
        .g_rdy(g_rdy), .g_valid(g_valid), .g_we(g_we),
        .g_addr(g_addr), .g_wdata(g_wdata),
        .rl_valid(rl_valid), .rl_layer(rl_layer), .release_bad(release_bad),
        .layer_fill(layer_fill), .layers_done(layers_done),
        .words_this(words_this), .overlap_cnt(overlap_cnt),
        .barrier_stalls(barrier_stalls)
    );

    sched_flow #(.AW(AW), .K(K), .PF(PF), .NL(NL)) u_sf (
        .clk(clk), .rst_n(rst_n),
        .go(go_sf), .busy(busy_sf),
        .t_valid(t_valid), .t_data(t_data), .t_ready(t_ready),
        .q_req(q_req), .q_tag(q_tag),
        .pf_req(pf_req), .pf_tag(pf_tag),
        .hot_wen(hot_wen), .hot_addr(hot_addr), .hot_data(hot_data),
        .layer_sync(layers_done),
        .layer_now(layer_now_sf), .q_done(q_done), .pf_done(pf_done),
        .layers_done(layers_done_sf)
    );

    selfsched4 #(.AW(AW), .L0N(4), .L1S(4), .L1W(2), .P1S(4), .P1W(2)) u_s4 (
        .clk(clk), .rst(~rst_n),
        .req(q_req), .tag(q_tag),
        .pf_req(pf_req), .pf_tag(pf_tag),
        .hot_wen(hot_wen), .hot_addr(hot_addr), .hot_data(hot_data),
        .s_hit(s_hit), .s_miss(s_miss), .s_l0(s_l0), .s_l1(s_l1),
        .s_pf(s_pf), .s_pref(s_pref), .s_prefok(s_prefok)
    );

    sram_pool_arb #(.AW(AWB), .DW(DW)) u_pool (
        .clk(clk), .rst_n(rst_n),
        .sel(1'b0),
        .g_valid(g_valid), .g_we(g_we), .g_addr(g_addr),
        .g_wdata(g_wdata), .g_rdy(g_rdy), .g_rdata(),
        .a_valid(1'b0), .a_we(1'b0), .a_addr('0), .a_wdata('0),
        .a_rdy(), .a_rdata(),
        .g_ops(g_ops), .a_ops(a_ops), .switches(switches)
    );

    // 每轮对 sched4 累计计数取快照, check 用 delta (sched4 仅复位清零)
    integer snap_hit, snap_miss, snap_l0, snap_l1, snap_pf, snap_pref, snap_prefok;

    // ---- 任务 ----
    task automatic start_round;
        begin
            wp = 0; qcnt = 0;
            snap_hit = s_hit; snap_miss = s_miss; snap_l0 = s_l0;
            snap_l1  = s_l1;  snap_pf   = s_pf;   snap_pref = s_pref;
            snap_prefok = s_prefok;
            go_flow = 1; go_sf = 1;
            while (!(busy_flow && busy_sf)) @(posedge clk);
            go_flow = 0; go_sf = 0;
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
            rl_valid = 1; rl_layer = k;
            while (layers_done <= k) @(posedge clk);
            rl_valid = 0;
        end
    endtask

task automatic check_round(input string name, input integer want_prefok_min,
                               input integer want_prefok_max);
        integer i, L, w, dh, dm, dl0, dpref, dok;
        reg ok;
        begin
            dh = s_hit - snap_hit;
            dm = s_miss - snap_miss;
            dl0 = s_l0 - snap_l0;
            dpref = s_pref - snap_pref;
            dok   = s_prefok - snap_prefok;
            ok = 1;
            if (wp !== TOT)               ok = 0;
            if (layers_done_sf !== NL)    ok = 0;
            if (q_done !== TAG8)          ok = 0;
            if (pf_done !== NL * PF)      ok = 0;
            if (dh + dm !== q_done)       ok = 0;
            if (s_pf - snap_pf !== dok)   ok = 0;
            if (dl0 !== NL)               ok = 0;
            if (dok < want_prefok_min || dok > want_prefok_max) ok = 0;
            // 逐查询日志: 严格层序 + 每层 K 词 + 图案一致
            if (qcnt !== TAG8) ok = 0;
            for (i = 0; i < TAG8 && ok; i = i + 1) begin
                L = i / K; w = i % K;
                if (ql[i][20 +: 4] !== L) begin
                    $display("  ql[%0d] 层错: got L=%0d 期望 %0d (w=%0d)", i,
                             ql[i][20 +: 4], L, w);
                    ok = 0;
                end
                if (ql[i][16 +: 4] !== w) begin
                    $display("  ql[%0d] 词序错: got w=%0d 期望 %0d (L=%0d)", i,
                             ql[i][16 +: 4], w, L);
                    ok = 0;
                end
                if (ql[i][15:0] !== th(L, w)) begin
                    $display("  ql[%0d] 图案错: got=16'h%04x 期望%04x (L=%0d w=%0d)",
                             i, ql[i][15:0], th(L, w), L, w);
                    ok = 0;
                end
            end
            if (ok)
                $display("%s 层序=0..%0d 逐词%0d/%0d对账 miss=%0d hit=%0d l0=%0d pref=%0d/o%0d  节点=层流对齐",
                         name, NL-1, qcnt, TAG8, dm, dh, dl0, dpref, dok);
            else begin
                $display("%s FAIL: q=%0d pf=%0d ldsf=%0d hit=%0d miss=%0d l0=%0d pref=%0d/ok=%0d",
                         name, q_done, pf_done, layers_done_sf,
                         dh, dm, dl0, dpref, dok);
                $display("  ql[0..2]=%08x / %08x / %08x", ql[0], ql[1], ql[2]);
                $fatal(1);
            end
        end
    endtask

    initial begin
        integer k;
        repeat (3) @(posedge clk); #1; rst_n = 1;
        churn_en = 0; use_spect_b = 0;

        // ---- R0 谱A: 跨层热门复用 → 预取张力 ----
        start_round;
        for (k = 0; k < NL; k = k + 1) release_one(k, 2);
        while (busy_sf) @(posedge clk);
        check_round("R0", 18, 26);

        // ---- R1 谱B: 纯随机无复用 → prefok 趋零 (结构自洽必须保持) ----
        use_spect_b = 1;
        start_round;
        for (k = 0; k < NL; k = k + 1) release_one(k, 2);
        while (busy_sf) @(posedge clk);
        check_round("R1", 0, 5);

        // ---- R2 变速: 1-in-3 tag 源 + wb 家源变速 + 随机滞后 ----
        use_spect_b = 0;
        churn_en = 1;
        start_round;
        for (k = 0; k < NL; k = k + 1) begin
            prng;
            release_one(k, rng & 5'd9);
        end
        while (busy_sf) @(posedge clk);
        if (q_done !== TAG8 || layers_done_sf !== NL) begin
            $display("R2 FAIL: q=%0d done=%0d", q_done, layers_done_sf);
            $fatal(1);
        end
        check_round("R2", 18, 26);

        // ---- R3 续跑: go 清零再整轮 clean ----
        churn_en = 0;
        start_round;
        for (k = 0; k < NL; k = k + 1) release_one(k, 1);
        while (busy_sf) @(posedge clk);
        check_round("R3", 18, 26);

        $display("##### ALL PASS: M10 sched4 接入 专家装配预取调度+层节拍对齐 #####");
        $finish;
    end

    initial begin
        #2000000;
        $display("M10 FAIL: 超时");
        $finish;
    end
endmodule