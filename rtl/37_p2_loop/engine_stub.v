`timescale 1ns/1ps
`default_nettype none
//────────────────────────────────────────────────────────────────────────────
// engine_stub.v — M21 层引擎段(骨架): 消费装配权重流, 逐层求和
//
// 契约 (board-1g-k3-frozen.md §9 层引擎 = 真机 GEMM 待 P2):
//   引擎 = 装配前端的消费者: 依 in_take(=credit) 逐词吃下装配词流, 每层恰
//   TOP*EW 词 → layer_done 脉 (作为源侧下一层屏障); NL 层完 → token_done
//   (触发输出头)。acc = 会话内 16b 截位累加 (FAST 替身; P2 为真 GEMM 结果)。
//   背压: credit 断 → 上游装配停拍 (等价引擎段慢取)。
//────────────────────────────────────────────────────────────────────────────
module engine_stub #(
    parameter TOP = 8,        // 装配词流: 每层 TOP 专家
    parameter EW  = 8,        // 每专家词数
    parameter NL  = 3,        // 层数
    parameter SW  = 16,       // 词位宽
    parameter AW  = 16        // 累加器截位
)(
    input  clk, rst_n,
    input  credit,                            // 引擎可收门 (背压注入)
    input  in_valid, input [SW-1:0] in_data,
    output wire in_take,                      // 引擎吃词使能 (=credit)
    output reg  layer_done, token_done,       // 层完/会话完 脉 (各1拍)
    output reg  [$clog2(NL)-1:0] e_lay,       // 当前层
    output reg  [AW-1:0] acc,                 // 截位累加 (FAST 替身)
    output reg  [31:0] words                  // 会话累计吃词
);
    localparam WCW = $clog2(TOP*EW);
    reg [WCW-1:0] wc;

    assign in_take = credit;
    wire eat = credit && in_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            layer_done <= 0; token_done <= 0; e_lay <= 0; acc <= 0; words <= 0; wc <= 0;
        end else begin
            layer_done <= 0; token_done <= 0;
            if (eat) begin
                words <= words + 1;
                acc   <= acc + in_data;
                if (wc == TOP*EW-1) begin
                    wc <= 0;
                    if (e_lay == NL-1) begin
                        e_lay <= 0; token_done <= 1;
                    end else begin
                        layer_done <= 1; e_lay <= e_lay + 1;
                    end
                end else wc <= wc + 1;
            end
        end
    end
endmodule
`default_nettype wire