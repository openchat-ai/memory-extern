`timescale 1ns/1ps
// tt_wrap_bf16_tb.v — TT wrapper（版本 B, bf16）行为对拍（内部探针版）：
//   直接比对 wrapper 内 periph_mac_bf16 实例的完整 acc 与直连参考，16 位逐位。
module tt_wrap_bf16_tb;
    localparam NGRP = 8;
    reg clk = 0;
    always #5 clk = ~clk;

    reg         rst = 1, go;
    reg  [15:0] q;
    reg  [7:0]  sc;
    wire [15:0] accA;
    wire        doneA;
    periph_mac_bf16 #(.NGRP(NGRP)) uA (.clk(clk), .rst(rst), .go(go), .q(q), .scale(sc), .acc(accA), .done(doneA));

    wire [7:0] uo;
    reg  [7:0] ui = 8'h00;
    tt_um_bf16 uB (.clk(clk), .rst_n(~rst), .ui_in(ui), .uo_out(uo),
                   .uio_in(8'h0), .uio_out(), .uio_oe());
    wire [15:0] accB = uB.acc;

    reg [15:0] qm [0:7];
    reg [7:0]  sm [0:7];
    integer    errs = 0;

    task load_row(input [1:0] w);
        integer k; begin
            for (k = 0; k < 8; k = k + 1) begin qm[k] = 16'h0; sm[k] = 8'hFF; end
            if (w == 1) begin
                for (k = 0; k < 8; k = k + 1) begin
                    qm[k] = (k & 1) ? 16'hBF80 : 16'h3F80;
                    sm[k] = 8'h7F;
                end
            end else if (w == 2) begin
                qm[0] = 16'h4020; sm[0] = 8'h7F;
                qm[1] = 16'hC020; sm[1] = 8'h7F;
                qm[2] = 16'h4000; sm[2] = 8'h78;
                qm[3] = 16'h0010; sm[3] = 8'h78;
                qm[4] = 16'hC000; sm[4] = 8'h7F;
                qm[5] = 16'h4080; sm[5] = 8'h7F;
                qm[6] = 16'h4040; sm[6] = 8'h7F;
                qm[7] = 16'hC040; sm[7] = 8'h7F;
            end
        end
    endtask

    task run_a_and_check(input [1:0] w, input integer exp_zero);
        integer k, cyc;
        reg saw_done;
        begin
            repeat (3) @(posedge clk);
            #1;
            go = 1; q = qm[0]; sc = sm[0];
            @(posedge clk); #1;
            go = 0;
            for (k = 1; k < 8; k = k + 1) begin
                q = qm[k]; sc = sm[k];
                @(posedge clk); #1;
            end
            // B：ui[2:1]=sel(w)，ui[0]=run
            ui = {5'b00000, w[1:0], 1'b1};
            @(posedge clk); #1;
            cyc = 0;
            saw_done = 1'b0;
            while (cyc < 50) begin
                if (uo[4] === 1'b1) saw_done = 1'b1;
                @(posedge clk); #1;
                cyc = cyc + 1;
            end
            ui = 8'h00;
            @(posedge clk); #1;

            if (!saw_done) begin
                $display("FAIL row sel=%0d: B done 未置位 running=%b go=%b row_active=%b g=%0d",
                         w, uB.running, uB.go, uB.row_active, uB.row_g);
                errs = errs + 1;
            end else begin
                if (accB !== accA) begin
                    $display("FAIL row sel=%0d: B acc=%04h A acc=%04h", w, accB, accA);
                    errs = errs + 1;
                end else begin
                    $display("  row sel=%0d: B==A acc=%04h (cyc=%0d)", w, accB, cyc);
                end
                if (exp_zero && accA !== 16'h0) begin
                    $display("FAIL row sel=%0d: acc 应为 +0，得 %04h", w, accA);
                    errs = errs + 1;
                end
            end
            @(posedge clk); #1;
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        rst = 0; #1;
        load_row(0); run_a_and_check(0, 1);
        load_row(1); run_a_and_check(1, 1);
        load_row(2); run_a_and_check(2, 0);
        $display("wrapper bf16: 3 行 错误 %0d", errs);
        if (errs == 0) $display("=== ALL PASS ===");
        else $display("=== %0d ERROR(S) ===", errs);
        $finish;
    end
endmodule