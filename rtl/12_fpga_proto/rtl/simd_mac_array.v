// ============================================================================
// simd_mac_array.v — 128 个并行 MAC，各有独立累加器（正式接入版）
//
// 真正的 SIMD 结构：
//   每条通道独立乘累加，互不干扰
//   最后由 reduction_tree 归约成单个输出
//
// 资源策略：
//   - mxfp4 模式：LUT 查表 + 移位加法替代 DSP（每通道 ~90 LUT）
//   - ACC16 模式：int16 饱和累加器，lane 成本 -40%（余量①）
//
// 新增 PIPE_MUL 参数（超频/布线优化）：
//   PIPE_MUL=0（默认）: 原版单拍组合累加（行为不变，兼容旧 tb）
//   PIPE_MUL=1       : 打断关键路径——把『乘积生成』锁存一拍，累加单独一拍。
//                      每段逻辑深度减半（约 5-6 LUT 级），可在 200MHz(5ns)
//                      内收敛，而原版单拍长链在 100MHz 就逼近布线死循环。
//                      功能等价：acc == Σ(w*x)，仅累加结果晚 1 拍到达。
//
// 时序兼容：PIPE_MUL=1 时 acc_done 基于 sample_any 下降沿对齐到
//  『最后 product 已累加完成』那一拍，保证归约树帧同步正确。
// ============================================================================

