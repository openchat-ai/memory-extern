// 分频器 — 纯数字
// 将高频时钟分频到参考时钟频率

module freq_divider #(
    parameter WIDTH = 5
)(
    input  wire             clk,        // 输入时钟（高频）
    input  wire             rst_n,      // 复位
    input  wire [WIDTH-1:0] ratio,      // 分频比
    output reg              divided     // 分频后时钟
);

    reg [WIDTH-1:0] count;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            count <= 0;
            divided <= 1'b0;
        end else begin
            if (count >= ratio - 1) begin
                count <= 0;
                divided <= ~divided;
            end else begin
                count <= count + 1;
            end
        end
    end

endmodule
