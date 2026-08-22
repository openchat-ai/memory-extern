// WDDR PHY 适配版测试平台
// 验证基本的 TX/RX 功能

`timescale 1ns/1ps

module wddr_phy_tb;

    // 参数
    parameter NUM_DQ = 8;
    parameter CLK_PERIOD = 10;  // 100 MHz
    
    // 信号
    reg clk;
    reg rst_n;
    reg [NUM_DQ*8-1:0] dfi_wdata;
    reg dfi_wvalid;
    wire [NUM_DQ*8-1:0] dfi_rdata;
    wire dfi_rvalid;
    
    // DRAM 接口
    wire [NUM_DQ-1:0] dq_out;
    reg [NUM_DQ-1:0] dq_in;
    wire dq_oe;
    wire ck_p, ck_n;
    wire [6:0] ca;
    wire cke, cs_n, ras_n, cas_n, we_n;
    
    // 测试数据
    reg [NUM_DQ*8-1:0] test_data;
    integer errors;
    
    // 实例化被测模块
    wddr_phy_generic #(
        .NUM_DQ(NUM_DQ)
    ) u_dut (
        .clk(clk),
        .rst_n(rst_n),
        .dfi_clk(clk),
        .dfi_wdata(dfi_wdata),
        .dfi_rdata(dfi_rdata),
        .dfi_wvalid(dfi_wvalid),
        .dfi_rvalid(dfi_rvalid),
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
        dfi_wdata = 0;
        dfi_wvalid = 0;
        dq_in = 0;
        errors = 0;
        
        // 复位
        #(CLK_PERIOD * 10);
        rst_n = 1;
        #(CLK_PERIOD * 10);
        
        $display("=== WDDR PHY 适配版测试 ===");
        
        // 测试 1：TX 基本功能
        $display("测试 1：TX 基本功能");
        test_data = 64'hA5A5A5A5A5A5A5A5;
        dfi_wdata = test_data;
        dfi_wvalid = 1;
        #(CLK_PERIOD);
        dfi_wvalid = 0;
        
        // 等待移位完成
        #(CLK_PERIOD * 10);
        
        // 检查输出
        if (dq_out !== test_data[0 +: NUM_DQ]) begin
            $display("错误：TX 输出不匹配");
            errors = errors + 1;
        end else begin
            $display("TX 测试通过");
        end
        
        // 测试 2：RX 基本功能
        $display("测试 2：RX 基本功能");
        dq_in = 8'h55;
        #(CLK_PERIOD * 10);
        
        if (dfi_rvalid) begin
            $display("RX 数据接收：%h", dfi_rdata);
        end else begin
            $display("RX 未收到有效数据");
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
        $dumpfile("wddr_phy_tb.vcd");
        $dumpvars(0, wddr_phy_tb);
    end

endmodule
