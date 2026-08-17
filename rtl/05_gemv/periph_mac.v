`timescale 1ns/1ps
// 05_gemv — 内存侧数字外围：跨组 fp32 累加 MAC
//
// 设备路径（sim_cim.c 语义）：模拟阵列给每个 (row, group) 一个部分和 q，
// ADC 量化后进入数字外围，逐组还原 scale 并 fp32 累加：
//     y[r] = Σ_g  q[r][g] × 2^(sb-127)      （g=0..NGRP-1，顺序，fp32 RN）
//
// 本模块是"跨组累加器"：每个时钟处理一个组的 term = q×scale（periph_scale
// 精确乘），累加器本体就是上一课写的 f32_add（IEEE 逐位，20022 用例全过）。
// scale==255（NaN）的组贡献 0（同 C 参考的 continue）。
//
// 累加顺序与 C 参考逐组一致，因此结果逐位相等（fp32 加法结合律不成立，
// 顺序就是契约）。
module periph_mac #(
    parameter NGRP = 112
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        go,             // 脉冲：启动一行累加
    input  wire [31:0] q,              // 当前组部分和（fp32）
    input  wire [7:0]  scale,          // 当前组 E8M0 码
    output reg  [31:0] acc,            // fp32 累加结果
    output reg         done            // 脉冲：一行完成（最后一组 posedge 上）
);
    localparam S_IDLE = 1'b0;
    localparam S_RUN  = 1'b1;
    reg  state;
    reg  [15:0] cnt;

    wire [31:0] scaled;
    periph_scale ps (.q(q), .sb(scale), .p(scaled));

    wire valid = (scale != 8'hFF);
    wire [31:0] term = valid ? scaled : 32'h0000_0000;

    wire [31:0] acc_new;
    f32_add add (.a(acc), .b(term), .y(acc_new));
    // 第 0 组：C 语义 0.0f + term。fp32 中 0+x ≡ x（IEEE RN，含 ±0/±inf/NaN
    // 传播，term 的 NaN 已被 periph_scale 静默化），唯一特例是 -0 → +0。
    // 用一个比较器代替整个加法器实例（省 ~40% 加法器面积）。
    wire [31:0] acc0 = (term == 32'h8000_0000) ? 32'h0000_0000 : term;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= S_IDLE;
            cnt   <= 16'd0;
            acc   <= 32'h0000_0000;
            done  <= 1'b0;
        end else begin
            done <= 1'b0;
            case (state)
            S_IDLE: begin
                if (go) begin
                    state <= S_RUN;
                    cnt   <= 16'd1;
                    acc   <= acc0;           // 第 0 组就在 go 拍处理（+0 + term）
                end
            end
            S_RUN: begin
                acc <= acc_new;              // acc ← acc + term（本组）
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
