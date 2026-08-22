// Lock Detector — 纯数字
// 检测 PLL 是否锁定

module lock_detector (
    input  wire     ref_clk,    // 参考时钟
    input  wire     fb_clk,     // 反馈时钟
    input  wire     rst_n,      // 复位
    output reg      locked      // 锁定信号
);

    reg [3:0] ref_cnt;
    reg [3:0] fb_cnt;
    reg [3:0] diff;
    reg [7:0] stable_cnt;
    
    // 计算相位差
    always @(posedge ref_clk or negedge rst_n) begin
        if (!rst_n) begin
            ref_cnt <= 0;
            fb_cnt <= 0;
            diff <= 0;
        end else begin
            ref_cnt <= ref_cnt + 1;
            if (fb_clk) fb_cnt <= fb_cnt + 1;
            
            // 计算差异
            if (ref_cnt > fb_cnt) begin
                diff <= ref_cnt - fb_cnt;
            end else begin
                diff <= fb_cnt - ref_cnt;
            end
        end
    end
    
    // 锁定检测
    always @(posedge ref_clk or negedge rst_n) begin
        if (!rst_n) begin
            locked <= 1'b0;
            stable_cnt <= 0;
        end else begin
            if (diff < 2) begin  // 相位差小于2个周期
                if (stable_cnt < 8'hFF) begin
                    stable_cnt <= stable_cnt + 1;
                end
                if (stable_cnt > 8'hF0) begin  // 稳定足够长时间
                    locked <= 1'b1;
                end
            end else begin
                stable_cnt <= 0;
                locked <= 1'b0;
            end
        end
    end

endmodule
