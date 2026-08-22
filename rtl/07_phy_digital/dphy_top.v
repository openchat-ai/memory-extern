// 数字 PHY 顶层模块
// 功能：集成 TX/RX 通路和时钟管理
// 应用：LPDDR5X 接口（简化版）

module dphy_top #(
    parameter DQ_WIDTH = 8,         // 数据宽度
    parameter CA_WIDTH = 7,         // 命令地址宽度
    parameter PHASES = 8            // 时钟相位数
)(
    // 系统接口
    input  wire                     clk,        // 系统时钟
    input  wire                     rst_n,      // 复位
    
    // 控制器接口（来自内存控制器）
    input  wire [DQ_WIDTH-1:0]      tx_din,     // 发送数据
    input  wire                     tx_valid,   // 发送有效
    output wire                     tx_ready,   // 发送就绪
    
    output wire [DQ_WIDTH-1:0]      rx_dout,    // 接收数据
    output wire                     rx_valid,   // 接收有效
    
    // DRAM 接口（连接到引脚，再到 foundry I/O cell）
    output wire [DQ_WIDTH-1:0]      dq_out,     // 数据输出
    input  wire [DQ_WIDTH-1:0]      dq_in,      // 数据输入
    output wire                     dq_oe,      // 输出使能
    output wire                     ck_p,       // 差分时钟正
    output wire                     ck_n,       // 差分时钟负
    output wire [CA_WIDTH-1:0]      ca,         // 命令地址
    output wire                     cke,        // 时钟使能
    output wire                     cs_n,       // 片选
    output wire                     ras_n,      // 行地址选通
    output wire                     cas_n,      // 列地址选通
    output wire                     we_n        // 写使能
);

    // 内部信号
    wire [PHASES-1:0]   dll_clk;
    wire                dll_locked;
    wire [DQ_WIDTH-1:0] tx_serial;
    wire [DQ_WIDTH-1:0] rx_parallel;
    
    // 时钟生成
    dll #(
        .PHASES(PHASES)
    ) u_dll (
        .clk_in(clk),
        .rst_n(rst_n),
        .enable(1'b1),
        .clk_out(dll_clk),
        .locked(dll_locked)
    );
    
    // 差分时钟生成（简化：用相位0和相位4）
    assign ck_p = dll_clk[0];
    assign ck_n = dll_clk[PHASES/2];
    
    // TX 通路：每个数据位一个 PISO
    // 注意：这里简化了，每个 PISO 处理 1 bit 的 8 个周期
    // 实际设计中应该是每个 PISO 处理 8 bit 数据
    genvar i;
    generate
        for (i = 0; i < DQ_WIDTH; i = i + 1) begin : tx_piso
            piso #(
                .WIDTH(1)  // 简化：每个 PISO 只处理 1 bit
            ) u_piso (
                .clk(dll_clk[0]),
                .rst_n(rst_n),
                .load(tx_valid),
                .din(tx_din[i]),
                .dout(tx_serial[i]),
                .ready()
            );
        end
    endgenerate
    
    // RX 通路：每个数据位一个 SIPO
    generate
        for (i = 0; i < DQ_WIDTH; i = i + 1) begin : rx_sipo
            sipo #(
                .WIDTH(1)  // 简化：每个 SIPO 只处理 1 bit
            ) u_sipo (
                .clk(dll_clk[0]),
                .rst_n(rst_n),
                .din(dq_in[i]),
                .bit_clk(dll_clk[1]),
                .dout(rx_parallel[i]),
                .valid(rx_valid)
            );
        end
    endgenerate
    
    // 输出赋值
    assign dq_out = tx_serial;
    assign dq_oe = tx_valid;
    assign rx_dout = rx_parallel;
    assign tx_ready = dll_locked;
    
    // 命令地址直接输出（简化）
    assign ca = 0;  // 由控制器驱动
    assign cke = 1;
    assign cs_n = 0;
    assign ras_n = 1;
    assign cas_n = 1;
    assign we_n = 1;

endmodule
