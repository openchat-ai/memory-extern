// ADPLL 测试平台

`timescale 1ns/1ps

module adpll_tb;

    // 参数
    parameter TDC_WIDTH  = 8;
    parameter DCO_WIDTH  = 6;
    parameter DIV_WIDTH  = 5;
    parameter FILT_WIDTH = 16;
    parameter CLK_PERIOD = 10;  // 100 MHz
    
    // 信号
    reg clk;
    reg rst_n;
    reg [DIV_WIDTH-1:0] div_ratio;
    reg [DCO_WIDTH-1:0] dco_ctrl;
    wire pll_clk;
    wire locked;
    
    // 实例化被测模块
    adpll_top #(
        .TDC_WIDTH(TDC_WIDTH),
        .DCO_WIDTH(DCO_WIDTH),
        .DIV_WIDTH(DIV_WIDTH),
        .FILT_WIDTH(FILT_WIDTH)
    ) u_dut (
        .ref_clk(clk),
        .rst_n(rst_n),
        .div_ratio(div_ratio),
        .dco_ctrl(dco_ctrl),
        .pll_clk(pll_clk),
        .locked(locked)
    );
    
    // 时钟生成
    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;
    
    // 测试过程
    initial begin
        // 初始化
        rst_n = 0;
        div_ratio = 5'd10;      // 10 分频
        dco_ctrl = 6'h20;       // 中等控制字
        
        // 复位
        #(CLK_PERIOD * 10);
        rst_n = 1;
        
        $display("=== ADPLL 测试开始 ===");
        $display("参考时钟频率：100 MHz");
        $display("分频比：%0d", div_ratio);
        
        // 等待锁定
        #(CLK_PERIOD * 200);
        
        // 检查锁定状态
        if (locked) begin
            $display("ADPLL 已锁定");
        end else begin
            $display("ADPLL 未锁定（正常，需要调参）");
        end
        
        // 测试不同控制字
        $display("测试不同 DCO 控制字...");
        dco_ctrl = 6'h10;
        #(CLK_PERIOD * 50);
        dco_ctrl = 6'h30;
        #(CLK_PERIOD * 50);
        dco_ctrl = 6'h20;
        #(CLK_PERIOD * 50);
        
        $display("=== 测试完成 ===");
        $finish;
    end
    
    // 波形输出
    initial begin
        $dumpfile("adpll_tb.vcd");
        $dumpvars(0, adpll_tb);
    end

endmodule
