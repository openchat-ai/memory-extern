// 01_counter — 同步 4 位计数器
// 三个要素：时钟边沿(时序) + 异步复位 + 使能(组合控制)
// 这就是"寄存器传输级"的最小完整例子：
//   每个 posedge clk，把 count+1 算好写回寄存器。
module counter (
    input  wire       clk,    // 时钟
    input  wire       rst_n,  // 异步复位，低有效
    input  wire       en,     // 使能：为 1 才计数
    output reg  [3:0] count   // 4 位计数器输出
);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            count <= 4'b0;          // 复位清零
        else if (en)
            count <= count + 1'b1;  // 非阻塞赋值：边沿采样，下一秒生效
    end
endmodule
