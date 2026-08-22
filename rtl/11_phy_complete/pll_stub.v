// PLL Stub — 行为级模型
// 由代工厂替换为实际 PLL IP

module pll_stub (
    input  wire     ref_clk,
    input  wire     rst_n,
    
    output wire     clk_0,      // 0 度
    output wire     clk_90,     // 90 度
    output wire     clk_180,    // 180 度
    output wire     clk_270,    // 270 度
    output reg      locked
);

    // ========================================
    // 行为级模型
    // ========================================
    reg [7:0] delay_cnt;
    
    // 锁定延迟
    always @(posedge ref_clk or negedge rst_n) begin
        if (!rst_n) begin
            delay_cnt <= 0;
            locked <= 1'b0;
        end else if (delay_cnt < 8'd255) begin
            delay_cnt <= delay_cnt + 1;
        end else begin
            locked <= 1'b1;
        end
    end
    
    // 时钟分频（简化模型）
    reg clk_div;
    always @(posedge ref_clk or negedge rst_n) begin
        if (!rst_n) begin
            clk_div <= 1'b0;
        end else begin
            clk_div <= ~clk_div;
        end
    end
    
    // 相位生成（用 always block 代替 assign + #delay）
    reg clk_90_r;
    reg clk_180_r;
    reg clk_270_r;
    
    initial begin
        clk_90_r = 0;
        clk_180_r = 0;
        clk_270_r = 0;
    end
    
    // 简化模型：直接用分频时钟
    assign clk_0 = clk_div;
    assign clk_90 = clk_90_r;
    assign clk_180 = clk_180_r;
    assign clk_270 = clk_270_r;
    
    // 生成相位偏移时钟（90/180/270）
    always @(posedge clk_div) begin
        clk_270_r <= ~clk_270_r;
    end
    
    always @(negedge clk_div) begin
        clk_90_r <= ~clk_90_r;
        clk_180_r <= ~clk_180_r;
    end

endmodule
