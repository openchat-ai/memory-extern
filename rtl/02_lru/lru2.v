`timescale 1ns/1ps
// 02_lru — 2 路 LRU 替换核心（北极星调度器的硬件种子）。
// lru_way 指针：指向 LRU 路（miss 时被替换、写回）。命中某路后该路变 MRU，
// 指针转向另一路。语义 = 教科书 2-way LRU。
// FSM 范式（README 硬核规范）：输入在两个时钟沿之间摆好，沿上先捕获旧状态
// 结果（hit/way），再更新状态；不能用同一个沿自读自写。
module lru2 #(
    parameter AW = 8   // tag 位宽
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        req,      // 访问请求
    input  wire        we,       // 1=写(miss 装入), 0=读
    input  wire [AW-1:0] tag,    // 请求的 tag
    output reg         hit,      // 上一拍请求命中
    output reg  [1:0]  way       // 命中路；miss 时为将被替换的路
);

    reg [AW-1:0] tag0;
    reg [AW-1:0] tag1;
    reg          lru_way;        // 0→evict way0, 1→evict way1

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            tag0    <= 0;
            tag1    <= 0;
            lru_way <= 0;
        end else if (req) begin
            if (tag == tag0) begin
                lru_way <= 1;           // way0 MRU → way1 变 LRU
            end else if (tag == tag1) begin
                lru_way <= 0;           // way1 MRU → way0 变 LRU
            end else if (lru_way == 0) begin
                tag0    <= tag;         // 替换 way0
                lru_way <= 1;
            end else begin
                tag1    <= tag;         // 替换 way1
                lru_way <= 0;
            end
        end
    end

    // 输出：沿上先用"旧标签"判定本拍请求的 hit/way，再更新状态。
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            hit <= 0;
            way <= 0;
        end else begin
            if (req && tag == tag0) begin
                hit <= 1; way <= 2'd0;
            end else if (req && tag == tag1) begin
                hit <= 1; way <= 2'd1;
            end else begin
                hit <= 0; way <= {1'b0, lru_way};
            end
        end
    end

endmodule