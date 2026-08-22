// TDC（时间数字转换器）— 纯数字
// 测量两个时钟边沿的时间差

module tdc #(
    parameter WIDTH = 8
)(
    input  wire             ref_clk,        // 参考时钟
    input  wire             fb_clk,         // 反馈时钟
    input  wire             rst_n,          // 复位
    output reg [WIDTH-1:0]  phase_diff,     // 相位差输出
    output reg              valid           // 输出有效
);

    // 延迟链
    reg [WIDTH-1:0] delay_chain [0:WIDTH-1];
    reg [WIDTH-1:0] ref_edge_pos;
    reg [WIDTH-1:0] fb_edge_pos;
    reg             ref_prev, fb_prev;
    reg             ref_edge, fb_edge;
    reg [1:0]       state;
    
    localparam IDLE = 2'b00;
    localparam MEASURE = 2'b01;
    localparam DONE = 2'b10;
    
    integer i;
    
    // 检测参考时钟边沿
    always @(posedge ref_clk or negedge rst_n) begin
        if (!rst_n) begin
            ref_prev <= 1'b0;
            ref_edge <= 1'b0;
        end else begin
            ref_prev <= 1'b1;
            ref_edge <= 1'b1 && !ref_prev;
        end
    end
    
    // 检测反馈时钟边沿
    always @(posedge fb_clk or negedge rst_n) begin
        if (!rst_n) begin
            fb_prev <= 1'b0;
            fb_edge <= 1'b0;
        end else begin
            fb_prev <= 1'b1;
            fb_edge <= 1'b1 && !fb_prev;
        end
    end
    
    // TDC 核心：延迟线采样
    always @(posedge ref_clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < WIDTH; i = i + 1) begin
                delay_chain[i] <= 0;
            end
            phase_diff <= 0;
            valid <= 1'b0;
            state <= IDLE;
        end else begin
            case (state)
                IDLE: begin
                    valid <= 1'b0;
                    if (ref_edge) begin
                        state <= MEASURE;
                        // 启动延迟链
                        delay_chain[0] <= 1'b1;
                        for (i = 1; i < WIDTH; i = i + 1) begin
                            delay_chain[i] <= delay_chain[i-1];
                        end
                    end
                end
                
                MEASURE: begin
                    // 继续移位
                    for (i = WIDTH-1; i > 0; i = i - 1) begin
                        delay_chain[i] <= delay_chain[i-1];
                    end
                    delay_chain[0] <= 1'b0;
                    
                    // 检测反馈边沿到达
                    if (fb_edge) begin
                        // 计数延迟链中1的个数
                        phase_diff <= 0;
                        for (i = 0; i < WIDTH; i = i + 1) begin
                            if (delay_chain[i]) phase_diff <= phase_diff + 1;
                        end
                        valid <= 1'b1;
                        state <= DONE;
                    end
                end
                
                DONE: begin
                    valid <= 1'b0;
                    state <= IDLE;
                end
            endcase
        end
    end

endmodule
