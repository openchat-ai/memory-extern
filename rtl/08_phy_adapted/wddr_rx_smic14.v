// WDDR RX 通路 — SMIC 14nm 适配版
// 从 Wavious ddr_rx.sv 简化

module wddr_rx_smic14 #(
    parameter NUM_DQ = 8
)(
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire [NUM_DQ-1:0]       din,        // 串行输入
    output reg [NUM_DQ*8-1:0]      dout,       // 并行输出
    output reg                      valid       // 输出有效
);

    // 移位寄存器
    reg [7:0] shift_reg [0:NUM_DQ-1];
    reg [2:0] cnt;
    
    integer i;
    
    // 移位采样
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < NUM_DQ; i = i + 1) begin
                shift_reg[i] <= 0;
            end
            cnt <= 0;
            valid <= 1'b0;
        end else begin
            // 移位采样
            for (i = 0; i < NUM_DQ; i = i + 1) begin
                shift_reg[i] <= {shift_reg[i][6:0], din[i]};
            end
            cnt <= cnt + 1;
            
            // 输出有效
            if (cnt == 7) begin
                for (i = 0; i < NUM_DQ; i = i + 1) begin
                    dout[i*8 +: 8] <= {shift_reg[i][6:0], din[i]};
                end
                valid <= 1'b1;
                cnt <= 0;
            end else begin
                valid <= 1'b0;
            end
        end
    end

endmodule
