// ============================================================================
// tb_sat16.v — ACC_WIDTH=16 饱和累加器专项验证
//
// 验证：
//   1. 小负载（结果在 int16 内）→ 与精确参考一致
//   2. 大负载（超 int16）    → 钳位到 ±32767/-32768，不回绕
// ============================================================================

`timescale 1ns/1ps

module tb_sat16;

    localparam NUM_LANES = 128;
    localparam CLK_HALF  = 5;

    reg clk, rst_n;
    initial clk = 0;
    always #CLK_HALF clk = ~clk;

    reg                       wt_valid = 0;
    reg  [NUM_LANES*4-1:0]    wt_data  = 0;
    reg  [7:0]                wt_scale = 8'h40;
    reg  [NUM_LANES*8-1:0]    x_data   = 0;
    reg                       x_valid  = 0;
    reg                       acc_clr  = 1;
    reg                       acc_en   = 1;
    wire [NUM_LANES*16-1:0]   acc_out;
    wire                      acc_done;

    simd_mac_array #(
        .NUM_LANES(NUM_LANES),
        .ACC_WIDTH(16)
        // SATURATE 默认随 ACC_WIDTH=16 自动置 1
    ) dut (
        .clk(clk), .rst_n(rst_n), .en(1'b1),
        .wt_valid(wt_valid), .wt_data(wt_data), .wt_scale(wt_scale),
        .x_data(x_data), .x_valid(x_valid),
        .acc_clr(acc_clr), .acc_en(acc_en),
        .acc_out(acc_out), .acc_done(acc_done)
    );

    integer i, beat, errors = 0;

    task step(input [3:0] w, input [7:0] x);
        begin
            @(negedge clk);
            for (i = 0; i < NUM_LANES; i = i + 1) begin
                wt_data[i*4 +: 4] = w;
                x_data [i*8 +: 8] = x;
            end
            wt_valid = 1; x_valid = 1;
            @(posedge clk);
            #1;                      // 避免与 DUT 时钟沿读取竞争
            wt_valid = 0; x_valid = 0;
        end
    endtask

    initial begin
        rst_n = 0;
        repeat (4) @(posedge clk);
        acc_clr = 0;
        @(negedge clk); rst_n = 1;

        // ── Test A：小负载，全部 lane 同值，可精确预算 ──
        $display("[A] int16 内小负载");
        // 选 mag=4(k=4),x=+100 → 每拍积=2*4*100=800；8 拍=+6400 <32767 ✓
        for (beat = 0; beat < 8; beat = beat + 1) step(4'b0100, 8'd100);
        #1;
        for (i = 0; i < NUM_LANES; i = i + 1) begin
            if ($signed(acc_out[i*16 +: 16]) !== 16'sd6400) begin
                if (errors<3) $display(" ✗ lane%0d=%0d 应为6400",
                    i, $signed(acc_out[i*16 +: 16]));
                errors++;
            end
        end
        if (!errors) $display(" ✓ 全 lane 精确 = +6400");

        // ── Test B：正向溢出 → 钳 +32767 ──
        $display("[B] 正向饱和");
        // 续接上面：再打 40 拍 product=+800 → 无饱和会到 38400
        for (beat = 0; beat < 40; beat = beat + 1) step(4'b0100, 8'd100);
        #1;
        for (i = 0; i < NUM_LANES; i = i + 1) begin
            if ($signed(acc_out[i*16 +: 16]) !== 16'sd32767) begin
                if (errors<3) $display(" ✗ lane%0d=%0d 应钳32767",
                    i, $signed(acc_out[i*16 +: 16]));
                errors++;
            end
        end
        if ($signed(acc_out[15:0]) === 16'sd32767)
            $display(" ✓ 正向钳位 = +32767");

        // ── Test C：清零后负向，先精确后钳位 ──
        $display("[C] 负向：21 拍精确 → 第 22 拍起钳位");
        @(negedge clk); acc_clr = 1;
        @(posedge clk); #1;
        if (|acc_out) begin
            $display(" ✗ 清零后非零: %h", acc_out[31:16]); errors++;
        end
        acc_clr = 0;
        // mag=5(k=6), x=-128 → 每拍积 = -2*6*128 = -1536
        for (beat = 0; beat < 21; beat = beat + 1) step(4'b0101, 8'h80);
        #1;
        if ($signed(acc_out[31:16]) !== -16'sd32256) begin
            $display(" ✗ C1 预钳位值 %0d ≠ -32256",
                     $signed(acc_out[31:16])); errors++;
        end else
            $display(" ✓ C1 精确 = -32256");
        step(4'b0101, 8'h80);   // 第 22 拍触发钳位
        #1;
        if ($signed(acc_out[31:16]) !== -16'sd32768) begin
            $display(" ✗ C2 应钳-32768, 得 %0d",
                     $signed(acc_out[31:16])); errors++;
        end else
            $display(" ✓ C2 负向钳位 = -32768");

        $display("");
        if (errors == 0) $display("✓✓ SAT16 TESTS PASSED");
        else             $display("✗ %0d ERRORS", errors);
        $finish;
    end

    initial begin #500000; $display("TIMEOUT"); $finish; end

endmodule
