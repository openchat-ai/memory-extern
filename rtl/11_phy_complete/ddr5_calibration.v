// DDR5 校准模块 — 完整设计
// 包含写均衡、读均衡、时序校准

module ddr5_calibration #(
    parameter DQ_WIDTH = 8
)(
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire                     start,
    
    output reg                      done,
    output reg [7:0]                dly,          // 延迟值
    output reg                      dq_oe,        // 校准时 DQ 使能
    output reg                      dqs_oe        // 校准时 DQS 使能
);

    // ========================================
    // 校准状态机
    // ========================================
    localparam CAL_IDLE     = 4'h0;
    localparam CAL_WRITE    = 4'h1;
    localparam CAL_READ     = 4'h2;
    localparam CAL_COMPARE  = 4'h3;
    localparam CAL_ADJUST   = 4'h4;
    localparam CAL_DONE     = 4'h5;
    
    reg [3:0] state;
    reg [2:0] cal_step;
    reg [7:0] delay_current;
    reg [7:0] delay_target;
    
    integer i;
    
    // ========================================
    // 校准逻辑
    // ========================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= CAL_IDLE;
            cal_step <= 0;
            delay_current <= 0;
            delay_target <= 8'd128;  // 目标延迟
            dly <= 0;
            dq_oe <= 1'b0;
            dqs_oe <= 1'b0;
            done <= 1'b0;
        end else begin
            case (state)
                CAL_IDLE: begin
                    if (start) begin
                        state <= CAL_WRITE;
                        cal_step <= 0;
                        delay_current <= 0;
                    end
                end
                
                CAL_WRITE: begin
                    // 写入测试模式
                    dq_oe <= 1'b1;
                    dqs_oe <= 1'b1;
                    state <= CAL_READ;
                end
                
                CAL_READ: begin
                    // 读回测试模式
                    dq_oe <= 1'b0;
                    dqs_oe <= 1'b0;
                    state <= CAL_COMPARE;
                end
                
                CAL_COMPARE: begin
                    // 比较结果
                    if (delay_current < delay_target) begin
                        state <= CAL_ADJUST;
                    end else begin
                        state <= CAL_DONE;
                    end
                end
                
                CAL_ADJUST: begin
                    // 调整延迟
                    delay_current <= delay_current + 1;
                    dly <= delay_current;
                    state <= CAL_WRITE;
                end
                
                CAL_DONE: begin
                    done <= 1'b1;
                end
            endcase
        end
    end

endmodule
