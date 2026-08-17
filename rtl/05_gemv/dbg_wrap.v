`timescale 1ns/1ps
module dbg_wrap_tb;
    reg clk=0; always #5 clk=~clk;
    reg rst=1, run=0;
    reg [7:0] ui_in=0, uio_in=0;
    wire [7:0] uo_out, uio_out, uio_oe;
    tt_um_periph_mac u (.clk(clk), .rst_n(~rst), .ui_in(ui_in), .uo_out(uo_out),
        .uio_in(uio_in), .uio_out(uio_out), .uio_oe(uio_oe));
    initial begin
        repeat(3) @(posedge clk);
        rst=0;
        repeat(2) @(posedge clk);
        ui_in = 8'b00000101;   // sel=10(row2), run=1
        repeat(12) begin
            @(posedge clk);
            $display("t=%0t g=%0d go=%b running=%b done=%b accB=%08h qb=%08h sc=%02h",
                     $time, u.row_g, u.go, u.running, u.done, u.acc, u.q_t, u.sc_t);
        end
        $finish;
    end
endmodule
