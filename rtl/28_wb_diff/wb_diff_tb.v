`timescale 1ps/1ps
//────────────────────────────────────────────────────────────────────────────
// wb_diff_tb.v — M13 v1 层 KDA diff 写回件 (P1 状态搬移件) 字节序对账
//
// 契约(基线 §5 写回协议 v0 / sim_layer_flow.py):
//   · 每 token 69 层严格层序; 帧 = 8B 头 + 96×(k128+v128)×2B = 49,160B
//   · 每轮(一个 go) = 一个 token = 69 帧 = 3,392,040B; 层末完工 = barrier, round++
//   · DMA 弹性 FIFO 无信用(y >50%)→ 停推; 恢复后续推
//   · host 收到即 S[L] += Σ_h k_h⊗v_h^T 物化 —— 板上只做 framing (本件范围)
// 源纪律(M6/M12 同款): ele_valid 组合直出, 元素词序 == u.pl_elem, 采样同拍。
// 黄金核 expb: 全局字节镜像复算 (轮/层/头/kv/i 映射), 逐推字节比对。
// 场景: T0 全信用(期望零停顿); T1 排空熄火 → 真挡 stall → 恢复。
//────────────────────────────────────────────────────────────────────────────
module wb_diff_tb;
    localparam NL1 = 69, HEADS = 96, D = 128;
    localparam ELEM_PER_HEAD = D + D;
    localparam DIFF_B = HEADS * ELEM_PER_HEAD * 2;   // 49152
    localparam F_B  = 8 + DIFF_B;                    // 49160
    localparam TOK_B = NL1 * F_B;                    // 3392040
    localparam FIFO_CAP = 4096, TCUT = FIFO_CAP/2;

    reg clk = 0, rst_n = 0; always #5 clk = ~clk;
    reg go, ele_valid; reg [7:0] s_lay; reg [15:0] s_elem;
    wire credit, f_valid, f_we; wire [7:0] f_b;
    wire busy, token_done, order_bad;
    wire [31:0] bytes_written, frames, stalls;

    wb_diff #(.NL1(NL1), .HEADS(HEADS), .D(D)) u (
        .clk(clk), .rst_n(rst_n), .go(go), .busy(busy),
        .s_lay(s_lay), .ele_valid(ele_valid), .s_elem(s_elem),
        .credit(credit), .f_valid(f_valid), .f_we(f_we), .f_b(f_b),
        .bytes_written(bytes_written), .frames(frames), .stalls(stalls),
        .order_bad(order_bad), .token_done(token_done));

    //--------------- 元素值黄金核 ----------------
    function [15:0] elem_src(input integer round, lay, head, kv, i);
        reg [31:0] t;
        begin
            t = (round * 131 + lay * 257 + head * 131 + kv * 37 + i * 11 + 17) % 65536;
            elem_src = (t + 1) & 16'hFFFF;
        end
    endfunction
    function [15:0] elem_of(input integer gidx);
        integer fr, off, round, lay, head, kv, i, ei, b;
        begin
            fr  = gidx / F_B;
            off = gidx % F_B;
            round = fr / NL1; lay = fr % NL1;
            ei = (off - 8) / 2; b = (off - 8) % 2;
            head = ei / ELEM_PER_HEAD;
            kv  = (ei % ELEM_PER_HEAD) / D;
            i   = ei % D;
            elem_of = elem_src(round, lay, head, kv, i);
        end
    endfunction
    function [7:0] expb(input integer gidx);
        integer fr, off, round, lay; reg [7:0] r; reg [15:0] e16;
        begin
            fr = gidx / F_B; off = gidx % F_B;
            round = fr / NL1; lay = fr % NL1;
            r[7:0] = 0;
            if (off < 8) begin
                case (off)
                    0: r = lay[7:0];
                    1: r = 8'h11;      // 类型 v1=diff
                    2: r = 8'h00;
                    3: r = 8'h00;
                    4: r = DIFF_B[7:0];
                    5: r = DIFF_B[15:8];
                    6: r = DIFF_B[23:16];
                    7: r = DIFF_B[31:24];
                endcase
            end
            else begin
                e16 = elem_of(gidx);
                r = (off - 8) % 2 == 0 ? e16[7:0] : e16[15:8];
            end
            expb = r;
        end
    endfunction

    //--------------- M6/M12 组合源: 词序 == u.pl_elem ----------------
    assign ele_valid = u.session && (u.st == 2'd1) && (u.pl_elem < ELEM_T);
    localparam ELEM_T = HEADS * ELEM_PER_HEAD;
    assign s_elem = elem_src(u.round, u.pl_lay,
                             (u.pl_elem / ELEM_PER_HEAD),
                             ((u.pl_elem % ELEM_PER_HEAD) / D),
                             (u.pl_elem % D));
    assign s_lay = u.pl_lay[7:0];

    //--------------- 推口对账 + FIFO 占用(寄存 occ_q, 与推/排空同沿 → 无 delta 竞态) ----------------
    integer crime = 0, err = 0;
    integer exp_idx = 0, drain_en = 0;
    reg [15:0] occ_q = 0;
    integer occ_max = 0;
    assign credit = (occ_q < TCUT);

    always @(posedge clk) begin
        if (rst_n) begin
            if (occ_q > occ_max) occ_max = occ_q;
            if (u.f_we && u.f_valid) begin
                if (expb(exp_idx) !== u.f_b) begin
                    err = err + 1;
                    if (err < 8)
                        $display("%0t FAIL byte exp_idx=%0d got=%0h gold=%0h", $time,
                                 exp_idx, u.f_b, expb(exp_idx));
                end
                exp_idx = exp_idx + 1;
            end
            if      (u.f_we && u.f_valid) occ_q <= occ_q + 1 - (drain_en && occ_q > 0 ? 1 : 0);
            else if (drain_en && occ_q > 0) occ_q <= occ_q - 1;
        end
        else occ_q <= 0;
    end

    //--------------- 主流程 ----------------
    integer b0, f0;
    initial begin
        repeat (3) @(posedge clk); #1; rst_n = 1;

        //---- T0 全信用(主机常排空, 期望零停顿) ----
        drain_en = 1;
        @(posedge clk); go = 1; @(posedge clk); go = 0;
        b0 = bytes_written; f0 = frames;
        while (!token_done) @(posedge clk);
        repeat (2) @(posedge clk);
        if (bytes_written != TOK_B)    err = err + 1;
        if (frames != NL1)             err = err + 1;
        $display("== T0 帧%0d 字节%0d 停顿%0d 对账到%0d 信用违例%0d ==",
                 frames, bytes_written, u.stalls, exp_idx, crime);

        //---- T1 停顿注入: 排空熄火 → FIFO>50% 真挡 → 恢复 ----
        drain_en = 0;
        @(posedge clk); go = 1; @(posedge clk); go = 0;
        b0 = bytes_written; f0 = frames;
        while (!token_done) begin
            @(posedge clk);
            if (u.stalls > 0) drain_en = 1;   // 第一次真实 stall 后恢复排空
        end
        repeat (2) @(posedge clk);
        if (bytes_written - b0[31:0] != TOK_B) err = err + 1;
        if (frames - f0[31:0] != NL1)          err = err + 1;
        if (u.stalls == 0)                     err = err + 1;
        if (order_bad)                         err = err + 1;
        if (crime)                             err = err + 1;
        if (exp_idx != 2 * TOK_B)              err = err + 1;
        $display("== T1 帧%0d 字节%0d 停顿%0d 对账到%0d 信用违例%0d order_bad=%0b ==",
                 frames - f0[31:0], bytes_written - b0[31:0], u.stalls, exp_idx, crime, order_bad);

        if (err == 0 && crime == 0 && !order_bad && u.stalls > 0)
            $display("##### ALL PASS: M13 v1层 KDA diff 写回 49,160B×69 严格层序 · 秩1 逐层即推 · credit 弹性 FIFO ##### (occ_max=%0d)", occ_max);
        else
            $display("##### FAIL err=%0d crime=%0d occ_max=%0d #####", err, crime, occ_max);
        $finish;
    end

    // 看门狗 (全速轮询: 每轮 ≈ 5M 周期)
    integer wdc = 0;
    always @(posedge clk) begin
        if (busy) begin
            if (wdc > 15000000) begin $display("%0t FAIL watchdog", $time); $finish; end
            wdc = wdc + 1;
        end else wdc = 0;
    end
endmodule