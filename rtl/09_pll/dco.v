// DCO（数字控制振荡器）— 纯数字
// 用环形振荡器实现

module dco #(
    parameter CTRL_WIDTH = 6
)(
    input  wire [CTRL_WIDTH-1:0]   ctrl,       // 控制字
    input  wire                     rst_n,      // 复位
    output reg                      clk         // 输出时钟
);

    // 环形振荡器：奇数个反相器串联
    // ctrl 控制延迟单元数量
    
    reg [7:0] delay_line;
    reg [7:0] cnt;
    reg       osc_enable;
    
    // 控制逻辑：ctrl 值越大，延迟越小，频率越高
    always @(posedge rst_n or negedge rst_n) begin
        if (!rst_n) begin
            delay_line <= 0;
            cnt <= 0;
            osc_enable <= 1'b0;
            clk <= 1'b0;
        end else begin
            // 使能振荡
            osc_enable <= 1'b1;
            
            if (osc_enable) begin
                // 环形振荡器核心
                // ctrl 控制延迟链长度
                cnt <= cnt + 1;
                
                // 简化的环形振荡器模型
                // 实际应该是奇数个反相器串联
                case (ctrl[2:0])
                    3'b000: delay_line <= 8'h01;  // 最长延迟，最低频
                    3'b001: delay_line <= 8'h03;
                    3'b010: delay_line <= 8'h07;
                    3'b011: delay_line <= 8'h0F;
                    3'b100: delay_line <= 8'h1F;
                    3'b101: delay_line <= 8'h3F;
                    3'b110: delay_line <= 8'h7F;
                    3'b111: delay_line <= 8'hFF;  // 最短延迟，最高频
                endcase
                
                // 振荡：当计数器达到延迟值时翻转
                if (cnt >= delay_line) begin
                    cnt <= 0;
                    clk <= ~clk;
                end
            end
        end
    end

endmodule
