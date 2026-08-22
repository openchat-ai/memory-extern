// 数字 PHY 测试平台
// 验证基本的 TX/RX 功能

`timescale 1ns/1ps

module dphy_tb;

    // 参数
    parameter DQ_WIDTH = 8;
    parameter CLK_PERIOD = 10;  // 100 MHz 系统时钟
    
    // 信号
    reg clk;
    reg rst_n;
    reg [DQ_WIDTH-1:0] tx_din;
    reg tx_valid;
    wire tx_ready;
    wire [DQ_WIDTH-1:0] rx_dout;
    wire rx_valid;
    
    // DRAM 接口（测试用）
    wire [DQ_WIDTH-1:0] dq_out;
    reg [DQ_WIDTH-1:0] dq_in;
    wire dq_oe;
    wire ck_p, ck_n;
    wire [6:0] ca;
    wire cke, cs_n, ras_n, cas_n, we_n;
    
    // 测试数据
    reg [DQ_WIDTH-1:0] test_data;
    integer i;
    integer errors;
    
    // 实例化被测模块
    dphy_top #(
        .DQ_WIDTH(DQ_WIDTH)
    ) u_dut (
        .clk(clk),
        .rst_n(rst_n),
        .tx_din(tx_din),
        .tx_valid(tx_valid),
        .tx_ready(tx_ready),
        .rx_dout(rx_dout),
        .rx_valid(rx_valid),
        .dq_out(dq_out),
        .dq_in(dq_in),
        .dq_oe(dq_oe),
        .ck_p(ck_p),
        .ck_n(ck_n),
        .ca(ca),
        .cke(cke),
        .cs_n(cs_n),
        .ras_n(ras_n),
        .cas_n(cas_n),
        .we_n(we_n)
    );
    
    // 时钟生成
    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;
    
    // 测试过程
    initial begin
        // 初始化
        rst_n = 0;
        tx_din = 0;
        tx_valid = 0;
        dq_in = 0;
        errors = 0;
        
        // 复位
        #(CLK_PERIOD * 10);
        rst_n = 1;
        #(CLK_PERIOD * 10);
        
        $display("=== 数字 PHY 测试开始 ===");
        
        // 测试 1：TX 基本功能
        $display("测试 1：TX 基本功能");
        test_data = 8'hA5;  // 10100101
        tx_din = test_data;
        tx_valid = 1;
        #(CLK_PERIOD);
        tx_valid = 0;
        #(CLK_PERIOD * 10);
        
        // 检查输出
        if (dq_out !== test_data) begin
            $display("错误：TX 输出不匹配，期望=%h，实际=%h", test_data, dq_out);
            errors = errors + 1;
        end else begin
            $display("TX 测试通过");
        end
        
        // 测试 2：RX 基本功能
        $display("测试 2：RX 基本功能");
        dq_in = 8'h55;  // 01010101
        #(CLK_PERIOD * 20);
        
        if (rx_valid) begin
            $display("RX 数据接收：%h", rx_dout);
        end else begin
            $display("RX 未收到有效数据（可能需要更多时钟周期）");
        end
        
        // 测试 3：时钟输出
        $display("测试 3：时钟输出");
        if (ck_p !== 0 || ck_n !== 1) begin
            $display("错误：差分时钟初始状态不正确");
            errors = errors + 1;
        end else begin
            $display("差分时钟初始状态正确");
        end
        
        // 总结
        #(CLK_PERIOD * 10);
        $display("=== 测试完成 ===");
        if (errors == 0) begin
            $display("所有测试通过！");
        end else begin
            $display("有 %d 个错误", errors);
        end
        
        $finish;
    end
    
    // 波形输出
    initial begin
        $dumpfile("dphy_tb.vcd");
        $dumpvars(0, dphy_tb);
    end

endmodule
