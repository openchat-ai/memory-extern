// PFD（鉴频鉴相器）— 纯数字
// 检测参考时钟和反馈时钟的相位/频率差

module pfd (
    input  wire     ref_clk,    // 参考时钟
    input  wire     fb_clk,     // 反馈时钟
    input  wire     rst_n,      // 复位
    output reg      up,         // 上冲（参考超前）
    output reg      down        // 下冲（反馈超前）
);

    // 状态定义
    localparam IDLE = 2'b00;
    localparam UP   = 2'b01;
    localparam DOWN = 2'b10;
    
    reg [1:0] state;
    reg       ref_edge, fb_edge;
    reg       ref_prev, fb_prev;
    
    // 检测时钟边沿
    always @(posedge ref_clk or negedge rst_n) begin
        if (!rst_n) begin
            ref_prev <= 1'b0;
            ref_edge <= 1'b0;
        end else begin
            ref_prev <= 1'b1;
            ref_edge <= 1'b1 && !ref_prev;
        end
    end
    
    always @(posedge fb_clk or negedge rst_n) begin
        if (!rst_n) begin
            fb_prev <= 1'b0;
            fb_edge <= 1'b0;
        end else begin
            fb_prev <= 1'b1;
            fb_edge <= 1'b1 && !fb_prev;
        end
    end
    
    // PFD 状态机
    always @(posedge ref_clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            up <= 1'b0;
            down <= 1'b0;
        end else begin
            case (state)
                IDLE: begin
                    if (ref_edge) begin
                        state <= UP;
                        up <= 1'b1;
                    end else if (fb_edge) begin
                        state <= DOWN;
                        down <= 1'b1;
                    end
                end
                
                UP: begin
                    if (fb_edge) begin
                        state <= IDLE;
                        up <= 1'b0;
                        down <= 1'b0;
                    end
                end
                
                DOWN: begin
                    if (ref_edge) begin
                        state <= IDLE;
                        up <= 1'b0;
                        down <= 1'b0;
                    end
                end
                
                default: state <= IDLE;
            endcase
        end
    end

endmodule
