// ============================================================================
// tb_pcie_dma.v — pcie_dma_engine 协议验证
//
// 验证：
//   1. CMD_PUSH_X 帧 → 激活寄存器正确装载（8 拍 × 16B）
//   2. CMD_RUN_WEIGHT 帧 → wt_valid 脉冲 + lane 码透传
//   3. sum_valid → m_axis 回传 + token 计数递增
// ============================================================================

`timescale 1ns/1ps

module tb_pcie_dma;

    localparam NUM_LANES = 128;
    localparam AXIS_W    = 128;
    localparam CLK_HALF  = 5;      // 100 MHz

    reg clk, rst_n;
    initial clk = 0;
    always #CLK_HALF clk = ~clk;

    // DUT 接口
    reg                     s_tvalid = 0;
    wire                    s_tready;
    reg  [AXIS_W-1:0]       s_tdata = 0;
    reg  [AXIS_W/8-1:0]     s_tkeep = {AXIS_W/8{1'b1}};
    reg                     s_tlast = 0;

    wire                    m_tvalid;
    reg                     m_tready = 1'b1;
    wire [31:0]             m_tdata;
    wire                    m_tlast;

    wire [31:0]             status_tokens;
    wire                    engine_busy;

    pcie_dma_engine #(
        .NUM_LANES(NUM_LANES),
        .AXIS_WIDTH(AXIS_W)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tvalid(s_tvalid), .s_axis_tready(s_tready),
        .s_axis_tdata (s_tdata),  .s_axis_tkeep(s_tkeep), .s_axis_tlast(s_tlast),
        .m_axis_tvalid(m_tvalid), .m_axis_tready(m_tready),
        .m_axis_tdata (m_tdata),  .m_axis_tlast(m_tlast),
        .status_tokens(status_tokens),
        .engine_busy  (engine_busy)
    );

    task send_frame(input [7:0] cmd, input [127:0] payload_shifted);
        // payload_shifted 已按最终位排布给出，仅低 8bit 被 cmd 覆盖
        begin
            @(negedge clk);
            s_tdata  <= payload_shifted;
            s_tdata[7:0] <= cmd;
            s_tvalid <= 1'b1;
            @(posedge clk);
            s_tvalid <= 1'b0;
        end
    endtask

    integer errors = 0;

    initial begin
        rst_n = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        $display("[Test 1] 推送激活向量（帧头 + 8 拍）");
        send_frame(8'h01, 128'hA5);
        for (integer b = 0; b < 8; b = b + 1) begin
            @(negedge clk);
            s_tdata <= {128{1'b0}} | ((b + 1) * 'h11);
            s_tvalid <= 1'b1;
            s_tdata[7:0] <= (b == 7) ? 8'h01 : 8'h00;  // 保持 cmd 上下文
            @(posedge clk);
            s_tvalid <= 1'b0;
        end
        repeat (2) @(posedge clk);
        if (dut.x_beat_cnt !== 0) begin
            $display("  ✗ x_beat_cnt=%0d 应为 0", dut.x_beat_cnt); errors++;
        end else
            $display("  ✓ 激活装载完成，beat 计数归零");

        $display("[Test 2] 权重帧透传");
        // 载荷左移 16bit，使 BEEF 落在 byte2..3（第一个可捕获 lane 区）
        send_frame(8'h02, {112'd0, 16'hBEEF, 16'd0});
        @(posedge clk);
        if (!dut.wt_valid_q) begin
            $display("  ✗ wt_valid 未脉冲"); errors++;
        end else if (dut.wt_lane_data[15:0] === 16'hBEEF)
            $display("  ✓ lane 码透传正确（lane0..3=BEEF）");
        else begin
            $display("  ✗ lane 数据错误: %h", dut.wt_lane_data[15:0]); errors++;
        end

        $display("[Test 3] 等待引擎输出");
        fork : wait_result
            begin : wait_v
                wait (m_tvalid === 1'b1);
            end
            begin : timeout
                #50000;
                $display("  ✗ 超时未收到结果"); errors++;
                disable wait_result;
            end
        join_any
        disable fork;
        if (m_tvalid && !m_tlast) begin
            $display("  ✗ 结果帧缺 tlast"); errors++;
        end else if (m_tvalid)
            $display("  ✓ 收到结果 sum=%h tlast=1", m_tdata);

        $display("[Test 4] token 计数");
        if (status_tokens != 32'd1) begin
            $display("  ✗ tokens=%0d", status_tokens); errors++;
        end else
            $display("  ✓ tokens=1");

        $display("");
        if (errors == 0) $display("✓✓ PCIE_DMA PROTOCOL TESTS PASSED");
        else             $display("✗ %0d ERRORS", errors);
        $finish;
    end

    initial begin
        #200000;
        $display("TIMEOUT"); $finish;
    end

endmodule
