// DDR5 PHY 完整设计 — 兼容 iverilog
// 不依赖高级 SystemVerilog 特性

module ddr5_phy #(
    parameter DQ_WIDTH   = 8,      // 数据宽度
    parameter DQS_WIDTH  = 1,      // DQS 宽度（每字节）
    parameter CA_WIDTH   = 7,      // 命令地址宽度
    parameter CLK_WIDTH  = 2,      // 差分时钟
    parameter NUM_BYTES  = 1,      // 字节数
    parameter AHB_AWIDTH = 32,     // AHB 地址宽度
    parameter AHB_DWIDTH = 32      // AHB 数据宽度
)(
    // 系统接口
    input  wire                     clk,            // 参考时钟（200 MHz）
    input  wire                     rst_n,          // 复位
    
    // DFI 接口（连接内存控制器）
    input  wire                     dfi_clk,        // DFI 时钟
    input  wire                     dfi_rst_n,      // DFI 复位
    
    // DFI 写接口
    input  wire [DQ_WIDTH*8-1:0]   dfi_wrdata,     // 写数据
    input  wire [DQ_WIDTH*8/8-1:0] dfi_wrdata_mask, // 写掩码
    input  wire                     dfi_wrdata_en,  // 写使能
    
    // DFI 读接口
    output wire [DQ_WIDTH*8-1:0]   dfi_rddata,     // 读数据
    output wire                     dfi_rddata_en,  // 读数据使能
    output wire                     dfi_rddata_valid, // 读数据有效
    
    // DFI 控制接口
    output wire                     dfi_freq,       // 频率切换
    output wire                     dfi_init_start, // 初始化开始
    input  wire                     dfi_init_complete, // 初始化完成
    
    // DRAM 接口
    output wire [DQ_WIDTH-1:0]     dram_dq_out,    // 数据输出
    input  wire [DQ_WIDTH-1:0]     dram_dq_in,     // 数据输入
    output wire                     dram_dq_oe,     // 输出使能
    output wire [DQS_WIDTH-1:0]    dram_dqs_out,   // DQS 输出
    input  wire [DQS_WIDTH-1:0]    dram_dqs_in,    // DQS 输入
    output wire                     dram_dqs_oe,    // DQS 输出使能
    output wire                     dram_ck_p,      // 差分时钟正
    output wire                     dram_ck_n,      // 差分时钟负
    output wire [CA_WIDTH-1:0]     dram_ca,        // 命令地址
    output wire                     dram_cke,       // 时钟使能
    output wire                     dram_cs_n,      // 片选
    output wire                     dram_ras_n,     // 行地址选通
    output wire                     dram_cas_n,     // 列地址选通
    output wire                     dram_we_n,      // 写使能
    output wire                     dram_reset_n,   // 复位
    
    // 校准接口
    output wire                     cal_done,       // 校准完成
    input  wire                     cal_start,      // 校准开始
    
    // 状态输出
    output wire [3:0]               phy_state       // PHY 状态
);

    // ========================================
    // 内部信号
    // ========================================
    
    // 时钟信号
    wire                pll_clk_0;
    wire                pll_clk_90;
    wire                pll_clk_180;
    wire                pll_clk_270;
    wire                pll_locked;
    
    // TX 信号
    wire [DQ_WIDTH-1:0] tx_dq;
    wire [DQS_WIDTH-1:0] tx_dqs;
    wire                tx_dq_oe;
    wire                tx_dqs_oe;
    
    // RX 信号
    wire [DQ_WIDTH-1:0] rx_dq;
    wire [DQS_WIDTH-1:0] rx_dqs;
    wire [DQ_WIDTH*8-1:0] rx_dout;
    wire                rx_valid;
    
    // 校准信号
    wire [7:0]          cal_dly;
    wire                cal_dq_oe;
    wire                cal_dqs_oe;
    
    // 状态机
    localparam PHY_IDLE      = 4'h0;
    localparam PHY_INIT      = 4'h1;
    localparam PHY_CAL       = 4'h2;
    localparam PHY_READY     = 4'h3;
    localparam PHY_READ      = 4'h4;
    localparam PHY_WRITE     = 4'h5;
    localparam PHY_REFRESH   = 4'h6;
    localparam PHY_POWERDOWN = 4'h7;
    
    reg [3:0] state, next_state;

    // ========================================
    // DFI 输入同步器（2FF）：dfi_init_complete 来自控制器时钟域，
    // 单周期脉冲可能被 pll_clk_0 采样沿错过（实测复现过卡死）
    // ========================================
    reg init_complete_sync1, init_complete_sync2;
    always @(posedge pll_clk_0 or negedge rst_n) begin
        if (!rst_n) begin
            init_complete_sync1 <= 1'b0;
            init_complete_sync2 <= 1'b0;
        end else begin
            init_complete_sync1 <= dfi_init_complete;
            init_complete_sync2 <= init_complete_sync1;
        end
    end

    // 读状态超时计数：rx_valid 不来时兜底返回 READY，避免死锁
    reg [4:0] rd_timeout;
    always @(posedge pll_clk_0 or negedge rst_n) begin
        if (!rst_n)
            rd_timeout <= 5'd0;
        else if (state == PHY_READ)
            rd_timeout <= rd_timeout + 5'd1;
        else
            rd_timeout <= 5'd0;
    end
    
    // ========================================
    // PLL（需要代工厂替换）
    // ========================================
    pll_stub u_pll (
        .ref_clk(clk),
        .rst_n(rst_n),
        .clk_0(pll_clk_0),
        .clk_90(pll_clk_90),
        .clk_180(pll_clk_180),
        .clk_270(pll_clk_270),
        .locked(pll_locked)
    );
    
    // ========================================
    // TX 通路
    // ========================================
    ddr5_tx #(
        .DQ_WIDTH(DQ_WIDTH),
        .DQS_WIDTH(DQS_WIDTH)
    ) u_tx (
        .clk(pll_clk_0),
        .clk_90(pll_clk_90),
        .rst_n(rst_n & pll_locked),
        .din(dfi_wrdata),
        .mask(dfi_wrdata_mask),
        .valid(dfi_wrdata_en),
        .dq_out(tx_dq),
        .dqs_out(tx_dqs),
        .dq_oe(tx_dq_oe),
        .dqs_oe(tx_dqs_oe)
    );
    
    // ========================================
    // RX 通路
    // ========================================
    ddr5_rx #(
        .DQ_WIDTH(DQ_WIDTH),
        .DQS_WIDTH(DQS_WIDTH)
    ) u_rx (
        .clk(pll_clk_0),
        .clk_90(pll_clk_90),
        .rst_n(rst_n & pll_locked),
        .dq_in(rx_dq),
        .dqs_in(rx_dqs),
        .dout(rx_dout),
        .valid(rx_valid)
    );
    
    // ========================================
    // 校准模块
    // ========================================
    ddr5_calibration #(
        .DQ_WIDTH(DQ_WIDTH)
    ) u_cal (
        .clk(pll_clk_0),
        .rst_n(rst_n & pll_locked),
        .start(cal_start),
        .done(cal_done),
        .dly(cal_dly),
        .dq_oe(cal_dq_oe),
        .dqs_oe(cal_dqs_oe)
    );
    
    // ========================================
    // 时钟输出
    // ========================================
    assign dram_ck_p = pll_clk_0;
    assign dram_ck_n = pll_clk_180;
    
    // ========================================
    // 数据输出控制
    // ========================================
    assign dram_dq_out = tx_dq;
    assign rx_dq = dram_dq_in;
    assign dram_dq_oe = tx_dq_oe | cal_dq_oe;
    
    assign dram_dqs_out = tx_dqs;
    assign rx_dqs = dram_dqs_in;
    assign dram_dqs_oe = tx_dqs_oe | cal_dqs_oe;
    
    // ========================================
    // DFI 接口
    // ========================================
    assign dfi_rddata = rx_dout;
    // 读窗口指示：READ 状态期间有效（此前恒为 1 且被本模块 FSM 读回，
    // 造成 READY→READ 自触发死锁）
    assign dfi_rddata_en = (state == PHY_READ);
    assign dfi_rddata_valid = rx_valid;
    assign dfi_freq = 1'b0;
    assign dfi_init_start = (state == PHY_INIT);
    
    // ========================================
    // DRAM 控制信号
    // ========================================
    assign dram_ca = 0;  // 由控制器驱动
    assign dram_cke = (state != PHY_POWERDOWN);
    assign dram_cs_n = 0;
    assign dram_ras_n = 1;
    assign dram_cas_n = 1;
    assign dram_we_n = 1;
    assign dram_reset_n = rst_n;
    
    // ========================================
    // 状态机
    // ========================================
    always @(posedge pll_clk_0 or negedge rst_n) begin
        if (!rst_n) begin
            state <= PHY_IDLE;
        end else begin
            state <= next_state;
        end
    end
    
    always @(*) begin
        next_state = state;
        case (state)
            PHY_IDLE: begin
                if (cal_start) begin
                    next_state = PHY_INIT;
                end
            end
            
            PHY_INIT: begin
                if (init_complete_sync2) begin
                    next_state = PHY_CAL;
                end
            end
            
            PHY_CAL: begin
                if (cal_done) begin
                    next_state = PHY_READY;
                end
            end
            
            PHY_READY: begin
                if (dfi_wrdata_en) begin
                    next_state = PHY_WRITE;
                end
            end

            PHY_WRITE: begin
                next_state = PHY_READ;
            end

            PHY_READ: begin
                if (dfi_rddata_valid || rd_timeout == 5'd20) begin
                    next_state = PHY_READY;
                end
            end
        endcase
    end
    
    assign phy_state = state;

endmodule
