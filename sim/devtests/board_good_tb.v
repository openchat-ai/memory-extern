`timescale 1ps/1ps
// board_good_tb — board_decode_top 帧指纹自动判定验证
// 断言: 稳定自驱闭环 → ≤20000 拍内 led[3](GOOD=≥2连续同指纹) 恒 1。
module board_good_tb;
    reg clk = 0, rst_n = 0;
    wire [5:0] led;
    board_decode_top U(.sys_clk(clk), .rst_n(rst_n), .led(led));
    always #5 clk = ~clk;
    integer cyc;
    reg donef = 0;
    reg tfb = 0;
    initial begin
        repeat (5) @(posedge clk); rst_n = 1;
        cyc = 0;
        while (cyc < 20000) begin
            @(posedge clk); cyc = cyc + 1;
            if (U.token_done) $display("  token@%0d aw=%0d hsh=%08h good=%0d", cyc, U.a_words, U.hsh, U.good);
            if (U.done_ir && !df) begin $display("  done@%0d", cyc); df = 1; end
            if (!led[3] && !donef) begin donef = 1; goodcyc = cyc; end   // 共阳: 0 = 亮 = GOOD
        end
        // 2026-10-21: 板级验收 = 解码 GOOD(led3) + 引擎两盏 PASS 灯(led4/led5)
        //   本板 LED 共阳 (逻辑 0 才点亮) → 条件成立 = 驱动 0 = TB 里读作 0
        //   led3=0 → good[1]=1 → 连续两帧同指纹 (解码 GOOD)
        //   led4=0 → attn 段出非零内积 (窗+读回+内积分块+乘累加链全活)
        //   led5=0 → 引擎爬满 4 层 (SELFREL 自释放; 每层含 GEMM 段 → rail 在网表里)
        if (donef) $display("board_good GOOD(led3)@%0d", goodcyc);
        if (donef && !led[3] && !led[4] && !led[5])
            $display("board_good PASS  led=%0b (led3 GOOD + led4 attn + led5 4层)", led);
        else begin
            $display("board_good FAIL  led=%0b (need led3=led4=led5=0, 共阳低亮)", led);
            $finish(1);
        end
        #40 $finish;
    end
    reg df = 0;
    integer goodcyc = 0;
endmodule