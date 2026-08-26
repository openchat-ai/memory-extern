// ============================================================================
// streaming_top.v — 流式 MoE 推理引擎（自包含可仿真版本）
// ============================================================================
`timescale 1ns/1ps

module streaming_top #(
    parameter NUM_MACS      = 16,
    parameter TOTAL_WEIGHTS = 1024   // int4 权重总数
)(
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start,
    output reg          busy,
    output reg          done,
    // 模拟 NAND 接口
    output reg          nand_rd_en,
    output reg  [31:0]  nand_rd_addr,
    input  wire [31:0]  nand_rd_data,
    input  wire         nand_rd_valid,
    // 结果
    output reg  [31:0]  acc_out,
    output reg          acc_valid
);

    // ========================================================================
    // 状态机
    // ========================================================================
    localparam S_IDLE    = 3'd0;
    localparam S_FETCH   = 3'd1;   // 从存储预取到 FIFO
    localparam S_COMPUTE = 3'd2;   // FIFO→MAC 消费中
    localparam S_DONE    = 3'd3;

    reg [2:0]  state;
    reg [31:0] fetched_cnt;
    reg [31:0] consumed_cnt;
    reg        fetch_active;

    assign busy = (state != S_IDLE);
    assign done = (state == S_DONE);

    // ========================================================================
    // 预取 FIFO（NAND 和 MAC 之间的解耦）
    // ========================================================================
    localparam FIFO_DEPTH = 16;
    reg [31:0] pf_mem [0:FIFO_DEPTH-1];
    reg [$clog2(FIFO_DEPTH)-1:0] pf_wp, pf_rp;
    reg [$clog2(FIFO_DEPTH+1)-1:0] pf_count;

    wire fifo_empty = (pf_count == 0);
    wire fifo_full  = (pf_count >= FIFO_DEPTH);

    // NAND 写入 FIFO
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) pf_wp <= 0;
        else if (nand_rd_valid && !fifo_full) begin
            pf_mem[pf_wp] <= nand_rd_data;
            pf_wp <= pf_wp + 1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) pf_count <= 0;
        else case ({nand_rd_valid && !fifo_full, mac_consumed && !fifo_empty})
            2'b10: pf_count <= pf_count + 1;
            2'b01: pf_count <= pf_count - 1;
            2'b11: pf_count <= pf_count;
            default: ;
        endcase
    end

    // ========================================================================
    // MAC 消费逻辑（简化：从 FIFO 读出并累加）
    // ========================================================================
    reg mac_consumed;
    reg [31:0] running_acc;
    wire fifo_rp_next = (pf_rp == FIFO_DEPTH-1) ? 0 : pf_rp + 1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pf_rp       <= 0;
            running_acc <= 32'd0;
            mac_consumed<= 1'b0;
        end else if (!fifo_empty) begin
            running_acc <= running_acc ^ pf_mem[pf_rp]; // 简化消费：XOR
            pf_rp       <= fifo_rp_next;
            mac_consumed<= 1'b1;
        end else begin
            mac_consumed<= 1'b0;
        end
    end

    // ========================================================================
    // 主控制状态机
    // ========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            busy         <= 1'b0;
            done         <= 1'b0;
            fetched_cnt  <= 32'd0;
            consumed_cnt <= 32'd0;
            nand_rd_en   <= 1'b0;
            nand_rd_addr <= 32'd0;
            acc_out      <= 32'd0;
            acc_valid    <= 1'b0;
            fetch_active <= 1'b0;
        end else begin
            acc_valid <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (start) begin
                        state        <= S_FETCH;
                        busy         <= 1'b1;
                        done         <= 1'b0;
                        fetched_cnt  <= 32'd0;
                        consumed_cnt <= 32'd0;
                        fetch_active <= 1'b1;
                    end
                end

                S_FETCH: begin
                    if (!fifo_full && fetched_cnt < TOTAL_WEIGHTS) begin
                        nand_rd_en <= 1'b1;
                        nand_rd_addr <= nand_rd_addr + 4;
                        fetched_cnt <= fetched_cnt + 4;
                    end else begin
                        nand_rd_en <= 1'b0;
                    end

                    if (fetched_cnt >= TOTAL_WEIGHTS) begin
                        state <= S_COMPUTE;
                    end
                end

                S_COMPUTE: begin
                    if (!fifo_empty) begin
                        consumed_cnt <= consumed_cnt + 4;
                        running_acc  <= running_acc ^ pf_mem[fifo_rp_next];
                        if (consumed_cnt + 4 >= TOTAL_WEIGHTS) begin
                            state     <= S_DONE;
                            acc_out   <= running_acc ^ pf_mem[fifo_rp_next];
                            acc_valid <= 1'b1;
                            done      <= 1'b1;
                        end
                    end else if (fetched_cnt >= TOTAL_WEIGHTS) begin
                        state <= S_DONE;
                        acc_out <= running_acc;
                        acc_valid <= 1'b1;
                        done <= 1'b1;
                    end
                end

                S_DONE: begin
                    busy  <= 1'b0;
                    done  <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
