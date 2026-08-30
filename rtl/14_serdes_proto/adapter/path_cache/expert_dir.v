// ============================================================================
// expert_dir.v — 专家 LRU 缓存目录(做实: trunk 永久驻留 + 专家 LRU 替换)
//
// 场景: SSD 存 trunk + 每层激活专家(动态更新)。本模块是缓存控制器内部的
//       真实目录, 采用 cache4.v 验证过的"单 always + 阻塞 = 组合结算"风格。
//
// 槽布局:
//   - 槽0 = TRUNK: 永久驻留, 永不替换, 恒命中。
//   - 槽1..EXPERT_SLOTS-1 = 专家槽, LRU 排序(rcnt: 每槽一个"上次访问拍"相对
//     计数, 最大者最旧=LRU)。
//
// 操作:
//   - 访问 req_valid+tag: 命中 -> req_hit=1 + req_data + 刷新该槽 [MRU];
//                         未命中 -> req_hit=0 + req_way=当前 LRU 槽(待替换)
//   - 加载 load_valid+load_way+load_tag+load_data: 装入磁盘数据并置 MRU
//   - 动态更新 upd_valid+upd_id+upd_data: 命中专家就地改权重 + 刷 MRU
//
// 仿真用单字权重(DW); 命中/替换/保序/动态更新逻辑与块级等价, 可综合。
// ============================================================================

`timescale 1ns/1ps

module expert_dir #(
    parameter DW           = 32,          // 权重字位宽
    parameter EXPERT_SLOTS = 8            // 总槽数 = 1(trunk) + (EXPERT_SLOTS-1) 专家
)(
    input  wire clk,
    input  wire rst_n,

    // ---- trunk 永久驻留(槽0, 恒命中) ----
    input  wire [7:0]      trunk_id,
    input  wire [DW-1:0]   trunk_data,

    // ---- 访问请求 ----
    input  wire            req_valid,
    input  wire [7:0]      req_tag,
    output reg             req_hit,
    output reg  [7:0]      req_way,
    output reg  [DW-1:0]   req_data,
    output reg             req_is_trunk,

    // ---- 加载(替换槽装入磁盘数据) ----
    input  wire            load_valid,
    input  wire [7:0]      load_way,
    input  wire [7:0]      load_tag,
    input  wire [DW-1:0]   load_data,

    // ---- 命令动态更新 ----
    input  wire            upd_valid,
    input  wire [7:0]      upd_id,
    input  wire [DW-1:0]   upd_data
);

    localparam S = EXPERT_SLOTS;

    reg [7:0]     tagv [0:S-1];
    reg [DW-1:0]  datv [0:S-1];
    reg           valid[0:S-1];
    reg [7:0]     rcnt [0:S-1];      // 相对旧度计数: 越大越旧(LRU)

    // ---- 存储: 时序更新(非阻塞, 无竞态, 仅在 posedge 变) ----
    integer k;
    always @(posedge clk) begin
        if (!rst_n) begin
            for (k = 0; k < S; k = k + 1) begin
                tagv[k]  <= 0;
                datv[k]  <= 0;
                valid[k] <= 0;
                rcnt[k]  <= 0;
            end
            valid[0] <= 1;           // trunk 槽0 永久有效
            tagv[0]  <= 0;
        end else begin
            // 访问: 命中专家 -> 置 MRU(其余相对 +1)
            if (req_valid && !is_trunk && is_ex_hit) begin
                for (k = 0; k < S; k = k + 1)
                    rcnt[k] <= (k == hw) ? 8'd0 : rcnt[k] + 8'd1;
            end

            // 加载: 装入槽 load_way 并置 MRU
            if (load_valid) begin
                tagv[load_way]  <= load_tag;
                valid[load_way] <= 1;
                datv[load_way]  <= load_data;
                for (k = 0; k < S; k = k + 1)
                    rcnt[k] <= (k == load_way) ? 8'd0 : rcnt[k] + 8'd1;
            end

            // 动态更新: 就地改权重 + 刷 MRU
            if (upd_valid) begin
                for (k = 1; k < S; k = k + 1)
                    if (valid[k] && tagv[k] == upd_id) begin
                        datv[k] <= upd_data;
                        for (j = 0; j < S; j = j + 1)
                            rcnt[j] <= (j == k) ? 8'd0 : rcnt[j] + 8'd1;
                    end
            end
        end
    end

    // ---- req_* 组合输出: 读稳定快照, 与源桩同拍对齐 ----
    integer i, j, hw, lw;
    reg    is_trunk, is_ex_hit;
    always @(*) begin
        is_trunk  = (req_tag == trunk_id);
        is_ex_hit = 1'b0;
        hw = 0;
        for (i = 1; i < S; i = i + 1)
            if (valid[i] && tagv[i] == req_tag) begin
                is_ex_hit = 1'b1;
                hw = i;
            end
        // 找专家 LRU 槽(rcnt 最大者; 只在槽1..S-1 里找)
        lw = 1;
        for (i = 2; i < S; i = i + 1)
            if (rcnt[i] > rcnt[lw]) lw = i;

        req_hit       = req_valid & (is_trunk | is_ex_hit);
        req_is_trunk  = req_valid & is_trunk;
        if (is_trunk) begin
            req_way  = 0;
            req_data = trunk_data;
        end else if (is_ex_hit) begin
            req_way  = hw;
            req_data = datv[hw];
        end else begin
            req_way  = lw;
            req_data = 0;
        end
    end



endmodule
