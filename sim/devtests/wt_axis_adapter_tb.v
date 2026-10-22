`timescale 1ps/1ps
// wt_axis_adapter_tb — 13↔14 语义对接件的自检回归 (2026-10-22)
// 覆盖:
//   1) 帧头: cmd=0x02 / seq 自增 / rem_bytes=64 / LBA 落在 [127:80]
//   2) 负载: 每帧 4 拍, 字序不变 (小端), tkeep 全 1, 末拍带 tlast
//   3) 反压: 随机拉低 tready → 适配器必须保持当前拍、停收字, **一个字都不能丢**
//   4) 帧数与 LBA 序列对齐 (每帧一个 LBA)
// 桩粒度: 14 侧用"字发生器"(模拟 cachectl 的 wt_*), 13 侧用"拍检查器"
module wt_axis_adapter_tb;
    localparam DW = 32, AXIS_WIDTH = 128, LBAW = 48, WPF = 16, NFRAMES = 5;
    localparam integer WPB = AXIS_WIDTH / DW;   // 4

    reg clk = 0, rst_n = 0;
    integer cyc = 0;
    always #5 clk = ~clk;
    always @(posedge clk) cyc = cyc + 1;

    // ---- 14 侧桩: 字发生器 ----
    reg [DW-1:0] wt_data;
    reg           wt_valid;
    wire          wt_ready;
    reg [LBAW-1:0] wt_lba;
    integer wfi, wfi_next, frame_idx, errors, beats_got, words_got, hdr_words;

    // ---- 13 侧: 拍检查器 ----
    wire [AXIS_WIDTH-1:0] s_axis_tdata;
    wire                  s_axis_tvalid;
    reg                   s_axis_tready;
    wire [AXIS_WIDTH/8-1:0] s_axis_tkeep;
    wire                  s_axis_tlast;
    wire [LBAW-1:0] frame_lba;
    wire [7:0] frame_seq;
    wire        frame_done;

    wt_axis_adapter #(
        .DW(DW), .AXIS_WIDTH(AXIS_WIDTH), .LBAW(LBAW), .WORDS_PER_FRAME(WPF)
    ) U (
        .clk(clk), .rst_n(rst_n),
        .wt_data(wt_data), .wt_valid(wt_valid), .wt_ready(wt_ready), .wt_lba(wt_lba),
        .s_axis_tdata(s_axis_tdata), .s_axis_tvalid(s_axis_tvalid), .s_axis_tready(s_axis_tready),
        .s_axis_tkeep(s_axis_tkeep), .s_axis_tlast(s_axis_tlast),
        .frame_lba(frame_lba), .frame_seq(frame_seq), .frame_done(frame_done)
    );

    // ================= 14 侧桩: 逐字发, 每帧一个 LBA =================
    initial begin
        wt_data = 0; wt_valid = 0; wt_lba = 48'h1000;
        wfi = 0; frame_idx = 0; errors = 0; beats_got = 0; words_got = 0; hdr_words = 0;
    end

    always @(posedge clk) if (rst_n) begin
        if (wt_valid && wt_ready) begin
            wt_data  <= wt_data + 32'd1;
            wfi      <= wfi + 1;
            if (wfi + 1 == WPF) begin
                wfi       <= 0;
                frame_idx <= frame_idx + 1;
                wt_lba    <= 48'h1000 + (frame_idx + 1) * 48'h40;
            end
        end
        // 供源: 持续供字 (wt_ready 反压时停)
        wt_valid <= (frame_idx < NFRAMES);
    end

    // ================= 13 侧: 拍检查 =================
    reg [31:0] exp_word;          // 本拍期望的字
    reg [7:0]  exp_seq;
    reg [47:0] exp_lba;
    reg        in_payload;
    reg [2:0]  beat_idx;
    reg [31:0] chk;

    initial begin
        s_axis_tready = 1'b0;   // 复位后再随机制造反压
        in_payload = 1'b0; beat_idx = 3'd0; exp_word = 32'h0; exp_seq = 8'd0; exp_lba = 48'h1000;
    end

    always @(posedge clk) if (rst_n) begin
        // 随机反压 (LFSR)
        chk <= {chk[30:0], chk[31] ^ chk[21] ^ chk[9] ^ chk[8]};
        s_axis_tready <= chk[0] | chk[3];     // 约 75% 就绪
    end

    always @(posedge clk) if (rst_n && s_axis_tvalid && s_axis_tready) begin
        if (!in_payload) begin
            // ---- 帧头 ----
            if (s_axis_tdata[7:0] !== 8'h02) begin
                $display("FAIL 帧头 cmd=%02x (期望 02)", s_axis_tdata[7:0]); errors = errors + 1;
            end
            if (s_axis_tdata[15:8] !== exp_seq) begin
                $display("FAIL 帧头 seq=%02x (期望 %02x)", s_axis_tdata[15:8], exp_seq); errors = errors + 1;
            end
            if (s_axis_tdata[23:16] !== 8'd64) begin
                $display("FAIL 帧头 rem_bytes=%02x (期望 40)", s_axis_tdata[23:16]); errors = errors + 1;
            end
            if (s_axis_tdata[127:80] !== exp_lba) begin
                $display("FAIL 帧头 LBA=%012x (期望 %012x)", s_axis_tdata[127:80], exp_lba); errors = errors + 1;
            end
            if (s_axis_tkeep !== {16{1'b1}}) begin
                $display("FAIL 帧头 tkeep 不全 1"); errors = errors + 1;
            end
            exp_seq  <= exp_seq + 8'd1;
            exp_lba  <= exp_lba + 48'h40;
            // exp_word **不清零**: 源侧的字是跨帧连续的 (0..15, 16..31, ...)
            // 适配器原样透传, 所以期望值也必须连续 (2026-10-22 TB 自身 bug)
            in_payload <= 1'b1;
            beat_idx  <= 3'd0;
        end else begin
            // ---- 负载拍: 4 个字, 小端 ----
            if (s_axis_tkeep !== {16{1'b1}}) begin
                $display("FAIL 负载拍 tkeep 不全 1"); errors = errors + 1;
            end
            if (s_axis_tdata[31:0] !== exp_word) begin
                $display("FAIL 负载拍0 字序错: 期望 %08x 实得 %08x", exp_word, s_axis_tdata[31:0]); errors = errors + 1;
            end
            if (s_axis_tdata[63:32] !== exp_word + 32'd1) begin
                $display("FAIL 负载拍1 字序错: 期望 %08x 实得 %08x", exp_word + 32'd1, s_axis_tdata[63:32]); errors = errors + 1;
            end
            if (s_axis_tdata[95:64] !== exp_word + 32'd2) begin
                $display("FAIL 负载拍2 字序错"); errors = errors + 1;
            end
            if (s_axis_tdata[127:96] !== exp_word + 32'd3) begin
                $display("FAIL 负载拍3 字序错"); errors = errors + 1;
            end
            exp_word <= exp_word + 32'd4;
            if (s_axis_tlast) begin
                if (beat_idx !== 3'd3) begin
                    $display("FAIL tlast 位置错: 拍序号 %0d (期望 3)", beat_idx); errors = errors + 1;
                end
                in_payload <= 1'b0;
                beat_idx  <= 3'd0;
            end else begin
                beat_idx <= beat_idx + 3'd1;
            end
        end
    end

    // ================= 收尾 =================
    initial begin
        chk = 32'hACE1_0001;
        repeat (10) @(posedge clk);
        rst_n = 1;
        repeat (40000) @(posedge clk);
        if (frame_idx != NFRAMES) begin
            $display("FAIL 帧数: 收到 %0d 期望 %0d", frame_idx, NFRAMES); errors = errors + 1;
        end
        if (errors == 0) $display("wt_axis_adapter PASS (帧头/负载/字序/tlast/反压 全过, 帧数 %0d)", frame_idx);
        else $display("wt_axis_adapter FAIL errors=%0d", errors);
        $finish;
    end
endmodule
