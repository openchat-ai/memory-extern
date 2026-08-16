// 03_cache — 4 路组相联缓存：LRU 替换 + 命中/缺失计数
// 一个集合 4 个槽（路），每个槽有 有效位 + 8 位地址标签 + 2 位"新旧程度"age
//   age: 3=最近用(MRU)   0=最久未用(LRU)
// 命中：地址在某个有效槽里 → 该槽抬到 MRU，比它"新"的槽都降 1
// 缺失：把 age==0 的槽驱逐，放入新地址并抬到 MRU，其余有效槽降 1
//
// 硬核规范（本课重点）：
//   同一个 always 块里 —— 阻塞赋值 "=" 只算临时量（下一拍要用的值），
//                            非阻塞赋值 "<=" 才更新状态寄存器。
//   不要用独立的 always @(*) 算 hit_way 再给时序块读：
//   同一拍里 NBA 更新会重算组合逻辑并重新激活时序块 → 一拍执行两次（我们抓到的 bug）。
module cache4 (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        req,          // 请求脉冲（保持 1 拍）
    input  wire [7:0]  addr,         // 8 位地址（256 个）
    output reg         hit,          // 本次是否命中
    output reg  [31:0] hit_count,    // 命中次数
    output reg  [31:0] miss_count    // 缺失次数
);
    localparam NUM_WAYS = 4;
    localparam TAG_W    = 8;

    reg [NUM_WAYS-1:0]       valid;                // 每个槽是否有效
    reg [TAG_W-1:0]          tag  [0:NUM_WAYS-1];  // 每个槽存的地址
    reg [1:0]                age  [0:NUM_WAYS-1];  // 0=LRU ... 3=MRU

    always @(posedge clk or negedge rst_n) begin
        integer i;
        integer hit_way;    // 命中的槽（无命中 = -1）
        integer lru_way;    // 最久未用的槽

        if (!rst_n) begin
            valid <= 4'b0;
            for (i = 0; i < NUM_WAYS; i = i + 1)
                age[i] <= 2'd0;              // 复位：age 全 0，保证 lru_way 按序填充
            hit_count <= 32'd0;
            miss_count <= 32'd0;
            hit <= 1'b0;
        end else if (req) begin
            // ① 阻塞赋值（=）：只算临时量，不进寄存器
            hit_way = -1;
            for (i = 0; i < NUM_WAYS; i = i + 1)
                if (valid[i] && tag[i] == addr)
                    hit_way = i;
            lru_way = 0;
            for (i = 1; i < NUM_WAYS; i = i + 1)
                if (age[i] < age[lru_way])
                    lru_way = i;

            // ② 非阻塞赋值（<=）：更新状态
            if (hit_way >= 0) begin
                hit <= 1'b1;
                hit_count <= hit_count + 1'b1;
                // 命中：该槽抬到 MRU(3)，比它"新"的槽降 1
                age[hit_way] <= 2'd3;
                for (i = 0; i < NUM_WAYS; i = i + 1)
                    if (valid[i] && i != hit_way && age[i] > age[hit_way])
                        age[i] <= age[i] - 2'd1;
            end else begin
                hit <= 1'b0;
                miss_count <= miss_count + 1'b1;
                // 缺失：驱逐最久未用的槽，放入新地址，抬到 MRU
                valid[lru_way] <= 1'b1;
                tag[lru_way] <= addr;
                age[lru_way] <= 2'd3;
                for (i = 0; i < NUM_WAYS; i = i + 1)
                    if (valid[i] && i != lru_way && age[i] > age[lru_way])
                        age[i] <= age[i] - 2'd1;
            end
        end
    end
endmodule