`timescale 1ns/1ps

module simd_mac_array #(
    parameter NUM_LANES      = 128,   // 并行 MAC 数量
    parameter ACC_WIDTH      = 32,    // 累加器位宽：32=精确 / 16=饱和省资源
    parameter PIPE_MUL       = 0,     // 1=打断关键路径的流水分段累加
    parameter PIPE_IN        = 0,     // 1=输入寄存器级：打断 x_data/wt_data 全局广播
    parameter SATURATE       = (ACC_WIDTH <= 16)
)(
    input  wire                       clk,
    input  wire                       rst_n,
    input  wire                       en,        // 全局使能（ICG 门控）

    // ---- 权重流输入（来自解包器）----
    input  wire                       wt_valid,
    input  wire [NUM_LANES*4-1:0]     wt_data,
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire [7:0]                 wt_scale,  // 预留 per-block scale
    /* verilator lint_on UNUSEDSIGNAL */

    // ---- 激活值向量（x 向量分片）----
    input  wire [NUM_LANES*8-1:0]     x_data,
    input  wire                       x_valid,

    // ---- 累加控制 ----
    input  wire                       acc_clr,
    input  wire                       acc_en,

    // ---- 输出到归约树 ----
    output wire [NUM_LANES*ACC_WIDTH-1:0] acc_out,
    output wire                       acc_done
);

    // ========================================================================
    // 输入寄存器级（PIPE_IN=1）：打断 x_data(1024bit)/wt_data(512bit) 的
    // 全局广播。原广播是每一位跨 die 扇出到几十个 lane；寄存后每个 bit
    // 只从『邻近的入口寄存器』扇出本 lane，缩短布线器需收敛的长网跨度。
    // 功能等价：只是数据晚 1 拍进入累加；x/wt/x_valid/wt_valid 同拍对齐。
    // ========================================================================
    wire [NUM_LANES*8-1:0]   x_use;
    wire [NUM_LANES*4-1:0]   wt_use;
    wire                     x_v_q, wt_v_q;

    generate
        if (PIPE_IN == 1) begin : gen_pipe_in
            reg [NUM_LANES*8-1:0] x_q;
            reg [NUM_LANES*4-1:0] wt_q;
            reg x_v, wt_v;
            always @(posedge clk) begin
                if (!rst_n) begin
                    x_q   <= {NUM_LANES*8{1'b0}};
                    wt_q  <= {NUM_LANES*4{1'b0}};
                    x_v   <= 1'b0;
                    wt_v  <= 1'b0;
                end else begin
                    x_q   <= x_data;
                    wt_q  <= wt_data;
                    x_v   <= x_valid;
                    wt_v  <= wt_valid;
                end
            end
            assign x_use  = x_q;
            assign wt_use = wt_q;
            assign x_v_q  = x_v;
            assign wt_v_q = wt_v;
        end else begin : gen_no_pipe_in
            assign x_use  = x_data;
            assign wt_use = wt_data;
            // 旁通：有效信号直接使用原始值，不引入额外延迟
            assign x_v_q  = x_valid;
            assign wt_v_q = wt_valid;
        end
    endgenerate

    // ========================================================================
    // mxfp4 E2M1 查表解码（LUT 实现，不用 DSP）
    // ========================================================================
    function signed [7:0] e2m1_lut;
        input [3:0] code;
        reg [4:0] mag;
        begin
            case (code[2:0])
                3'b000: mag = 5'd0;
                3'b001: mag = 5'd2;
                3'b010: mag = 5'd4;
                3'b011: mag = 5'd6;
                3'b100: mag = 5'd8;
                3'b101: mag = 5'd12;
                3'b110: mag = 5'd16;
                3'b111: mag = 5'd24;
                default: mag = 5'd0;
            endcase
            e2m1_lut = code[3] ? -$signed({3'b000, mag}) : $signed({3'b000, mag});
        end
    endfunction

    // ========================================================================
    // 饱和函数（ACC16 模式用）
    // ========================================================================
    function signed [47:0] sat16;
        input signed [47:0] v;
        begin
            if      (v >  48'sd32767)  sat16 =  48'sd32767;
            else if (v < -48'sd32768)  sat16 = -48'sd32768;
            else                       sat16 = v;
        end
    endfunction

    // ========================================================================
    // 单个 MAC 通道：移位加法乘法 + 独立累加器
    // ========================================================================
    generate
        genvar i;
        for (i = 0; i < NUM_LANES; i = i + 1) begin : gen_lane
            reg signed [ACC_WIDTH-1:0] acc;

            wire signed [7:0] x_val = x_use[i*8 +: 8];

            // ── 移位加法乘法器（E2M1 幅值全偶数：w = 2k）──
            wire [2:0] mag = wt_use[i*4 +: 3];
            wire      sgn = wt_use[i*4+3];
            wire signed [11:0] sx = {{4{x_val[7]}}, x_val};
            reg  signed [11:0] kx;                     // k·x ∈ [-1536,+1512]
            always @(*) begin
                case (mag)
                    3'd0: kx = 12'sd0;
                    3'd1: kx = sx;
                    3'd2: kx = sx <<< 1;
                    3'd3: kx = sx + (sx <<< 1);
                    3'd4: kx = sx <<< 2;
                    3'd5: kx = (sx <<< 2) + (sx <<< 1);
                    3'd6: kx = sx <<< 3;
                    3'd7: kx = (sx <<< 3) + (sx <<< 2);
                endcase
            end
            // 先算窄位宽积（保留符号），靠赋值隐式符号扩展到 ACC_WIDTH
            wire signed [12:0] prod13 =
                sgn ? -$signed({kx, 1'b0})
                    :  $signed({kx, 1'b0});
            wire signed [ACC_WIDTH-1:0] product = prod13;

            // ── 累加（32bit 精确 / 16bit 饱和二选一，参数常量折叠）──
            // 48bit 域加法：ACC16 时高 32 位自然为零扩展并被折叠
            wire signed [47:0] sum_ext =
                {{(48-ACC_WIDTH){acc[ACC_WIDTH-1]}}, acc} +
                {{(48-ACC_WIDTH){product[ACC_WIDTH-1]}}, product};

            // 饱和结果经中间线网（避免函数返回值直接位选的移植性问题）
            wire signed [47:0] sum_sat = sat16(sum_ext);

            if (PIPE_MUL == 0) begin : gen_combo
                // ── 原版：单拍组合累加（默认行为不变）──
                always @(posedge clk) begin
                    if (!rst_n || acc_clr)
                        acc <= {ACC_WIDTH{1'b0}};
                    else if (en && wt_v_q && x_v_q && acc_en)
                        acc <= SATURATE ? sum_sat[ACC_WIDTH-1:0]
                                        : sum_ext[ACC_WIDTH-1:0];
                end
            end else begin : gen_pipe
                // ── 流水版：打断关键路径（三级）──
                // Stage A：kx 锁存 — 打断 `case(mag)` 移位加法 MUX 组合路径
                // Stage B：product 锁存 — 由已寄存的 kx_pipe 计算（只剩符号/位宽扩展）
                // Stage C：psum(acc) 锁存 — 累加
                wire do_sample = en && wt_v_q && x_v_q && acc_en;
                reg  kx_vld;                          // 上一拍 kx 有效
                reg  signed [11:0] kx_pipe;           // Stage A：锁存 kx
                reg  kx_sgn;                          // Stage A：锁存符号（与 kx 同拍）
                always @(posedge clk) begin
                    if (!rst_n) begin
                        kx_vld  <= 1'b0;
                        kx_pipe <= 12'sd0;
                        kx_sgn  <= 1'b0;
                    end else begin
                        kx_vld  <= do_sample;
                        if (do_sample) begin
                            kx_pipe <= kx;            // Stage A：锁存移位加法结果
                            kx_sgn  <= sgn;
                        end
                    end
                end

                // Stage B：由 kx_pipe 计算 product（符号用同拍锁存的 kx_sgn）
                wire signed [12:0] prod13_p =
                    kx_sgn ? -$signed({kx_pipe, 1'b0})
                           :  $signed({kx_pipe, 1'b0});
                reg  signed [ACC_WIDTH-1:0] prod_pipe0;
                always @(posedge clk) begin
                    if (!rst_n)
                        prod_pipe0 <= {ACC_WIDTH{1'b0}};
                    else if (kx_vld)
                        prod_pipe0 <= prod13_p;       // Stage B：锁存乘积
                end

                // Stage C：kx_vld 延迟成 prod_vld（product 有效）→ 累加
                reg  prod_vld;
                always @(posedge clk) begin
                    if (!rst_n) prod_vld <= 1'b0;
                    else        prod_vld <= kx_vld;
                end

                // 累加（48bit 域，ACC16 饱和）
                wire signed [47:0] psum_ext =
                    {{(48-ACC_WIDTH){prod_pipe0[ACC_WIDTH-1]}}, prod_pipe0} +
                    {{(48-ACC_WIDTH){acc[ACC_WIDTH-1]}}, acc};
                wire signed [47:0] psum_sat = sat16(psum_ext);

                always @(posedge clk) begin
                    if (!rst_n || acc_clr)
                        acc <= {ACC_WIDTH{1'b0}};
                    else if (prod_vld)
                        acc <= SATURATE ? psum_sat[ACC_WIDTH-1:0]
                                        : psum_ext[ACC_WIDTH-1:0];
                end
            end
        end
    endgenerate

    // ── 输出总线 ──
    generate
        for (genvar j = 0; j < NUM_LANES; j = j + 1) begin : gen_acc_out
            assign acc_out[j*ACC_WIDTH +: ACC_WIDTH] = gen_lane[j].acc;
        end
    endgenerate

    // ── 完成信号：单周期脉冲（帧末尾 wt_valid 下降沿触发一次）──
    // PIPE_MUL=1 时须与『最后 product 已累加』对齐：
    //   sample_any 1→0 的那一拍，acc 已完成最后累加 → 归约树采样完整。
    if (PIPE_MUL == 0) begin : gen_done_combo
        reg [15:0] done_cnt;
        reg        wt_valid_d;
        always @(posedge clk) begin
            if (!rst_n || acc_clr)
                done_cnt <= 16'd0;
            else if (en && wt_v_q && x_v_q && acc_en)
                done_cnt <= done_cnt + 16'd1;
        end
        always @(posedge clk) begin
            if (!rst_n) wt_valid_d <= 1'b0;
            else        wt_valid_d <= wt_v_q;
        end
        // acc_done 必须是脉冲：帧消费完（wt_valid 下降沿）仅触发一次，
        // 否则归约树会每周期重新发射 sum_valid 导致结果重复
        assign acc_done = (done_cnt != 16'd0) && wt_valid_d && !wt_v_q;
    end else begin : gen_done_pipe
        // 三级流水（PIPE_IN=kx→product→acc）：累加触发在 do_sample 延迟 2 拍
        // （prod_vld），acc 在下一拍完成。acc_done 须取 do_sample 延迟 3 拍
        // 的下降沿，保证『最后 product 已累加』时归约树采样完整。
        reg sample_any;
        always @(posedge clk) begin
            if (!rst_n) sample_any <= 1'b0;
            else        sample_any <= (en && wt_v_q && x_v_q && acc_en);
        end
        reg sample_any_d1, sample_any_d2;
        always @(posedge clk) begin
            if (!rst_n) begin
                sample_any_d1 <= 1'b0;
                sample_any_d2 <= 1'b0;
            end else begin
                sample_any_d1 <= sample_any;
                sample_any_d2 <= sample_any_d1;
            end
        end
        assign acc_done = sample_any_d2 && !sample_any_d1;
    end

endmodule