// 01_counter — 同步 12 位计数器，数到 1000 归零
// 三个要素：时钟边沿(时序) + 异步复位 + 使能(组合控制)
// 每个 posedge clk：复位则清零；否则若使能，到 1000 就回 0，不然 +1
module counter (
    input  wire        clk,    // 时钟
    input  wire        rst_n,  // 异步复位，低有效
    input  wire        en,     // 使能：为 1 才计数
    output reg  [11:0] count   // 12 位计数器输出（够数到 1000）
);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            count <= 12'b0;         // 复位清零
        else if (en)
            count <= (count >= 12'd1000) ? 12'd0 : count + 1'b1;
            // 到 1000 就回 0，否则 +1（?: 三元 = PHP 里的那个）
    end
endmodule
