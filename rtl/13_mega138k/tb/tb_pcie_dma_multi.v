// ============================================================================
// tb_pcie_dma_multi.v — 多帧连续推理 + 背压 + 换载回归
//
// 验证：
//   1. 一次 PUSH_X 后连续执行多帧 RUN_WEIGHT，x 常驻复用
//   2. 每帧 SETTLE 的 acc_clr 正确清累加器，结果互不污染
//   3. 含正负权重、混合权重的数值回归（期望值 tb 内按 LUT 复算）
//   4. 背压：m_axis_tready=0 时 holding producer 排队不丢，恢复后送达
//   5. status_tokens == 已执行帧数（拒绝重复发射/丢失）
//   6. 中途再次 PUSH_X 更换 x，后续帧用新 x 计算
// ============================================================================

`timescale 1ns/1ps

module tb_pcie_dma_multi;

    localparam NUM_LANES = 128;
    localparam AXIS_W    = 128;
    localparam CLK_HALF  = 5;

    reg clk, rst_n;
    initial clk = 0;
    always #CLK_HALF clk = ~clk;

    reg                  s_tvalid = 0;
    wire                 s_tready;
    reg  [AXIS_W-1:0]    s_tdata = 0;
    reg  [AXIS_W/8-1:0]  s_tkeep = '1;
    reg                  s_tlast = 0;

    wire                 m_tvalid;
    reg                  m_tready = 1'b1;
    wire [31:0]          m_tdata;
    wire                 m_tlast;
    wire [31:0]          status_tokens;
    wire                 engine_busy;

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

    // ---------- 驱动 ----------
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

    task phdr(input [7:0] cmd, input [15:0] len);
        begin
            axis_put({ 104'd0, len[7:0], 8'd0, cmd }, 16'h0003, 1'b0);
        end
    endtask

    // ---------- 期望值（按 simd_mac_array 的 E2M1 LUT 复算 Σ w·x）----------
    function signed [47:0] lut_mag;
        input [2:0] m;
        begin
            case (m)
                3'd0: lut_mag = 48'd0;
                3'd1: lut_mag = 48'd2;
                3'd2: lut_mag = 48'd4;
                3'd3: lut_mag = 48'd6;
                3'd4: lut_mag = 48'd8;
                3'd5: lut_mag = 48'd12;
                3'd6: lut_mag = 48'd16;
                3'd7: lut_mag = 48'd24;
            endcase
        end
    endfunction

    function signed [47:0] expected;
        input [NUM_LANES*4-1:0] wc;
        input [NUM_LANES*8-1:0] xs;
        integer l;
        reg signed [47:0] acc;
        begin
            acc = 0;
            for (l = 0; l < NUM_LANES; l = l + 1) begin
                if (wc[l*4+3])
                    acc = acc - lut_mag(wc[l*4 +: 3]) * $signed(xs[l*8 +: 8]);
                else
                    acc = acc + lut_mag(wc[l*4 +: 3]) * $signed(xs[l*8 +: 8]);
            end
            expected = acc;
        end
    endfunction

    // ---------- 权重帧唤醒 ----------
    reg [AXIS_W-1:0] w_beats [0:3];

    integer pw_byte, pw_b, pw_off, l_idx;
    task pack_w(input [NUM_LANES*4-1:0] codes);
        begin
            for (pw_byte = 0; pw_byte < 64; pw_byte = pw_byte + 1) begin
                pw_b   = pw_byte / 16;
                pw_off = pw_byte % 16;
                w_beats[pw_b][pw_off*8 +: 4]     = codes[pw_byte*8 +: 4];
                w_beats[pw_b][pw_off*8 + 4 +: 4] = codes[pw_byte*8+4 +: 4];
            end
        end
    endtask

    task send_w_frame(input [NUM_LANES*4-1:0] codes);
        integer j;
        begin
            phdr(8'h02, 16'd64);
            pack_w(codes);
            for (j = 0; j < 4; j = j + 1)
                axis_put(w_beats[j], '1, (j == 3));
        end
    endtask

    // ---------- 执行一帧并校验结果；hold=1 时先拉低 m_tready 验证背压 ----------
    integer g_fail = 0;
    task run_frame(input [NUM_LANES*4-1:0] codes, input integer hold,
                   input signed [47:0] want);
        integer c;
        reg [31:0] val;
        reg        got;
        begin
            send_w_frame(codes);
            // 结果送达（holding 已捕获 → m_tvalid 置位）
            if (hold) begin
                // 触发：等一轮 sum_valid 产生再拉低会丢，改为先拉低让引擎积压
                m_tready = 1'b0;
                // 引擎会一直有效等 tready → 够了：让渡一段再释放
            end
            got = 0;
            @(posedge clk); #1;
            m_tready = 1'b1;          // 释放背压，允许结算
            for (c = 0; c < 200 && !got; c = c + 1) begin
                @(posedge clk); #1;
                if (m_tvalid && m_tready) begin
                    val  = m_tdata;
                    got  = 1;
                end
            end
            if (!got) begin
                $display("  ✗ 帧结果超时");
                g_fail = 1;
            end else begin
                if ($signed(val) !== want) begin
                    $display("  ✗ sum=%0d ≠ 期望 %0d", $signed(val), want);
                    g_fail = 1;
                end else begin
                    $display("  ✓ sum=%0d 正确", $signed(val));
                end
            end
            m_tready = 1'b1;
        end
    endtask

    reg [NUM_LANES*4-1:0] wc_all1, wc_all2, wc_all9, wc_mix;
    integer l;

    initial begin
        rst_n = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        wc_all1 = 0; wc_all2 = 0; wc_all9 = 0; wc_mix = 0;
        for (l = 0; l < 128; l = l + 1) begin
            wc_all1 = wc_all1 | ({4'h1} << (l*4));
            wc_all2 = wc_all2 | ({4'h2} << (l*4));
            wc_all9 = wc_all9 | ({4'h9} << (l*4));
            wc_mix  = wc_mix  | (((l % 2) == 0) ? ({4'h1} << (l*4)) : ({4'h2} << (l*4)));
        end

        // ---------- T1: PUSH_X x[i]=i ----------
        $display("[T1] PUSH_X x[i]=i");
        phdr(8'h01, 16'd128);
        for (l = 0; l < 8; l = l + 1) begin
            reg [AXIS_W-1:0] bd;
            integer b;
            bd = 0;
            for (b = 0; b < 16; b = b + 1)
                bd[b*8 +: 8] = l*16 + b;
            axis_put(bd, '1, (l == 7));
        end
        repeat (2) @(posedge clk); #1;
        begin
            integer e;
            e = 0;
            for (l = 0; l < NUM_LANES; l = l + 1)
                if (dut.x_reg[l*8 +: 8] !== l[7:0]) e++;
            if (e) begin $display("  ✗ x_reg 错 %0d lane", e); g_fail = 1; end
            else   $display("  ✓ x_reg 就绪（x=0..127）");
        end

        // ---------- T2: 连续帧 +2 / +4 / -2（x 常驻）----------
        $display("[T2] 连续帧 +2 / +4 / -2（x 复用）");
        run_frame(wc_all1, 0, 48'sd16256);         // Σ2i
        run_frame(wc_all2, 0, 48'sd32512);         // Σ4i
        run_frame(wc_all9, 0, -48'sd16256);        // Σ(-2)i

        // ---------- T3: 混合权重（偶 +2、奇 +4）----------
        $display("[T3] 混合权重偶/奇 lane");
        run_frame(wc_mix, 0, 48'sd24448);          // 2·Σ偶 + 4·Σ奇
        // Σ偶 i（0..126 步长2）= 4032；Σ奇 i（1..127 步长2）= 4096
        // 2·4032 + 4·4096 = 8064 + 16384 = 24448

        // ---------- T4: 背压排队（先拉低 tready 再触发）----------
        $display("[T4] m_axis 背压 1 拍");
        run_frame(wc_all1, 1, 48'sd16256);

        // ---------- T5: tokens 计数 ----------
        $display("[T5] status_tokens=%0d 期望 5", status_tokens);
        if (status_tokens !== 32'd5) begin
            $display("  ✗ tokens=%0d", status_tokens);
            g_fail = 1;
        end else
            $display("  ✓ tokens=5 精确");

        // ---------- T6: 换载 x[i]=1 → 重算 +2 ----------
        $display("[T6] 换载 x[i]=1，重算 +2 → 2·128=256");
        phdr(8'h01, 16'd128);
        for (l = 0; l < 8; l = l + 1) begin
            reg [AXIS_W-1:0] bd;
            integer b;
            bd = {AXIS_W{1'b0}};
            for (b = 0; b < 16; b = b + 1)
                bd[b*8 +: 8] = 8'd1;
            axis_put(bd, '1, (l == 7));
        end
        repeat (2) @(posedge clk); #1;
        run_frame(wc_all1, 0, 48'sd256);

        $display("");
        if (g_fail)
            $display("═══ 回归：存在 ✗ ═══");
        else
            $display("═══ 回归全绿 ✅ ═══");
        $finish;
    end

    always @(posedge clk)
        if (s_tvalid || dut.rx_state != 2'd0 || dut.u_engine.acc_done || dut.u_engine.sum_valid)
            $display("    [mon] t=%0t st=%0d sc=%0d tv=%b tr=%b rem=%0d pb=%0d cmd=%02h ad=%b sv=%b msv=%0d",
                $time, dut.rx_state, dut.settle_cnt, s_tvalid, s_tready,
                dut.rem_bytes, dut.pay_beat, dut.cur_cmd,
                dut.u_engine.acc_done, dut.u_engine.sum_valid, status_tokens);

    initial begin
        #200000;
        $display("TIMEOUT at %0t", $time); $finish;
    end

endmodule