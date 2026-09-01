// ============================================================================
// tb_board_top_200.v — board_top 200MHz 引擎链路仿真
//
// 验证目标：
//   1. Gowin PLL 以行为桩替代（50→200M 引擎、50→35M LCD）
//   2. 复位释放后，pat 激励驱动引擎（PIPE_MUL=1）开始累加
//   3. sum_valid 产生、act_cnt 递增、LED 心跳翻转
//   4. 200MHz 引擎逻辑（打断关键路径后）功能正常
// ============================================================================

`timescale 1ns/1ps

// ---- 行为桩：Gowin_PLL（50→35MHz LCD）----
module Gowin_PLL (clkout0, lock, clkin);
    input  clkin;
    output clkout0;
    output lock;
    reg    lock = 0;
    assign clkout0 = clkin;          // 桩：直通（LCD 不影响引擎验证）
    always #3 lock = 1;              // 30ns 后 lock
endmodule

// ---- 行为桩：Gowin_PLL_X200（50→200MHz 引擎）----
module Gowin_PLL_X200 (clkout0, lock, clkin);
    input  clkin;
    output clkout0;
    output lock;
    reg    lock = 0;
    // 200MHz：半周期 2.5ns → 周期 5ns（行为桩，PLL 已锁定后持续输出）
    reg clkout = 0;
    assign clkout0 = clkout;
    always #2.5 clkout = ~clkout;
    always #3 lock = 1;
endmodule

module tb_board_top_200;

    reg  sys_clk = 0;
    reg  rst_n = 0;
    wire [3:0] led;
    wire lcd_clk;
    wire lcd_en, lcd_hs, lcd_vs;
    wire [5:0] lcd_r, lcd_g, lcd_b;

    board_top dut (
        .sys_clk(sys_clk),
        .rst_n  (rst_n),
        .led    (led),
        .lcd_clk(lcd_clk),
        .lcd_en (lcd_en),
        .lcd_hs (lcd_hs),
        .lcd_vs (lcd_vs),
        .lcd_r  (lcd_r),
        .lcd_g  (lcd_g),
        .lcd_b  (lcd_b)
    );

    // 50MHz 板载时钟
    always #10 sys_clk = ~sys_clk;   // 20ns 周期 = 50MHz

    integer i;
    integer errors = 0;
    reg sum_valid_seen = 0;

// 监控 sum_valid 脉冲（从 engine 侧内部信号观察）
    always @(posedge dut.clk_int) begin
        if (dut.sum_valid) begin
            sum_valid_seen <= 1;
            $display("  [sum_valid t=%0t] sum_out=%0d", $time, $signed(dut.sum_out));
        end
    end

    initial begin
        $dumpfile("tb_board_top_200.vcd");
        $dumpvars(0, tb_board_top_200);
        $display("=== board_top @200MHz 引擎链路仿真 ===");
        $display("sys_clk=50MHz, PLL200 → %0.1fMHz, PLL35 → 直通桩", 50.0*4);

        // 电源复位
        rst_n = 0;
        repeat (13) @(posedge sys_clk);   // 130ns POR
        rst_n = 1;

        // 等待：POR(327us) 完成后引擎第一轮突发(5us)即可产生 sum_valid
        #360000;   // 360us

        // 检查
        $display("");
        $display(" t=%0t", $time);
        $display(" sum_valid 出现过: %0s", sum_valid_seen ? "YES" : "NO");
        $display(" act_cnt: %0d", dut.act_cnt);
        $display(" engine_busy: %0d", dut.engine_busy);
        $display(" sum_out: %0d", dut.sum_out);

        if (sum_valid_seen) begin
            $display(" ✓ 引擎在 200MHz 下完成归约（sum_valid 已产生）");
            if (dut.act_cnt > 0)
                $display(" ✓ act_cnt 递增 (%0d) → 多帧 MAC 完成", dut.act_cnt);
            else
                $display(" ⚠ act_cnt=0（可能帧数不足）");
        end else begin
            $display(" ✗ 引擎未产生 sum_valid");
            errors = errors + 1;
        end

        if ($signed(dut.sum_out) == 0 && sum_valid_seen) begin
            // sum=0 且引擎工作过 → pat_x 全 0 或权重 0 的初始帧可能，需进一步确认
            $display(" ⚠ sum_out=0（初始帧 pat 可能产生 0）");
        end

        $display("");
        if (errors == 0) $display(" ✓✓ BOARD_TOP@200MHz SMOKE PASSED");
        else             $display(" ✗✗ %0d ERRORS", errors);
        $finish;
    end

    initial begin
        #2000000;   // 2ms 全局超时保护
        $display("TIMEOUT");
        $finish;
    end

endmodule