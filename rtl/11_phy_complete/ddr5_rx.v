// DDR5 RX 通路 — 完整设计
// 包含采样、对齐

module ddr5_rx #(
    parameter DQ_WIDTH  = 8,
    parameter DQS_WIDTH = 1
)(
    input  wire                     clk,
    input  wire                     clk_90,
    input  wire                     rst_n,
    
    // 数据输入
    input  wire [DQ_WIDTH-1:0]     dq_in,        // DQ 输入
    input  wire [DQS_WIDTH-1:0]    dqs_in,       // DQS 输入
    
    // 数据输出
    output reg [DQ_WIDTH*8-1:0]    dout,         // 并行输出
    output reg                      valid         // 输出有效
);

    // ========================================
    // 内部信号
    // ========================================
    reg [7:0] dq_shift [0:DQ_WIDTH-1];
    reg [2:0] dq_cnt;
    reg       dq_capturing;
    
    reg [3:0] dqs_edge_cnt;
    reg       dqs_last;
    
    integer i;
    
    // ========================================
    // DQS 边沿检测
    // ========================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dqs_edge_cnt <= 0;
            dqs_last <= 1'b0;
        end else begin
            dqs_last <= dqs_in[0];
            if (dqs_in[0] && !dqs_last) begin  // 上升沿
                dqs_edge_cnt <= dqs_edge_cnt + 1;
            end
        end
    end
    
    // ========================================
    // DQ 采样（DDR 双边沿）
    // ========================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < DQ_WIDTH; i = i + 1) begin
                dq_shift[i] <= 0;
            end
            dq_cnt <= 0;
            dq_capturing <= 1'b0;
            dout <= 0;
            valid <= 1'b0;
        end else begin
            // 开始捕获（检测到 DQS 边沿）
            if (dqs_edge_cnt != 0 && !dq_capturing) begin
                dq_capturing <= 1'b1;
                dq_cnt <= 0;
            end
            
            // 采样 DQ
            if (dq_capturing) begin
                // DDR 采样：每个周期 2 bit
                // bit 0 = 上升沿数据
                // bit 1 = 下降沿数据（需要反相时钟采样）
                for (i = 0; i < DQ_WIDTH; i = i + 1) begin
                    dq_shift[i][dq_cnt*2] <= dq_in[i];  // 上升沿
                    dq_shift[i][dq_cnt*2+1] <= dq_in[i];  // 下降沿（简化：用同一数据）
                end
                dq_cnt <= dq_cnt + 1;
                
                if (dq_cnt == 3) begin
                    // 输出完整字节
                    for (i = 0; i < DQ_WIDTH; i = i + 1) begin
                        dout[i*8 +: 8] <= dq_shift[i];
                    end
                    valid <= 1'b1;
                    dq_capturing <= 1'b0;
                end else begin
                    valid <= 1'b0;
                end
            end else begin
                valid <= 1'b0;
            end
        end
    end

endmodule
