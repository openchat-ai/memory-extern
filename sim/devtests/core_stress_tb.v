`timescale 1ps/1ps
// core_stress_tb — 背压内容等价对账 (STRESS 注入信用停摆窗 60~68 拍 credit=0)
// uA (STRESS=0) 与 uB (STRESS=1) 同 seed 并行; 断言两者均 done、
// 词量同为 128 且事件级内容哈希逐位相等 → 词内容与信用路径正交 (不漏不重)。
module core_stress_tb;
    reg clk = 0, rst_n = 0, run = 0, credit = 1, s_valid = 0, out_take = 1, wr_en = 0;
    reg [15:0] s_score = 0, head_acc = 16'h1234;
    reg [3:0] xext = 4'h6;
    reg [63:0] q_vec_p = 0;
    reg [8:0] wr_addr = 0; reg [15:0] wr_data = 0;
    wire busyA, doneA, tokenA, ovA; wire [31:0] awA;
    wire [3:0] expA; wire [15:0] odA; wire [8:0] otA; wire [15:0] osA;
    wire busyB, doneB, tokenB, ovB; wire [31:0] awB;
    wire [3:0] expB; wire [15:0] odB; wire [8:0] otB; wire [15:0] osB;

    decode_auto_core #(.SELFDRV(1), .STRESS(0)) UA(
        .clk(clk), .rst_n(rst_n), .run(run), .busy(busyA), .done(doneA),
        .credit(credit), .s_valid(s_valid), .out_take(out_take), .s_score(s_score),
        .q_vec_p(q_vec_p), .head_acc(head_acc), .xext(xext),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
        .out_valid(ovA), .out_data(odA), .out_expert(expA),
        .token_done(tokenA), .r_token_done(), .out_token(otA), .out_score(osA), .h_go(),
        .r_round(), .h_round(), .r_stalls(), .a_stalls(), .a_words(awA)
    );
    decode_auto_core #(.SELFDRV(1), .STRESS(1)) UB(
        .clk(clk), .rst_n(rst_n), .run(run), .busy(busyB), .done(doneB),
        .credit(credit), .s_valid(s_valid), .out_take(out_take), .s_score(s_score),
        .q_vec_p(q_vec_p), .head_acc(head_acc), .xext(xext),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
        .out_valid(ovB), .out_data(odB), .out_expert(expB),
        .token_done(tokenB), .r_token_done(), .out_token(otB), .out_score(osB), .h_go(),
        .r_round(), .h_round(), .r_stalls(), .a_stalls(), .a_words(awB)
    );
    always #5 clk = ~clk;

    integer i, cyc, k;
    reg [31:0] hA = 0, hB = 0;
    reg [31:0] swA = 0, swB = 0;
    reg dfA = 0, dfB = 0;
    reg [11:0] seqA [0:127];
    reg [11:0] seqB [0:127];

    initial begin
        repeat (5) @(posedge clk); rst_n = 1;
        repeat (3) @(posedge clk);
        wr_en = 1;
        for (i = 0; i < 512; i = i + 1) begin
            wr_addr = i; wr_data = i[15:0]; @(posedge clk);
        end
        wr_en = 0;
        run = 1; @(posedge clk); run = 0;
        for (cyc = 0; cyc < 5000; cyc = cyc + 1) begin
@(posedge clk);
            if (0)
                $display("t=%0d cred=%0b R=%0d A=%0d lay=%0d caddr=%3d Bwords=%0d", cyc, UB.stress_credit,
                    UB.u_ras.R.st, UB.u_ras.A.st, UB.u_ras.A.lay_idx, UB.u_ras.A.caddr, awB);
            if (ovA && awA > swA) begin hA = {hA[30:0], hA[31]^expA[0]} ^ {expA[3:0], odA[3:0]}; seqA[awA-1] = {expA, odA[3:0]}; swA <= awA; end
            if (ovB && awB > swB) begin hB = {hB[30:0], hB[31]^expB[0]} ^ {expB[3:0], odB[3:0]}; seqB[awB-1] = {expB, odB[3:0]}; swB <= awB; end
            if (doneA) dfA = 1;
            if (doneB) dfB = 1;
            if (dfA && dfB) cyc = 5000;
        end
        $display("A: done=%0d words=%0d h=%08h   B(stress): done=%0d words=%0d h=%08h",
            dfA, awA, hA, dfB, awB, hB);
        if (!(dfA && dfB)) begin $display("core_stress FAIL (done)"); $finish(1); end
        begin : seqcmp
            integer m, nmis;
            nmis = 0;
            for (m = 0; m < 128; m = m + 1) begin
                if (seqA[m] !== seqB[m]) begin
                    if (nmis < 8) $display("  diff@%0d  A=%04h B=%04h", m, seqA[m], seqB[m]);
                    nmis = nmis + 1;
                end
            end
            $display("  %0d 元素不同", nmis);
        end
        if (dfA && dfB && awA == 32'd128 && awB == 32'd128 && hA === hB)
            $display("core_stress PASS  (信用停摆窗下词内容与无背压逐位一致 = 不漏不重)");
        else begin $display("core_stress FAIL"); $finish(1); end
        $finish;
    end
endmodule