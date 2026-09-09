`timescale 1ns/1ps
`default_nettype none
//────────────────────────────────────────────────────────────────────────────
// relay_fifo.v — DMA 弹性转载 FIFO (M7)
//
// 定位 (冻结基线 §8): 板→主机写回路径的 128KB 弹性 FIFO.
//   - 每层 diff(单笔 49KB)算完即推, 异步无阻塞; 结构性深度 ≥ 单笔 → 笔内不停;
//   - 阈值 credit 闸 (≥50% 顶不推新笔), 等主机排走 (266MB/s 零停顿);
//   - 转载站 (B-SRAM 侧 0.5MB/s 慢取) 走同口, 攒批靠主机写合并, 不靠大数组.
//
// 语义:
//   - 字宽 DW 循环缓存; 深度 DEPTH 字数 (须 2 幂). 实配 128KB = DW32 32768 字;
//   - 推侧 w_valid/w_ready (电平 ready), 拉侧 r_valid/r_take (电平取走);
//   - used/max_used 观测, over_half = 阈值闸, w_ops/r_ops 簿记.
// 纪律 (M6 沉淀): 消费侧一律电平手拉手; 计数位宽容终值 (q 用 AW+1 位).
//────────────────────────────────────────────────────────────────────────────
module relay_fifo #(
    parameter DW    = 32,
    parameter DEPTH = 512          // 字数 (须 2 幂; 128KB 实配 = 32768 字)
)(
    input  wire          clk,
    input  wire          rst_n,

    // ---- 推 (层 diff 泵) ----
    input  wire          w_valid,
    input  wire [DW-1:0] w_data,
    output wire          w_ready,

    // ---- 拉 (主机 DMA / 转载站) ----
    output wire          r_valid,
    output wire [DW-1:0] r_data,
    input  wire          r_take,

    // ---- 状态 ----
    output wire [31:0]   used,
    output wire          full, empty,
    output wire          over_half,       // >= 50% 阈值 (新笔 credit 闸)
    output wire [31:0]   w_ops, r_ops,
    output reg  [31:0]   max_used
);

    localparam AW = $clog2(DEPTH);

    reg [AW-1:0]  wp, rp;
    reg [AW:0]    q;                     // 已用字数 (AW+1 位容 DEPTH 终值)
    reg [DW-1:0]  mem [0:DEPTH-1];
    reg [31:0]    w_ops_r, r_ops_r;

    assign full      = (q == DEPTH);
    assign empty     = (q == 0);
    assign w_ready   = !full;
    assign r_valid   = !empty;           // 电平: 非空即有效
    assign r_data    = mem[rp];
    assign over_half = (q >= (DEPTH >> 1));
    assign used      = q;                // 零展宽
    assign w_ops     = w_ops_r;
    assign r_ops     = r_ops_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wp <= 0; rp <= 0; q <= 0;
            w_ops_r <= 0; r_ops_r <= 0; max_used <= 0;
        end else begin
            if (w_valid && w_ready) begin
                mem[wp] <= w_data;
                wp <= wp + 1'b1;
                q  <= q + 1'b1;
                w_ops_r <= w_ops_r + 1'b1;
                if (q + 1'b1 > max_used) max_used <= q + 1'b1;
            end
            if (r_valid && r_take) begin
                rp <= rp + 1'b1;
                q  <= q - 1'b1;
                r_ops_r <= r_ops_r + 1'b1;
            end
        end
    end

endmodule
`default_nettype wire