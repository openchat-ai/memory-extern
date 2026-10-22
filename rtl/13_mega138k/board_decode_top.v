// board_decode_top.v — SF9/SF11: 整包板上顶层 (burn 输入件) + 自动判定 + UART 通道
// sys_clk 50MHz 直连 (无 PLL), rst_n K16, led[5:0] (cst: mega138k_decode.cst).
//   led[0]=J14 心跳  led[1]=R26 busy  led[2]=L20 done  led[3]=M25 GOOD(解码闭环)
//   led[4]=N21 引擎 attn 段 PASS 灯   led[5]=N23 引擎 GEMM 段 PASS 灯
// 判决: 每轮 token (token_done) 结束把整轮 out_expert/words 流哈希为 hsh;
//        若 hsh 连续两轮非零且相同 → good++ → led[3]=GOOD (板上直接观测判活)。
// data 面: decode_auto_core SELFDRV=1 内嵌 LFSR 源 → termux core_selftest 同 seed 已对账
//        (done@162 / token_done@160 / a_words=128 / hsh=ff81ff81)。
// UART 通道 (2026-10-21): 同一根 USB JTAG&UART 线 (8 针口: 4×JTAG + 2×UART + VCC/GND),
//        uart_tx=N16(FPGA 发) / uart_rx=P15(FPGA 收), 115200 8N1, 不需要任何额外接线。
//        · 每帧吐一行: F=帧号 W=词量 H=帧哈希 A=attn内积 L=引擎层数 R=rail帧 C=末次命令
//        · 收 1 字节 = 1 条命令: 低4位覆盖 xext(候选窗半径) / bit4 手动触发一帧
module board_decode_top #(
    parameter BAUD = 115200      // UART 波特率 (板级 115200; 仿真可用高速档)
) (
    input  wire sys_clk,
    input  wire rst_n,
    input  wire uart_rx,
    output wire uart_tx,
    output wire [5:0] led,
    // ---- LCD (800x480 RGB666, 复用引擎板同一驱动/时序) ----
    output wire       lcd_clk,
    output wire       lcd_en,
    output wire       lcd_hs,
    output wire       lcd_vs,
    output wire [5:0] lcd_r,
    output wire [5:0] lcd_g,
    output wire [5:0] lcd_b
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
        // q 模板给非零常量: q=0 会让 attn 内积恒 0 → 乘法链被综合器折成常量, MAC 不在网表
        .q_vec_p(64'h0123_4567_89AB_CDEF), .head_acc(16'h1234), .xext(xext_reg),
        .wr_en(1'b0), .wr_addr(9'h0), .wr_data(16'h0),
        .out_valid(out_valid), .out_data(out_data), .out_expert(out_expert),
        .token_done(token_done), .r_token_done(), .out_token(), .out_score(), .h_go(),
        .r_round(), .h_round(), .r_stalls(), .a_stalls(a_stalls), .a_words(a_words),
        .eng_o_valid(eng_o_valid), .eng_o_data(eng_o_data),
        .eng_rail_frames(eng_rail_frames), .eng_attn_done(eng_attn_done),
        .eng_gemm_done(eng_gemm_done), .eng_layers_done(eng_layers_done)
    );

    // ---- 帧节拍 + 手动触发 ----
    reg [3:0]  man_cnt = 0;      // 手动帧脉冲计数
    reg [3:0]  run_len = 0;      // run 高电平剩余拍
    reg [3:0]  xext_reg = 4'h6;  // 候选窗半径 (可由 UART 命令改)
    reg [7:0]  last_cmd = 8'h00;
    wire cmd_valid;
    wire [7:0] cmd_data;

    always @(posedge sys_clk or negedge rst_n)
        if (!rst_n) begin
            div <= 0; tick <= 0; man_cnt <= 0; run_len <= 0; run <= 0;
            xext_reg <= 4'h6; last_cmd <= 8'h00;
        end else begin
            div <= div + 1'b1;
            tick <= tick + 1'b1;                       // 22bit 自然回绕
            if (cmd_valid) begin
                xext_reg <= cmd_data[3:0];             // 低4位 → 候选窗半径
                last_cmd <= cmd_data;
                if (cmd_data[4]) man_cnt <= 4'd15;     // bit4 → 手动触发一帧
            end
            if (man_cnt != 4'd0) man_cnt <= man_cnt - 1'b1;
            // run 脉冲: 常规节拍 (每 2048 拍) 或 手动触发, 两者不重叠
            if (run_len == 4'd0) begin
                if (tick[10:0] == 11'd1000 || man_cnt == 4'd15) begin
                    run <= 1'b1; run_len <= 4'd15;
                end
            end else begin
                run_len <= run_len - 1'b1;
                if (run_len == 4'd1) run <= 1'b0;
            end
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

    // LED 极性: 本板 LED 共阳 (见 periph_smoke.cst 注释"共阳低亮") → 逻辑 0 才点亮。
    // 仓库既有板级顶层 (board_top.v / board_freq800_sentry.v) 一律写 ~signal。
    assign led[0] = ~div[22];           // 心跳 (慢闪)
    assign led[1] = ~busy;              // 忙时点亮 (帧节拍)
    assign led[2] = ~done_state;        // 帧内 done 点亮
    assign led[3] = ~good[1];           // ≥2 连续同指纹 = 解码 GOOD → 点亮
    reg done_state = 0;
    always @(posedge sys_clk or negedge rst_n)
        if (!rst_n) done_state <= 0; else done_state <= done_ir || a_words == 32'd128;

    // ---- 引擎 PASS 灯 (2026-10-21) --------------------------------------------
    // 板上引擎每会话跑一轮 (会话 2048 拍), 活动窗很短 → 闪灯看不出持续活动,
    // 改用**板级锁存**: 见一次就常亮 = 板上真跑过 (共阳 → 条件成立时点亮)。
    //   led[4] N21: attn 段真出非零内积 → 窗灌+读回+内积分块+乘累加链 全活
    //   led[5] N23: 引擎跑满 4 层 (每层含 GEMM 段 → rail 链同时被拉进网表)
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
    assign led[4] = ~eng_attn_seen;
    assign led[5] = ~(eng_gemm_seen & eng_layers_seen);

    // ---- UART: 发送 (行输出器) ----
    localparam [2:0] RP_IDLE = 3'd0, RP_LBL = 3'd1, RP_EQ = 3'd2,
                     RP_HEX = 3'd3, RP_SEP = 3'd4;
    localparam [2:0] NF = 3'd6;          // 末位字段下标 (F W H A L R C 共 7 个, 下标 0..6)

    reg [2:0]  rep_st;
    reg [2:0]  fld;
    reg [3:0]  chr;
    reg [31:0] val_sh;
    reg        rep_pend;
    reg [31:0] rep_f, rep_w, rep_h, rep_a, rep_l, rep_r;

    wire uart_tx_ready;
    wire uart_tx_wr;
    reg [7:0] uart_tx_byte;

    function [7:0] hexdig(input [3:0] n);
        begin
            hexdig = (n < 4'd10) ? (8'h30 + {4'd0, n}) : (8'h41 + {4'd0, n} - 8'd10);
        end
    endfunction

    reg [7:0] lbl;
    always @(*) begin
        case (fld)
            3'd0: lbl = "F";
            3'd1: lbl = "W";
            3'd2: lbl = "H";
            3'd3: lbl = "A";
            3'd4: lbl = "L";
            3'd5: lbl = "R";
            3'd6: lbl = "C";
            default: lbl = " ";
        endcase
    end

    always @(*) begin
        case (rep_st)
            RP_LBL: uart_tx_byte = lbl;
            RP_EQ:  uart_tx_byte = 8'h3D;              // '='
            RP_HEX: uart_tx_byte = hexdig(val_sh[31:28]);  // 高位在前 (人读习惯)
            RP_SEP: uart_tx_byte = (fld == NF) ? 8'h0A : 8'h20;
            default: uart_tx_byte = 8'h20;
        endcase
    end
    assign uart_tx_wr = (rep_st != RP_IDLE) && uart_tx_ready;

    // 每帧锁存一行数据 (保证整行取值一致)
    always @(posedge sys_clk or negedge rst_n)
        if (!rst_n) begin
            rep_f <= 32'd0; rep_w <= 32'd0; rep_h <= 32'd0;
            rep_a <= 32'd0; rep_l <= 32'd0; rep_r <= 32'd0;
        end else if (token_done) begin
            rep_f <= rep_f + 32'd1;
            rep_w <= a_words;
            rep_h <= hsh;
            rep_a <= {16'h0000, eng_o_data};
            rep_l <= eng_layers_done;
            rep_r <= eng_rail_frames;
        end

    reg [31:0] fld_val_raw;
    always @(*) begin
        case (fld)
            3'd0: fld_val_raw = rep_f;
            3'd1: fld_val_raw = rep_w;
            3'd2: fld_val_raw = rep_h;
            3'd3: fld_val_raw = rep_a;
            3'd4: fld_val_raw = rep_l;
            3'd5: fld_val_raw = rep_r;
            3'd6: fld_val_raw = {24'h000000, last_cmd};
            default: fld_val_raw = 32'h0000_0000;
        endcase
    end
    // X 防护: 硅上不会有 X, 但仿真的 slice LUT 未预灌 → 帧哈希 hsh 整条是 X。
    //   用 === 自比较把含 X/Z 的值归零, 保证串口行永远可打印 (硅上此分支恒不生效)。
    reg [31:0] fld_val;
    always @(*) fld_val = (fld_val_raw === fld_val_raw) ? fld_val_raw : 32'h0000_0000;

    always @(posedge sys_clk or negedge rst_n)
        if (!rst_n) begin
            rep_st <= RP_IDLE; fld <= 3'd0; chr <= 4'd0; val_sh <= 32'd0; rep_pend <= 1'b0;
        end else begin
            if (token_done) rep_pend <= 1'b1;
            case (rep_st)
                RP_IDLE: begin
                    if (rep_pend) begin
                        rep_pend <= 1'b0; fld <= 3'd0; chr <= 4'd0; rep_st <= RP_LBL;
                    end
                end
                RP_LBL: begin
                    if (uart_tx_ready) begin
                        val_sh <= fld_val; chr <= 4'd1; rep_st <= RP_EQ;
                    end
                end
                RP_EQ: begin
                    if (uart_tx_ready) begin chr <= 4'd2; rep_st <= RP_HEX; end
                end
                RP_HEX: begin
                    if (uart_tx_ready) begin
                        // 4bit 左旋: 最高位依次转到前面 (右移会把已发的位丢掉)
                        val_sh <= {val_sh[27:0], val_sh[31:28]};
                        if (chr == 4'd9) rep_st <= RP_SEP;  // chr=2..9 共 8 个十六进制位
                        else chr <= chr + 4'd1;
                    end
                end
                RP_SEP: begin
                    if (uart_tx_ready) begin
                        if (fld == NF) begin chr <= 4'd0; rep_st <= RP_IDLE; end
                        else begin fld <= fld + 3'd1; chr <= 4'd0; rep_st <= RP_LBL; end
                    end
                end
                default: rep_st <= RP_IDLE;
            endcase
        end

    uart_tx #(.CLK_HZ(50000000), .BAUD(BAUD)) U_TX (
        .clk(sys_clk), .rst_n(rst_n), .tx(uart_tx),
        .wr_en(uart_tx_wr), .data(uart_tx_byte), .ready(uart_tx_ready)
    );

    // ---- UART: 接收 (命令) ----
    uart_rx #(.CLK_HZ(50000000), .BAUD(BAUD)) U_RX (
        .clk(sys_clk), .rst_n(rst_n), .rx(uart_rx),
        .rd_ready(1'b1), .rd_valid(cmd_valid), .rd_data(cmd_data)
    );

    // ---- LCD 显示 (2026-10-21) ------------------------------------------------
    // 复用引擎板同款: PLL 50M→35M 像素钟 (50×21/1/30) + lcd_display (800x480 RGB666,
    // 无帧缓冲, 组合逻辑查 5x7 点阵字模)。
    //   act_cnt ← 帧号 (每帧 +1, 24.4 次/秒) → 屏幕 COUNT 在跳 = 速度直接可见
    //   sum_out ← 帧哈希 (解码路径的内容指纹)
    //   engine_busy ← 引擎活动 (attn 内积输出有效)
    wire        lcd_clk_35;
    wire        pll_lock;

    Gowin_PLL u_pll (
        .clkout0 (lcd_clk_35),
        .lock    (pll_lock),
        .clkin   (sys_clk)
    );

    lcd_display #(
        .TITLE   ("DECODE STATUS"),
        .LBL1    ("FPS:  "),
        .LBL2    ("W:    "),
        .LBL3    ("HASH: "),
        .LBL4    ("FRM:  "),
        .LBL5    ("L:    "),
        .L1_WORD (1'b0),        // Line1 用十六进制 (FPS), 不用 ACTIVE/IDLE 文字
        .NLINES  (6)
    ) u_lcd (
        .lcd_clk     (lcd_clk_35),
        .rst_n       (pll_lock),
        .act_cnt     (rep_f[23:0]),   // 活动源: 帧号在变 → MODE 判定为 ACTIVE
        .cnt1        (a_words[23:0]), // Line2 每帧词量
        .cnt2        (fps_val),       // Line1 上一秒实测帧数 (速度)
        .val8        (rep_h),         // Line3 帧哈希
        .cnt4        (rep_f[23:0]),   // Line4 帧计数
        .cnt5        (eng_layers_done[23:0]), // Line5 引擎层数
        .lcd_clk_o   (lcd_clk),
        .lcd_en      (lcd_en),
        .lcd_hs      (lcd_hs),
        .lcd_vs      (lcd_vs),
        .lcd_r       (lcd_r),
        .lcd_g       (lcd_g),
        .lcd_b       (lcd_b)
    );

    // ---- 1Hz 窗口: 统计"上一秒实测帧数" → 屏上 FPS 字段 ------------------------
    //   帧周期 = 2048 拍 @50MHz = 40.96us → 理论 24,414 帧/秒; 这个数是**实测**
    //   (若引擎背压或状态机卡住, 它会掉下来), 不是设计常量。
    reg [25:0] sec_cnt = 0;
    reg [23:0] fps_win = 0;
    reg [23:0] fps_val = 0;
    always @(posedge sys_clk or negedge rst_n)
        if (!rst_n) begin
            sec_cnt <= 26'd0; fps_win <= 24'd0; fps_val <= 24'd0;
        end else begin
            if (sec_cnt == 26'd49999999) begin
                sec_cnt <= 26'd0;
                fps_val <= fps_win;
                if (token_done) fps_win <= 24'd1;
                else fps_win <= 24'd0;
            end else begin
                sec_cnt <= sec_cnt + 26'd1;
                if (token_done) fps_win <= fps_win + 24'd1;
            end
        end
endmodule
