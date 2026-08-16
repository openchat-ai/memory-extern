// 02_lru — 2 路组相联缓存里的 LRU 状态机
// 一个集合里只有两块 A 和 B。状态 = "谁最久没被用（该被驱逐）"。
//
//   状态表（Moore 型：输出 = 状态本身）：
//     lru=0 → 驱逐 A      lru=1 → 驱逐 B
//   迁移（访问事件驱动）：
//     访问 A → A 变成 MRU → 驱逐目标变成 B (1)
//     访问 B → B 变成 MRU → 驱逐目标变成 A (0)
//     无访问 → 保持
//
// 这就是 k3_cache LRU 替换的硬件种子：状态机决定"驱逐谁"。
module lru2 (
    input  wire       clk,      // 时钟
    input  wire       rst_n,    // 异步复位（低有效）
    input  wire [1:0] access,   // 01=访问A, 10=访问B, 00=无访问
    output reg        lru       // 0=驱逐A, 1=驱逐B
);
    reg next_lru;               // "下一个状态"

    // ① 组合逻辑：下一状态 = f(当前状态, 输入)
    always @(*) begin
        case (access)
            2'b01: next_lru = 1'b1;   // 访问了 A → 驱逐 B
            2'b10: next_lru = 1'b0;   // 访问了 B → 驱逐 A
            default: next_lru = lru;  // 无访问 → 保持
        endcase
    end

    // ② 时序逻辑：时钟边沿把下一状态锁进状态寄存器
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            lru <= 1'b0;              // 复位：驱逐 A
        else
            lru <= next_lru;
    end
endmodule
