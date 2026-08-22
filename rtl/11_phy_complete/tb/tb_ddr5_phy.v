// DDR5 PHY 测试平台

`timescale 1ps / 1ps

module tb_ddr5_phy;

    // ========================================
    // 参数
    // ========================================
    parameter DQ_WIDTH  = 8;
    parameter DQS_WIDTH = 1;
    parameter CA_WIDTH  = 7;
    parameter CLK_PERIOD = 5000;  // 200 MHz
    
    // ========================================
    // 信号
    // ========================================
    reg                     clk;
    reg                     rst_n;
    
    // DFI 接口
    wire                    dfi_clk;
    reg                     dfi_rst_n;
    reg [DQ_WIDTH*8-1:0]   dfi_wrdata;
    reg [DQ_WIDTH*8/8-1:0] dfi_wrdata_mask;
    reg                     dfi_wrdata_en;
    wire [DQ_WIDTH*8-1:0]  dfi_rddata;
    wire                    dfi_rddata_en;
    wire                    dfi_rddata_valid;
    wire                    dfi_freq;
    wire                    dfi_init_start;
    reg                     dfi_init_complete;
    
    // DRAM 接口
    wire [DQ_WIDTH-1:0]    dram_dq_out;
    wire [DQ_WIDTH-1:0]    dram_dq_in;
    wire                    dram_dq_oe;
    wire [DQS_WIDTH-1:0]   dram_dqs_out;
    wire [DQS_WIDTH-1:0]   dram_dqs_in;
    wire                    dram_dqs_oe;
    wire                    dram_ck_p;
    wire                    dram_ck_n;
    wire [CA_WIDTH-1:0]    dram_ca;
    wire                    dram_cke;
    wire                    dram_cs_n;
    wire                    dram_ras_n;
    wire                    dram_cas_n;
    wire                    dram_we_n;
    wire                    dram_reset_n;
    
    // 校准接口
    wire                    cal_done;
    reg                     cal_start;
    
    // 状态
    wire [3:0]              phy_state;
    
    // ========================================
    // 实例化
    // ========================================
    ddr5_phy #(
        .DQ_WIDTH(DQ_WIDTH),
        .DQS_WIDTH(DQS_WIDTH),
        .CA_WIDTH(CA_WIDTH)
    ) uut (
        .clk(clk),
        .rst_n(rst_n),
        .dfi_clk(dfi_clk),
        .dfi_rst_n(dfi_rst_n),
        .dfi_wrdata(dfi_wrdata),
        .dfi_wrdata_mask(dfi_wrdata_mask),
        .dfi_wrdata_en(dfi_wrdata_en),
        .dfi_rddata(dfi_rddata),
        .dfi_rddata_en(dfi_rddata_en),
        .dfi_rddata_valid(dfi_rddata_valid),
        .dfi_freq(dfi_freq),
        .dfi_init_start(dfi_init_start),
        .dfi_init_complete(dfi_init_complete),
        .dram_dq_out(dram_dq_out),
        .dram_dq_in(dram_dq_in),
        .dram_dq_oe(dram_dq_oe),
        .dram_dqs_out(dram_dqs_out),
        .dram_dqs_in(dram_dqs_in),
        .dram_dqs_oe(dram_dqs_oe),
        .dram_ck_p(dram_ck_p),
        .dram_ck_n(dram_ck_n),
        .dram_ca(dram_ca),
        .dram_cke(dram_cke),
        .dram_cs_n(dram_cs_n),
        .dram_ras_n(dram_ras_n),
        .dram_cas_n(dram_cas_n),
        .dram_we_n(dram_we_n),
        .dram_reset_n(dram_reset_n),
        .cal_done(cal_done),
        .cal_start(cal_start),
        .phy_state(phy_state)
    );
    
    // ========================================
    // DRAM 环回模型：OE 有效时输出回环到输入
    // ========================================
    assign dram_dq_in  = dram_dq_oe  ? dram_dq_out  : {DQ_WIDTH{1'bz}};
    assign dram_dqs_in = dram_dqs_oe ? dram_dqs_out : {DQS_WIDTH{1'bz}};

    // ========================================
    // 时钟生成
    // ========================================
    initial begin
        clk = 0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end
    
    assign dfi_clk = clk;
    
    // ========================================
    // 测试序列
    // ========================================
    initial begin
        // 初始化
        rst_n = 0;
        dfi_rst_n = 0;
        dfi_wrdata = 0;
        dfi_wrdata_mask = 0;
        dfi_wrdata_en = 0;
        dfi_init_complete = 0;
        cal_start = 0;
        
        // 复位释放
        #(CLK_PERIOD * 10);
        rst_n = 1;
        dfi_rst_n = 1;
        
        // 等待 PLL 锁定
        #(CLK_PERIOD * 300);
        
        $display("=== DDR5 PHY Test ===");
        $display("Time=%0t: PHY state = %h", $time, phy_state);
        
        // 开始校准
        cal_start = 1;
        #(CLK_PERIOD);
        cal_start = 0;
        
        // 模拟初始化完成（DFI 协议中为电平握手：
        // 控制器拉高并保持，直到 PHY 进入校准态才撤下）
        #(CLK_PERIOD * 100);
        dfi_init_complete = 1;
        wait (phy_state == 4'h2);  // PHY_CAL
        dfi_init_complete = 0;
        
        // 等待校准完成
        wait(cal_done);
        $display("Time=%0t: Calibration done", $time);
        
        // 写操作测试
        #(CLK_PERIOD * 10);
        dfi_wrdata = 8'hA5;  // 测试数据
        dfi_wrdata_mask = 0;
        dfi_wrdata_en = 1;
        #(CLK_PERIOD);
        dfi_wrdata_en = 0;

        // 等待写→读→READY 全流程
        #(CLK_PERIOD * 100);

        $display("Time=%0t: PHY state = %h", $time, phy_state);
        if (phy_state == 4'h3)
            $display("PASS: FSM reached READY (write->read->ready)");
        else
            $display("FAIL: FSM stuck at state %h", phy_state);
        $display("=== Test Complete ===");
        $finish;
    end
    
    // ========================================
    // 波形输出
    // ========================================
    initial begin
        $dumpfile("ddr5_phy.vcd");
        $dumpvars(0, tb_ddr5_phy);
    end

endmodule
