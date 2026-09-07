// ============================================================================
// ws2812_smoke.v — 单 WS2812 LED 颜色循环（官方 ws2812 算法重写，清晰状态机）
// 时钟 50MHz（sys_clk），单 LED，24bit GRB。
// S3 未按(en=1)：每次发射完一轮后颜色旋转；S3 按下(en=0)：固定当前色。
// ============================================================================
`timescale 1ns/1ps

module ws2812_smoke #(
    parameter CLK_FRE = 50_000_000
)(
    input  clk,
    input  en,
    input  off,       // 1: 强制熄灭（WS2812 恒低）+ 状态机复位
    input  [1:0] lvl, // 亮度档位选择(lvl={key2,key1} 原样, 未按=1): 3=2%暗缺省 2=10% 1=100% 0=0.4%
    output reg WS2812
);

    // ---- 时序参数（50MHz 下计数）----
    // 1bit = 850ns高 + 400ns低  (逻辑1)
    // 0bit = 400ns高 + 850ns低  (逻辑0)
    // reset = >50us，这里取 100ms 便于目测循环
    localparam DELAY_1_HIGH = 42;   // ~840ns @50MHz (50clk=1us)
    localparam DELAY_1_LOW  = 20;   // ~400ns
    localparam DELAY_0_HIGH = 20;   // ~400ns
    localparam DELAY_0_LOW  = 42;   // ~840ns
    localparam DELAY_RESET  = 4_999_999; // ~100ms

    // 2% 亮度：颜色三通道非零处取 0x06（=6，约满值 0xFF 的 2.4%）。恒流 LED 下 10% 物理亮度≈感知 1/3 满亮仍刺眼，故降到 2%
    // 亮度档位由 lvl 实时选择（运行时按键可调，便于验证灰度机制是否板上生效）
    localparam LSAT = 6;      // 6 种颜色循环

    localparam RESET         = 2'd0;
    localparam DATA_SEND     = 2'd1;
    localparam BIT_SEND_HIGH = 2'd2;
    localparam BIT_SEND_LOW  = 2'd3;

    reg [1:0] state     = RESET;
    reg [4:0] bit_idx   = 0;
    reg [31:0] cnt      = 0;
    reg [2:0] color_idx = 0;
    reg [23:0] ucolor   = {6'h06, 8'h00, 8'h00};  // 初始红色 2%

    // lvl={key2,key1} → 默认 0x01(最小微亮)，按S2 切满亮对照；其余档同微亮
    reg [7:0] cur_lvl;
    always @(*) begin
        case (lvl)
            2'd1: cur_lvl = 8'hFF;  // 按 S2(key2=0) → 满亮(需要刺眼时)
            default: cur_lvl = 8'h01; // 默认/其余 → 0x01 最小微亮(已定稿，0x00=灭)
        endcase
    end

    // 颜色查表（GRB 24bit）：红/绿/蓝/黄/青/品红，亮度取 cur_lvl
    always @(*) begin
        case (color_idx)
            3'd0: ucolor = {cur_lvl, 8'h00, 8'h00};        // 红 (G=R0 B=0)
            3'd1: ucolor = {8'h00, cur_lvl, 8'h00};        // 绿
            3'd2: ucolor = {8'h00, 8'h00, cur_lvl};        // 蓝
            3'd3: ucolor = {cur_lvl, cur_lvl, 8'h00};      // 黄 (G+R)
            3'd4: ucolor = {8'h00, cur_lvl, cur_lvl};      // 青 (G+B)
            3'd5: ucolor = {cur_lvl, 8'h00, cur_lvl};      // 品红 (R+B)
            default: ucolor = {cur_lvl, cur_lvl, cur_lvl}; // 白
        endcase
    end

    always @(posedge clk) begin
        if (off) begin
            // 强制熄灭：保持 RESET 态、输出恒低、复位计数
            state     <= RESET;
            bit_idx   <= 0;
            cnt       <= 0;
            WS2812    <= 1'b0;
        end else begin
        case (state)
            RESET: begin
                WS2812 <= 1'b0;
                if (cnt < DELAY_RESET)
                    cnt <= cnt + 1;
                else begin
                    cnt       <= 0;
                    bit_idx   <= 0;
                    if (en)
                        color_idx <= (color_idx == (LSAT-1)) ? 3'd0 : color_idx + 3'd1;  // 换下一色
                    state     <= DATA_SEND;
                end
            end

            DATA_SEND: begin
                if (bit_idx < 24)
                    state <= BIT_SEND_HIGH;
                else
                    state <= RESET;   // 24bit 发完 → 复位(重置+旋转)
            end

            BIT_SEND_HIGH: begin
                WS2812 <= 1'b1;
                if (cnt < (ucolor[bit_idx] ? DELAY_1_HIGH : DELAY_0_HIGH))
                    cnt <= cnt + 1;
                else begin
                    cnt   <= 0;
                    state <= BIT_SEND_LOW;
                end
            end

            BIT_SEND_LOW: begin
                WS2812 <= 1'b0;
                if (cnt < (ucolor[bit_idx] ? DELAY_1_LOW : DELAY_0_LOW))
                    cnt <= cnt + 1;
                else begin
                    cnt     <= 0;
                    bit_idx <= bit_idx + 1;
                    state   <= DATA_SEND;
                end
            end
        endcase
        end  // else (not off)
    end

endmodule
