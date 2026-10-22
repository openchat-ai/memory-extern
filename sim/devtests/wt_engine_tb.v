`timescale 1ps/1ps
// wt_engine_tb — 13↔14 语义对接的**端到端**证明 (2026-10-22)
// 链路: 权重字流桩 (模拟 cachectl_pipeline 的 wt_*) → wt_axis_adapter
//       → 真 pcie_dma_engine (s_axis_*) → 结果流 (m_axis_*) + status_tokens
// 判据:
//   1) 引擎能收下适配器造的权重帧 (cmd=0x02) 并进入 SETTLE→累加
//   2) 引擎吐出结果 (m_axis_tvalid + tlast), status_tokens 递增
//   3) 帧里的 LBA 被适配器原样带上 (观测 frame_lba)
// 说明: 权重**内容**用的是替身格式 (cachectl 侧现在是 {tag,weight} 简化单字,
//       与引擎期望的 "128 lane × 4bit 码" 不同) —— 本 TB 只证明**帧/握手/时序**语义对上,
//       内容格式是下一阶段的课题 (见 rtl/14_serdes_proto/.../cachectl_pipeline.v 注释)。
module wt_engine_tb;
    localparam DW = 32, AXIS_WIDTH = 128, LBAW = 48, WPF = 16, NFRAMES = 4;
    localparam integer WPB = AXIS_WIDTH / DW;   // 4

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    // ---- 14 侧桩: 字流 ----
    reg [DW-1:0]  wt_data;
    reg            wt_valid;
    wire           wt_ready;
    reg [LBAW-1:0] wt_lba;
    integer wfi, frame_idx;

    // ---- 13 侧: 引擎 ----
    wire [AXIS_WIDTH-1:0] s_axis_tdata;
    wire                  s_axis_tvalid;
    wire                  s_axis_tready;
    wire [AXIS_WIDTH/8-1:0] s_axis_tkeep;
    wire                  s_axis_tlast;
    wire [LBAW-1:0] frame_lba;
    wire [7:0]  frame_seq;
    wire        frame_done;

    wire                  m_axis_tvalid;
    reg                   m_axis_tready;
    wire [31:0]           m_axis_tdata;
    wire                  m_axis_tlast;
    wire [31:0]           status_tokens;
    wire                  engine_busy;

    wt_axis_adapter #(
        .DW(DW), .AXIS_WIDTH(AXIS_WIDTH), .LBAW(LBAW), .WORDS_PER_FRAME(WPF)
    ) U_AD (
        .clk(clk), .rst_n(rst_n),
        .wt_data(wt_data), .wt_valid(wt_valid), .wt_ready(wt_ready), .wt_lba(wt_lba),
        .s_axis_tdata(s_axis_tdata), .s_axis_tvalid(s_axis_tvalid), .s_axis_tready(s_axis_tready),
        .s_axis_tkeep(s_axis_tkeep), .s_axis_tlast(s_axis_tlast),
        .frame_lba(frame_lba), .frame_seq(frame_seq), .frame_done(frame_done)
    );

    pcie_dma_engine #(
        .NUM_LANES(128), .ACC_WIDTH(32), .AXIS_WIDTH(AXIS_WIDTH)
    ) U_ENG (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tvalid(s_axis_tvalid), .s_axis_tready(s_axis_tready),
        .s_axis_tdata(s_axis_tdata), .s_axis_tkeep(s_axis_tkeep), .s_axis_tlast(s_axis_tlast),
        .m_axis_tvalid(m_axis_tvalid), .m_axis_tready(m_axis_tready),
        .m_axis_tdata(m_axis_tdata), .m_axis_tlast(m_axis_tlast),
        .status_tokens(status_tokens), .engine_busy(engine_busy)
    );

    // ---- 源: 连续供字, 每帧一个 LBA ----
    initial begin
        wt_data = 0; wt_valid = 0; wt_lba = 48'h1000;
        wfi = 0; frame_idx = 0; m_axis_tready = 1'b1;
    end
    always @(posedge clk) if (rst_n) begin
        if (wt_valid && wt_ready) begin
            wt_data <= wt_data + 32'd1;
            wfi     <= wfi + 1;
            if (wfi + 1 == WPF) begin
                wfi       <= 0;
                frame_idx <= frame_idx + 1;
                wt_lba    <= 48'h1000 + (frame_idx + 1) * 48'h40;
            end
        end
        wt_valid <= (frame_idx < NFRAMES);
    end

    // ---- 结果检查 ----
    integer res_cnt, errors, done_cnt;
    reg [47:0] exp_lba_chk;
    reg [31:0] tok0;
    initial begin res_cnt = 0; errors = 0; done_cnt = 0; tok0 = 32'hFFFF_FFFF; exp_lba_chk = 48'h1000; end

    always @(posedge clk) if (rst_n) begin
        if (frame_done) begin
            done_cnt = done_cnt + 1;
            if (frame_lba !== exp_lba_chk) begin
                $display("FAIL 帧 LBA 不对: %012x (期望 %012x)", frame_lba, exp_lba_chk); errors = errors + 1;
            end
            exp_lba_chk = exp_lba_chk + 48'h40;
        end
        if (m_axis_tvalid && m_axis_tready) begin
            res_cnt = res_cnt + 1;
            if (res_cnt == 1) tok0 = status_tokens;
            if (!m_axis_tlast) begin
                $display("FAIL 结果流 tlast 不在最后一拍"); errors = errors + 1;
            end
        end
    end

    initial begin
        repeat (10) @(posedge clk);
        rst_n = 1;
        repeat (200000) @(posedge clk);
        if (done_cnt < NFRAMES) begin
            $display("FAIL 帧数: 适配器出 %0d 帧 (期望 %0d)", done_cnt, NFRAMES); errors = errors + 1;
        end
        if (res_cnt == 0) begin
            $display("FAIL 引擎没吐出任何结果"); errors = errors + 1;
        end
        if (status_tokens == 32'd0) begin
            $display("FAIL status_tokens 没递增"); errors = errors + 1;
        end
        if (errors == 0)
            $display("wt_engine PASS (帧 %0d, 结果 %0d 拍, status_tokens=%0d)", done_cnt, res_cnt, status_tokens);
        else
            $display("wt_engine FAIL errors=%0d", errors);
        $finish;
    end
endmodule
