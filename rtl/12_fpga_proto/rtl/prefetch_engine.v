// ============================================================================
// prefetch_engine.v — 预取引擎（NAND→DDR4 后台搬运）
//
// 功能：在 MAC 消费当前层的同时，从存储预取下一层数据
// 实现：简单地址生成器 + 握手信号
// ============================================================================
`timescale 1ns/1ps

module prefetch_engine #(
    parameter ADDR_W = 32,     // 存储地址位宽
    parameter BURST  = 16      // 突发长度（每次连续读取的 beat 数）
)(
    input  wire            clk,
    input  wire            rst_n,
    input  wire            enable,          // 全局使能
    // 读请求接口（连到存储控制器）
    output reg             rd_req,           // 读取请求脉冲
    output reg  [ADDR_W-1:0] rd_addr,        // 读取地址
    input  wire            rd_data_valid,    // 数据有效
    input  wire [511:0]    rd_data,          // 512bit 数据
    // 输出到消费侧（MAC/解包）
    output reg             out_valid,
    output reg  [511:0]    out_data,
    input  wire            out_ready         // 下游可接收
);
    reg [ADDR_W-1:0] addr_q;
    reg              burst_active;
    reg [$clog2(BURST)-1:0] burst_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_req       <= 0;
            rd_addr      <= 0;
            burst_active <= 0;
            burst_cnt    <= 0;
        end else if (enable) begin
            if (!burst_active && !rd_req) begin
                // 发起新的突发读取
                rd_req   <= 1;
                rd_addr  <= addr_q;
                burst_active <= 1;
                burst_cnt    <= 0;
            end else if (burst_active) begin
                rd_req <= 0;
                if (rd_data_valid) begin
                    out_valid <= 1;
                    out_data  <= rd_data;
                    burst_cnt <= burst_cnt + 1;
                    if (burst_cnt == BURST - 1) begin
                        burst_active <= 0;   // 本轮突发完成
                        addr_q       <= addr_q + BURST * 64; // 步进
                    end else begin
                        rd_addr <= rd_addr + 64;     // 连续下一拍
                    end
                end
            end
        end
    end

endmodule
