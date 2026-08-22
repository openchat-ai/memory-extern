// WDDR RX 通路 — 通用版
// 不依赖特定代工厂，纯数字逻辑

module wddr_rx_generic #(
    parameter NUM_DQ = 8
)(
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire [NUM_DQ-1:0]       din,
    output reg [NUM_DQ*8-1:0]      dout,
    output reg                      valid
);

    reg [7:0] shift_reg [0:NUM_DQ-1];
    reg [2:0] cnt;
    
    integer i;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < NUM_DQ; i = i + 1) begin
                shift_reg[i] <= 0;
            end
            cnt <= 0;
            valid <= 1'b0;
        end else begin
            for (i = 0; i < NUM_DQ; i = i + 1) begin
                shift_reg[i] <= {shift_reg[i][6:0], din[i]};
            end
            cnt <= cnt + 1;
            
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
