// 数字环路滤波器 — 纯数字
// PI 控制器（比例-积分）

module digital_filter #(
    parameter IN_WIDTH  = 8,
    parameter OUT_WIDTH = 16
)(
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire [IN_WIDTH-1:0]      din,        // 相位差输入
    input  wire                     valid,       // 输入有效
    output reg [OUT_WIDTH-1:0]      dout        // 控制输出
);

    // PI 控制器参数
    parameter KP = 4;   // 比例系数（2的幂）
    parameter KI = 2;   // 积分系数（2的幂）
    
    reg signed [OUT_WIDTH-1:0] integral;
    reg signed [OUT_WIDTH-1:0] proportional;
    reg signed [OUT_WIDTH-1:0] output_reg;
    
    // 符号扩展
    wire signed [OUT_WIDTH-1:0] din_ext;
    assign din_ext = {{(OUT_WIDTH-IN_WIDTH){din[IN_WIDTH-1]}}, din};
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            integral <= 0;
            proportional <= 0;
            output_reg <= 0;
        end else if (valid) begin
            // 比例项
            proportional <= (din_ext <<< KP);
            
            // 积分项
            integral <= integral + (din_ext <<< KI);
            
            // 限幅
            if (integral > 2**(OUT_WIDTH-1) - 1) begin
                integral <= 2**(OUT_WIDTH-1) - 1;
            end else if (integral < -(2**(OUT_WIDTH-1))) begin
                integral <= -(2**(OUT_WIDTH-1));
            end
            
            // 输出
            output_reg <= proportional + integral;
        end
    end
    
    // 输出
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dout <= 0;
        end else begin
            dout <= output_reg;
        end
    end

endmodule
