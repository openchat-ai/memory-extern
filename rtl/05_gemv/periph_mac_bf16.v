`timescale 1ns/1ps
// 05_gemv — 内存侧数字外围：跨组 bf16 累加 MAC（版本 B，流片目标）
//
// 与 periph_mac.v 同构，但累加精度改为 bf16（MX 生态标准累加类型）：
//     y[r] = Σ_g  q[r][g] × 2^(sb-127)      （g=0..NGRP-1，顺序，bf16 RN）
// q 为 bf16（1+8+7），scale 仍为 E8M0 码。面积优势来自 bf16_add
// （705 cells vs f32_add 1562），整个演示可压进 1 tile。
//
// 累加顺序与 C 参考逐组一致（bf16 加法结合律同样不成立，顺序即契约）。
module periph_mac_bf16 #(
    parameter NGRP = 8
) (
    input  wire         clk,
    input  wire         rst,
    input  wire         go,             // 脉冲：启动一行累加
    input  wire [15:0]  q,              // 当前组部分和（bf16）
    input  wire [7:0]   scale,          // 当前组 E8M0 码
    output reg  [15:0]  acc,            // bf16 累加结果
    output reg          done            // 脉冲：一行完成
);
    localparam S_IDLE = 1'b0;
    localparam S_RUN  = 1'b1;
    reg  state;
    reg  [15:0] cnt;

    wire [15:0] scaled;
    periph_scale_bf16 ps (.q(q), .sb(scale), .p(scaled));

    wire valid = (scale != 8'hFF);
    wire [15:0] term = valid ? scaled : 16'h0000;

    wire [15:0] acc_new;
    bf16_add add (.a(acc), .b(term), .y(acc_new));
    wire [15:0] acc0 = (term == 16'h8000) ? 16'h0000 : term;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= S_IDLE;
            cnt   <= 16'd0;
            acc   <= 16'h0000;
            done  <= 1'b0;
        end else begin
            done <= 1'b0;
            case (state)
            S_IDLE: begin
                if (go) begin
                    state <= S_RUN;
                    cnt   <= 16'd1;
                    acc   <= acc0;
                end
            end
            S_RUN: begin
                acc <= acc_new;
                if (cnt == NGRP - 1) begin
                    state <= S_IDLE;
                    done  <= 1'b1;
                end
                cnt <= cnt + 16'd1;
            end
            endcase
        end
    end
endmodule