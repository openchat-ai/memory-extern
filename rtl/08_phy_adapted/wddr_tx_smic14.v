// WDDR TX 通路 — SMIC 14nm 适配版
// 从 Wavious ddr_tx.sv 简化

module wddr_tx_smic14 #(
    parameter NUM_DQ = 8
)(
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire [NUM_DQ*8-1:0]     din,        // 并行输入
    input  wire                     valid,       // 输入有效
    output reg [NUM_DQ-1:0]        dout,       // 串行输出
    output reg                      oe          // 输出使能
);

    // 移位寄存器
    reg [7:0] shift_reg [0:NUM_DQ-1];
    reg [2:0] cnt;
    reg       running;
    
    integer i;
    
    // 状态控制
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < NUM_DQ; i = i + 1) begin
                shift_reg[i] <= 0;
            end
            cnt <= 0;
            running <= 1'b0;
            oe <= 1'b0;
        end else if (valid && !running) begin
            // 加载并行数据
            for (i = 0; i < NUM_DQ; i = i + 1) begin
                shift_reg[i] <= din[i*8 +: 8];
            end
            cnt <= 0;
            running <= 1'b1;
            oe <= 1'b1;
        end else if (running) begin
            // 移位输出
            for (i = 0; i < NUM_DQ; i = i + 1) begin
                dout[i] <= shift_reg[i][7];
                shift_reg[i] <= {shift_reg[i][6:0], 1'b0};
            end
            cnt <= cnt + 1;
            if (cnt == 7) begin
                running <= 1'b0;
                oe <= 1'b0;
            end
        end
    end

endmodule
