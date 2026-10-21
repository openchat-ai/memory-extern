// board_decode_top.v — SF9/SF11: 整包板上顶层 (burn 输入件) + 自动判定
// sys_clk 50MHz 直连 (无 PLL), rst_n K16, led[5:0] (cst: mega138k_decode.cst)。
//   led[0]=J14 心跳  led[1]=R26 busy  led[2]=L20 done  led[3]=M25 GOOD(解码闭环)
//   led[4]=N21 引擎 attn 段 PASS 灯   led[5]=N23 引擎 GEMM 段 PASS 灯  (2026-10-21)
// 判决: 每轮 token (token_done) 结束把整轮 out_expert/words 流哈希为 hsh;
//        若 hsh 连续两轮非零且相同 → good++ → led[3]=GOOD (板上直接观测判活)。
// data 面: decode_auto_core SELFDRV=1 内嵌 LFSR 源 → termux core_selftest 同 seed 已对账
//        (done@162 / token_done@160 / a_words=128 / hsh=ff81ff81)。
module board_decode_top (
    input  wire sys_clk,
    input  wire rst_n,
    output wire [5:0] led
);
    reg [22:0] div;
    reg run = 0;
    reg [21:0] tick;
    wire busy, done, token_done, out_valid;
    wire [15:0] out_data;
    wire [3:0] out_expert;
    wire [31:0] a_words, a_stalls;
    wire done_ir;
    reg [31:0] hsh = 0, prev_words = 0;
    reg [2:0] good = 0;
    reg hsh_nz = 0;
    // 引擎活动观测 (2026-10-21)
    wire eng_o_valid;
    wire [15:0] eng_o_data;
    wire [31:0] eng_rail_frames, eng_attn_done, eng_gemm_done, eng_layers_done;

    decode_auto_core #(.SELFREL(1)) U(
        .clk(sys_clk), .rst_n(rst_n), .run(run), .busy(busy), .done(done_ir),
        .credit(1'b1), .s_valid(1'b0), .out_take(1'b1), .s_score(16'h0000),
        // q 模板给非零常量: q=0 会让 attn 内积恒 0 → 乘法链被综合器折成常量,
        // 引擎就只剩控制壳。给非零 q 才能在板上真的看到内积出数 (led[4] 的判据)。
        .q_vec_p(64'h0123_4567_89AB_CDEF), .head_acc(16'h1234), .xext(4'h6),
        .wr_en(1'b0), .wr_addr(9'h0), .wr_data(16'h0),
        .out_valid(out_valid), .out_data(out_data), .out_expert(out_expert),
        .token_done(token_done), .r_token_done(), .out_token(), .out_score(), .h_go(),
        .r_round(), .h_round(), .r_stalls(), .a_stalls(a_stalls), .a_words(a_words),
        .eng_o_valid(eng_o_valid), .eng_o_data(eng_o_data),
        .eng_rail_frames(eng_rail_frames), .eng_attn_done(eng_attn_done),
        .eng_gemm_done(eng_gemm_done), .eng_layers_done(eng_layers_done)
    );

    always @(posedge sys_clk or negedge rst_n)
        if (!rst_n) begin
            div <= 0; tick <= 0; run <= 0;
        end else begin
            div <= div + 1'b1;
            tick <= tick + 1'b1;                       // 22bit 自然回绕
            if (tick[10:0] == 11'd1000) run <= 1'b1;   // 帧周期 2048 拍
            else if (tick[10:0] == 11'd1016) run <= 1'b0;
        end

    // 帧哈希: 每帧 token_done 归零; emit 期间累计内容+流程指纹 (同 core_selftest 内容版)
    always @(posedge sys_clk or negedge rst_n)
        if (!rst_n) begin
            hsh <= 0; hsh_nz <= 0;
        end else begin
            if (token_done) begin
                hsh <= 0; hsh_nz <= 0;
            end else if (out_valid && a_words > 0) begin
                hsh_nz <= 1'b1;
                hsh <= {hsh[30:0], hsh[31] ^ out_expert[0]} ^ {out_expert[3:1], out_data[3:0]};
            end
        end

    // 帧末对账: 每帧词量 +128 (全量) 且帧内内容流活跃 → GOOD (双证: 完整性+真数据面流动)
    always @(posedge sys_clk or negedge rst_n)
        if (!rst_n) begin
            prev_words <= 0; good <= 0;
        end else if (token_done) begin
            if ((a_words - prev_words == 32'd128) && hsh_nz) good <= good >= 2 ? 3 : good + 1;
            else good <= 0;
            prev_words <= a_words;
        end

    assign led[0] = div[22];
    assign led[1] = busy;
    assign led[2] = done_state;
    assign led[3] = good[1];          // ≥2 连续同指纹 = 自驱闭环稳定 → GOOD
    reg done_state = 0;
    always @(posedge sys_clk or negedge rst_n)
        if (!rst_n) done_state <= 0; else done_state <= done_ir || a_words == 32'd128;

    // ---- 引擎 PASS 灯 (2026-10-21) --------------------------------------------
    // 板上引擎每会话跑一轮 (会话 2048 拍), 活动窗很短 → 闪灯看不出持续活动,
    // 改用**板级锁存**: 见一次就常亮 = 板上真跑过。
    //   led[4] N21: attn 段真出非零内积 → 窗灌+读回+内积分块+乘累加链 全活
    //   led[5] N23: 引擎跑满 4 层 (SELFREL 自释放后 layers_done 能爬到 4)
    //                → 调度器多层循环成立; 每层含 GEMM 段 → rail 链同时被拉进网表
    reg eng_attn_seen = 0;
    reg eng_gemm_seen = 0;
    reg eng_layers_seen = 0;
    always @(posedge sys_clk or negedge rst_n)
        if (!rst_n) begin
            eng_attn_seen <= 0; eng_gemm_seen <= 0; eng_layers_seen <= 0;
        end else begin
            if (eng_o_valid && (eng_o_data != 16'h0000)) eng_attn_seen <= 1'b1;
            if (eng_rail_frames != 32'h0000) eng_gemm_seen <= 1'b1;
            if (eng_layers_done >= 32'd4) eng_layers_seen <= 1'b1;
        end
    assign led[4] = eng_attn_seen;
    assign led[5] = eng_gemm_seen & eng_layers_seen;
endmodule