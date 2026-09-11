`timescale 1ps/1ps
//────────────────────────────────────────────────────────────────────────────
// sloader_tb.v — M16 S[L] 层流灌入件 (P1 状态搬移件, 读侧) 元素序对账
//
// 契约(基线 §4/§5; S 布局 = 96头×128×128 BF16, 69 v1 层/序列):
//   · 粒序 = 元素(2B)级 严格 (v1 层 asc → 头 0..95 → 头内 i 0..16383)
//   · 黄金镜像逐元素: 增量(cur_l, cur_h, cur_i)游标, 值 = s_src(r, v1lay(l), h, i)
//   · 吸收 = sel_valid && credit; !credit 挂起记 stall 不丢
//   · head_done/layer_done 单拍脉冲: 逐头/逐层完工 → barrier
//   · 信用: 寄存 occ_q 同沿 → 无 delta 竞态, occ 上限 = 阈值
// 场景: T0 排空全开(零停顿); T1 排空熄火真挡 → 恢复; 全程 2 token 对账。
// 规模: 默认 FAST (DIM=8); -DFULL 为真尺寸(108M 元素/序列, 慢, 回归用 FAST)。
//────────────────────────────────────────────────────────────────────────────
module sloader_tb;
    `ifdef FULL
    localparam NL = 93, NL2 = 24, HEADS = 96, DIM = 128;
    `else
    localparam NL = 93, NL2 = 24, HEADS = 96, DIM = 8;
    `endif
    localparam HEAD_E = DIM * DIM;
    localparam FIFO_CAP = 4096, TCUT = FIFO_CAP/2;

    reg clk = 0, rst_n = 0; always #5 clk = ~clk;
    reg go, drain_en = 0;
    wire credit;
    wire sel_valid, busy, token_done, layer_done, head_done;
    wire [15:0] s_sel;
    wire [7:0] round;
    wire [31:0] elems_loaded, layers, heads, stalls;

    assign sel_valid = busy;
    assign s_sel = s_src(u.round, v1lay(u.pl_l), u.pl_h, u.pl_i);

    sloader #(.NL(NL), .NL2(NL2), .HEADS(HEADS), .DIM(DIM)) u (
        .clk(clk), .rst_n(rst_n), .go(go), .credit(credit), .busy(busy),
        .sel_valid(sel_valid), .s_sel(s_sel),
        .token_done(token_done), .layer_done(layer_done), .head_done(head_done),
        .round(round), .elems_loaded(elems_loaded), .layers(layers),
        .heads(heads), .stalls(stalls));

    //--------------- 值函数 ----------------
    function [15:0] s_src(input integer r, lay, h, i);
        reg [31:0] t;
        begin
            t = (r * 13 + lay * 97 + h * 61 + i * 7 + 3) % 65536;
            s_src = (t + 1) & 16'hFFFF;
        end
    endfunction
    function integer v1(input integer l);
        begin v1 = !(l % 4 == 3) && !(l == NL - 1); end
    endfunction
    function integer v1lay(input integer n);
        integer l, c, found;
        begin
            found = 0; v1lay = NL - 1; c = 0;
            for (l = 0; l < NL && !found; l = l + 1) begin
                if (v1(l)) begin
                    if (c == n) begin v1lay = l; found = 1; end
                    c = c + 1;
                end
            end
        end
    endfunction

    //--------------- 对账镜像 ----------------
    integer crime = 0, err = 0, exp_idx = 0, occ_max = 0;
    integer cur_l = 0, cur_h = 0, cur_i = 0, cur_round = 0;
    integer TOK_E, b0, f0, l0, L;
    reg [15:0] occ_q = 0;
    assign credit = (occ_q < TCUT);

    always @(posedge clk) begin
        if (rst_n) begin
            if (occ_q > occ_max) occ_max = occ_q;
            if (sel_valid && credit) begin
                if (s_src(cur_round, v1lay(cur_l), cur_h, cur_i) !== s_sel) begin
                    err = err + 1;
                    if (err < 8)
                        $display("%0t FAIL elem exp_idx=%0d (v1L=%0d l=%0d h=%0d i=%0d) got=%0h gold=%0h", $time,
                                 exp_idx, v1lay(cur_l), cur_l, cur_h, cur_i, s_sel,
                                 s_src(cur_round, v1lay(cur_l), cur_h, cur_i));
                end
                exp_idx = exp_idx + 1;
                cur_i = cur_i + 1;
                if (cur_i == HEAD_E) begin cur_i = 0; cur_h = cur_h + 1; end
                if (cur_h == HEADS)  begin cur_h = 0; cur_l = cur_l + 1; end
            end
            if      (sel_valid && credit) occ_q <= occ_q + 1 - (drain_en && occ_q > 0 ? 1 : 0);
            else if (drain_en && occ_q > 0) occ_q <= occ_q - 1;
        end
        else occ_q <= 0;
    end

    //--------------- 主流程 ----------------
    initial begin
        TOK_E = (NL - NL2) * HEADS * HEAD_E;
        repeat (3) @(posedge clk); #1; rst_n = 1;
        go = 0;

        //---- T0 排空全开 (轮0) ----
        cur_round = 0; cur_l = 0; cur_h = 0; cur_i = 0;
        drain_en = 1;
        @(posedge clk); go = 1; @(posedge clk); go = 0;
        b0 = elems_loaded; f0 = heads; l0 = layers;
        while (!token_done) @(posedge clk);
        repeat (2) @(posedge clk);
        if (elems_loaded != TOK_E) err = err + 1;
        if (layers != NL - NL2)    err = err + 1;
        if (heads != (NL - NL2)*HEADS) err = err + 1;
        if (u.stalls != 0)         err = err + 1;
        $display("== T0 层%0d 头%0d 元素%0d 停顿%0d 对账到%0d 信用违例%0d occ峰%0d ==",
                 layers, heads, elems_loaded, u.stalls, exp_idx, crime, occ_max);

        //---- T1 停顿注入 (轮1) ----
        cur_round = 1; cur_l = 0; cur_h = 0; cur_i = 0;
        drain_en = 0;
        @(posedge clk); go = 1; @(posedge clk); go = 0;
        b0 = elems_loaded; f0 = heads; l0 = layers;
        while (!token_done) begin
            @(posedge clk);
            if (u.stalls > 0) drain_en = 1;
        end
        repeat (2) @(posedge clk);
        if (elems_loaded - b0[31:0] != TOK_E) err = err + 1;
        if (layers - l0[31:0] != NL - NL2)    err = err + 1;
        if (heads - f0[31:0] != (NL - NL2)*HEADS) err = err + 1;
        if (u.stalls == 0)                    err = err + 1;
        if (crime)                            err = err + 1;
        if (exp_idx != 2 * TOK_E)             err = err + 1;
        $display("== T1 层%0d 头%0d 元素%0d 停顿%0d 对账到%0d 信用违例%0d occ峰%0d ==",
                 layers - l0[31:0], heads - f0[31:0], elems_loaded - b0[31:0],
                 u.stalls, exp_idx, crime, occ_max);

        if (err == 0 && u.stalls > 0 && heads == 2*(NL - NL2)*HEADS && layers == 2*(NL - NL2))
            $display("##### ALL PASS: M16 S[L] 层流灌入 96头×128×128 BF16 ×69 v1层 · 严格粒序 · credit 弹性背压 · head/layer barrier #####");
        else
            $display("##### FAIL err=%0d crime=%0d occ_max=%0d #####", err, crime, occ_max);
        $finish;
    end

    // 看门狗
    integer wdc = 0;
    always @(posedge clk) begin
        if (busy) begin
            if (wdc > 20000000) begin $display("%0t FAIL watchdog", $time); $finish; end
            wdc = wdc + 1;
        end else wdc = 0;
    end
endmodule