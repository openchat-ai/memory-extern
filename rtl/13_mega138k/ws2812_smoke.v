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

    localparam RESET         = 2'd0;
    localparam DATA_SEND     = 2'd1;
    localparam BIT_SEND_HIGH = 2'd2;
    localparam BIT_SEND_LOW  = 2'd3;

    reg [1:0] state     = RESET;
    reg [4:0] bit_idx   = 0;
    reg [31:0] cnt      = 0;
    reg [23:0] ucolor   = 24'h0000FF;

    always @(posedge clk) begin
        case (state)
            RESET: begin
                WS2812 <= 1'b0;
                if (cnt < DELAY_RESET)
                    cnt <= cnt + 1;
                else begin
                    cnt  <= 0;
                    bit_idx <= 0;
                    if (en)
                        ucolor <= {ucolor[22:0], ucolor[23]};  // 颜色旋转
                    state <= DATA_SEND;
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
    end

endmodule
