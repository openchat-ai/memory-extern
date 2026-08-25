// ============================================================================
// stream_engine.v — 流式推理引擎（简洁版）
//
// 功能：从存储流式读取权重 → 解码 → 累加 → 输出结果
// 验证目标：证明"预取→解码→消费"流水线可以正确工作
// ============================================================================
`timescale 1ns/1ps

module stream_engine #(
    parameter NUM_WORDS = 64      // 权重总数（int4 个数）
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    // 模拟存储读取接口（NAND/ROM 延迟后返回数据）
    output reg         mem_rd_en,
    output reg  [9:0]  mem_rd_addr,
    input  wire [31:0] mem_rd_data,
    input  wire        mem_rd_valid,
    // 输出
    output reg  [31:0] result,
    output reg         result_valid,
    output reg         busy
);

    // ---- 状态 ----
    localparam S_IDLE   = 2'd0;
    localparam S_READ   = 2'd1;   // 从存储读
    localparam S_COMPUTE= 2'd2;   // MAC 消费
    localparam S_DONE   = 2'd3;

    reg [1:0] state;
    reg [31:0] fetched_cnt;
    reg [31:0] consumed_cnt;

    assign busy = (state != S_IDLE);
    assign done = (state == S_DONE);

    // ========================================================================
    // 简化 FIFO：NAND 和 MAC 之间的解耦
    // ========================================================================
    localparam DEPTH = 16;
    reg [31:0] buf_mem [0:DEPTH-1];
    reg [$clog2(DEPTH)-1:0] wp, rp;
    reg [$clog2(DEPTH+1)-1:0] count;

    wire fifo_empty = (count == 0);
    wire fifo_full  = (count >= DEPTH);

    // 写入侧：从存储预取
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) wp <= 0;
        else if (mem_rd_valid && !fifo_full) wp <= wp + 1;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) count <= 0;
        else case ({mem_rd_valid && !fifo_full, mac_consumed && !fifo_empty})
            2'b10: count <= count + 1;
            2'b01: count <= count - 1;
            default: ;
        endcase
    end

    // ========================================================================
    // 存储读取引擎
    // ========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mem_rd_en <= 0;
            mem_rd_addr <= 0;
        end else begin
            if (state == S_READ || state == S_COMPUTE) begin
                if (!fifo_full) begin
                    mem_rd_en <= 1;
                    mem_rd_addr <= mem_rd_addr + 4;
                end else begin
                    mem_rd_en <= 0;
                end
            end else begin
                mem_rd_en <= 0;
                mem_rd_addr <= 0;
            end
        end
    end

    // ========================================================================
    // MAC 消费逻辑（从 FIFO 读出并累加）
    // ========================================================================
    reg [31:0] running_sum;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            running_sum <= 32'd0;
            rp <= 0;
        end else if (!fifo_empty) begin
            running_sum <= running_sum ^ buf_mem[rp];
            rp <= (rp == DEPTH-1) ? 0 : rp + 1;
        end
    end

    // ========================================================================
    // 主状态机
    // ========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            busy         <= 1'b0;
            fetched_cnt  <= 32'd0;
            consumed_cnt <= 32'd0;
            result       <= 32'd0;
            result_valid <= 1'b0;
        end else begin
            result_valid <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (start) begin
                        state       <= S_READ;
                        busy        <= 1'b1;
                        fetched_cnt <= 32'd0;
                        consumed_cnt<= 32'd0;
                    end
                end

                S_READ: begin
                    if (!fifo_full) begin
                        // 模拟存储返回数据（用地址作为伪数据）
                        buf_mem[wp] <= {mem_rd_addr, ~mem_rd_addr};
                        wp <= (wp == DEPTH-1) ? 0 : wp + 1;
                        count <= count + 1;
                    end

                    // 全部取完？
                    if (fetched_cnt >= NUM_WORDS) begin
                        state <= S_COMPUTE;
                    end
                end

                S_COMPUTE: begin
                    if (!fifo_empty) begin
                        running_sum <= running_sum ^ buf_mem[rp];
                        rp <= (rp == DEPTH-1) ? 0 : rp + 1;
                        consumed_cnt <= consumed_cnt + 1;
                    end

                    if (consumed_cnt >= NUM_WORDS) begin
                        state <= S_DONE;
                        result <= running_sum;
                        result_valid <= 1;
                    end
                end

                S_DONE: begin
                    busy <= 0;
                    state <= S_IDLE;
                end
            endcase
        end
    end

endmodule
