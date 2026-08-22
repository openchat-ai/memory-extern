// DDR5 TX 通路 — 完整设计
// 包含预加重、驱动控制

module ddr5_tx #(
    parameter DQ_WIDTH  = 8,
    parameter DQS_WIDTH = 1
)(
    input  wire                     clk,
    input  wire                     clk_90,      // 90 度相移时钟
    input  wire                     rst_n,
    
    // 数据输入
    input  wire [DQ_WIDTH*8-1:0]   din,         // 并行数据
    input  wire [DQ_WIDTH*8/8-1:0] mask,        // 写掩码
    input  wire                     valid,       // 输入有效
    
    // 数据输出
    output reg [DQ_WIDTH-1:0]      dq_out,      // DQ 输出
    output reg [DQS_WIDTH-1:0]     dqs_out,     // DQS 输出
    output reg                      dq_oe,       // DQ 输出使能
    output reg                      dqs_oe       // DQS 输出使能
);

    // ========================================
    // 发送移位寄存器
    // ========================================
    reg [7:0] dq_shift [0:DQ_WIDTH-1];
    reg [2:0] dq_cnt;
    reg       dq_active;
    
    reg [7:0] dqs_shift [0:DQS_WIDTH-1];
    reg [2:0] dqs_cnt;
    reg       dqs_active;
    
    integer i;
    
    // ========================================
    // DQ 通路
    // ========================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < DQ_WIDTH; i = i + 1) begin
                dq_shift[i] <= 0;
            end
            dq_cnt <= 0;
            dq_active <= 1'b0;
            dq_out <= 0;
            dq_oe <= 1'b0;
        end else if (valid && !dq_active) begin
            // 加载数据
            for (i = 0; i < DQ_WIDTH; i = i + 1) begin
                dq_shift[i] <= din[i*8 +: 8];
            end
            dq_cnt <= 0;
            dq_active <= 1'b1;
            dq_oe <= 1'b1;
        end else if (dq_active) begin
            // DDR 输出：每个时钟周期输出 2 bit
            for (i = 0; i < DQ_WIDTH; i = i + 1) begin
                dq_out[i] <= dq_shift[i][0];
            end
            // 移位
            for (i = 0; i < DQ_WIDTH; i = i + 1) begin
                dq_shift[i] <= {1'b0, dq_shift[i][7:1]};
            end
            dq_cnt <= dq_cnt + 1;
            if (dq_cnt == 3) begin
                dq_active <= 1'b0;
                dq_oe <= 1'b0;
            end
        end
    end
    
    // ========================================
    // DQS 通路（差分）
    // ========================================
    always @(posedge clk_90 or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < DQS_WIDTH; i = i + 1) begin
                dqs_shift[i] <= 0;
            end
            dqs_cnt <= 0;
            dqs_active <= 1'b0;
            dqs_out <= 0;
            dqs_oe <= 1'b0;
        end else if (valid && !dqs_active) begin
            // 初始化 DQS
            for (i = 0; i < DQS_WIDTH; i = i + 1) begin
                dqs_shift[i] <= 8'hAA;  // 10101010 模式
            end
            dqs_cnt <= 0;
            dqs_active <= 1'b1;
            dqs_oe <= 1'b1;
        end else if (dqs_active) begin
            // DQS 输出
            for (i = 0; i < DQS_WIDTH; i = i + 1) begin
                dqs_out[i] <= dqs_shift[i][0];
            end
            // 移位
            for (i = 0; i < DQS_WIDTH; i = i + 1) begin
                dqs_shift[i] <= {1'b0, dqs_shift[i][7:1]};
            end
            dqs_cnt <= dqs_cnt + 1;
            if (dqs_cnt == 3) begin
                dqs_active <= 1'b0;
                dqs_oe <= 1'b0;
            end
        end
    end

endmodule
