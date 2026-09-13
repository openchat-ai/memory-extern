`timescale 1ps/1ps
// board_smoke_self_tb — 冒烟核自标定: 独立 LFSR 复算 8 拍流水乘加黄金值,
// 与 top 内部 acc_o 对账; PASS 时打印 GOLD, 并把 led[1] 判定期望固填 RTL。
module board_smoke_self_tb;
    reg clk = 0, rst_n = 0;
    wire [3:0] led;
    wire [31:0] acc_o;
    wire done_o;
    board_smoke_top U(.clk(clk), .rst_n(rst_n), .led(led), .acc_o(acc_o), .done_o(done_o));
    always #5 clk = ~clk;

    reg [31:0] slfsr; reg [31:0] pacc; integer i; reg [31:0] gold; reg [15:0] sp, sw, sa;

    initial begin
        slfsr = 32'hCAFE_BEEF; pacc = 0; gold = 0;
        slfsr = 32'hCAFE_BEEF;
        for (i = 0; i < 7; i = i + 1) begin
            sw = slfsr[31:16]; sa = slfsr[15:0];
            gold = gold + sw * sa;
            slfsr = {slfsr[30:0], slfsr[31] ^ slfsr[21] ^ slfsr[1] ^ slfsr[0]};
        end
        repeat (25) @(posedge clk); rst_n = 1;
        for (i = 0; i < 16; i = i + 1) begin
            @(posedge clk);
            $display("t=%0d acc_o=%08h done=%b led=%b", i, acc_o, done_o, led);
        end
        if (done_o && acc_o === gold) begin
            $display("SMOKE 自检 PASS  acc=%08h  GOLD=%08h  (led=%b)", acc_o, gold, led);
            $display("SMOKE_GOLD 0x%08h", gold);
        end else begin
            $display("SMOKE MISMATCH acc=%08h gold=%08h done=%b", acc_o, gold, done_o);
            $finish(1);
        end
        $finish;
    end
endmodule
`default_nettype wire