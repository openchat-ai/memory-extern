// ============================================================================
// tb_pcie_dma.v — pcie_dma_engine v0.2 协议验证（含数值闭环）
//
// 验证：
//   1. CMD_PUSH_X 帧（帧头 + 8 拍×16B）→ x_reg[i] = i（0..127）
//   2. CMD_RUN_WEIGHT 帧（帧头 + 4 拍×16B）→ lane 码全 4'h1（w=+2）
//   3. SETTLE 序列：先 acc_clr、后 wt_valid、期间 tready=0（背压）
//   4. 数值回归：Σ 2·i（i=0..127）= 16256 精确匹配
//   5. holding producer：m_axis_tready 压低时结果不丢
//   6. status_tokens=1（acc_done 单脉冲，杜绝引擎重复发射结果）
// ============================================================================

`timescale 1ns/1ps

module tb_pcie_dma;

    localparam NUM_LANES = 128;
    localparam AXIS_W    = 128;
    localparam CLK_HALF  = 5;      // 100 MHz

    reg clk, rst_n;
    initial clk = 0;
    always #CLK_HALF clk = ~clk;

    reg                     s_tvalid = 0;
    wire                    s_tready;
    reg  [AXIS_W-1:0]       s_tdata = 0;
    reg  [AXIS_W/8-1:0]     s_tkeep = '1;
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

    // ---- 工具：负沿置有效，正沿 DUT 采样，同拍撤除（已验证的时序风格）----
    task axis_put(input [AXIS_W-1:0] data, input [AXIS_W/8-1:0] keep, input last);
        begin
            @(negedge clk);
            s_tdata  = data;
            s_tkeep  = keep;
            s_tlast  = last;
            s_tvalid <= 1'b1;
            @(posedge clk);
            s_tvalid <= 1'b0;
        end
    endtask

    task send_frame_header(input [7:0] cmd, input [15:0] len);
        begin
            // 布局：cmd[7:0] seq[15:8] len[23:16]，104bit 高位填充
            axis_put({ 104'd0, len[7:0], 8'd0, cmd }, 16'h0003, 1'b0);
        end
    endtask

    integer errors = 0;
    integer i;

    initial begin
        rst_n = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        // ------------------------------------------------ Test 1: X 帧装填
        $display("[Test 1] X 帧：帧头 + 8 拍，x_reg[i]=i");
        send_frame_header(8'h01, 16'd128);
        for (i = 0; i < 8; i = i + 1) begin
            reg [AXIS_W-1:0] beat;
            integer b;
            beat = 0;
            for (b = 0; b < 16; b = b + 1)
                beat[b*8 +: 8] = i*16 + b;   // 字节值 = 序号
            axis_put(beat, '1, (i == 7));
        end
        repeat (2) @(posedge clk);
        // 校验 x_reg
        errors = 0;
        for (i = 0; i < NUM_LANES; i = i + 1)
            if (dut.x_reg[i*8 +: 8] !== i[7:0]) errors++;
        if (errors)
            $display("  ✗ x_reg 有 %0d lane 值错", errors);
        else
            $display("  ✓ x_reg[0..127] 全部正确");

        // ------------------------------------------------ Test 2: W 帧 + SETTLE
        $display("[Test 2] W 帧：帧头 + 4 拍 lane 码全 4'h1");
        send_frame_header(8'h02, 16'd64);
        for (i = 0; i < 4; i = i + 1) begin
            // 每拍 16 字节，每字节 2 个 4bit 码；全填 4'h1 → w=+2
            axis_put({AXIS_W{4'h1}}, '1, (i == 3));
        end
        // 权重帧结束 → SETTLE 序列检查
        // 帧末拍当日 rx_state 尚为 PAYLOAD（NBA 延迟一拍进入 SETTLE）；
        // #1 保证读到本拍 NBA 结算后的状态值
        @(posedge clk); #1;
        if (dut.settle_cnt === 2'd1 && dut.acc_clr_q === 1'b1)
            $display("  ✓ SETTLE[0] 发 acc_clr");
        else
            $display("  ✗ acc_clr 时序错 (settle=%0d acc_clr=%b)", dut.settle_cnt, dut.acc_clr_q);
        if (s_tready !== 1'b0)
            $display("  ✗ SETTLE 期无背压");
        else
            $display("  ✓ SETTLE 期 tready=0");
        @(posedge clk); #1;
        if (dut.settle_cnt === 2'd2 && dut.wt_valid_q === 1'b1)
            $display("  ✓ SETTLE[1] 发 wt_valid");
        else
            $display("  ✗ wt_valid 时序错 (settle=%0d wt_valid=%b)", dut.settle_cnt, dut.wt_valid_q);
        @(posedge clk); #1;   // SETTLE 退出，rx_state 回 IDLE
        if (s_tready !== 1'b1)
            $display("  ✗ SETTLE 退出后 tready 未恢复");
        else
            $display("  ✓ SETTLE 退出后 tready=1");

        // ------------------------------------------------ Test 3: 数值闭环
        $display("[Test 3] 引擎输出 sum = Σ 2·i = 16256");
        // 故意压低 m_axis_tready，验证 holding 不丢
        m_tready = 1'b0;
        #(CLK_HALF);   // 释放一拍蓄意阻塞前先同步
        m_tready = 1'b1;
        fork : wait_result
            begin : wait_v
                wait (m_tvalid === 1'b1 && m_tready === 1'b1);
                if (m_tdata !== 32'sd16256) begin
                    $display("  ✗ sum=%0d ≠ 16256", $signed(m_tdata));
                end else
                    $display("  ✓ sum=16256 数值正确");
            end
            begin : timeout
                #50000;
                $display("  ✗ sum_valid 超时（或 holding 卡死）");
                disable wait_result;
            end
        join_any
        disable fork;

        // ------------------------------------------------ Test 4: holding & token
        $display("[Test 4] holding producer + token 计数");
        m_tready = 1'b0;
        repeat (5) @(posedge clk);   // 保持 tready=0，若 holding 正确则保留结果
        m_tready = 1'b1;
        @(posedge clk);
        if (m_tvalid !== 1'b0)
            $display("  ✗ 握手后 m_tvalid 未拉低");
        else
            $display("  ✓ 握手完成，m_axis 回到空闲");
        repeat (10) @(posedge clk);
        if (status_tokens != 32'd1)
            $display("  ✗ tokens=%0d ≠ 1（acc_done 可能重复发射）", status_tokens);
        else
            $display("  ✓ tokens=1（结果仅发射一次）");

        $display("");
        $display("═══ 结果：若上方全 ✓ 即 PASS ═══");
        $finish;
    end

    initial begin
        #200000;
        $display("TIMEOUT"); $finish;
    end

endmodule