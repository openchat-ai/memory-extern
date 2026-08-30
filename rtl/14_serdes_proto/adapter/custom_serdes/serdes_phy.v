// ============================================================================
// serdes_phy.v — 自定义裸 SerDes 物理层模型 (可综合仿真版, 抽象串行通道)
//
// 把 DATAW-bit 并行词组(TX 侧)串行化成 N_LANE 条差分串行流,
// 经回环(loopback)传输后, RX 侧解串回复词组。
//
// 这是"通用 SerDes 抽象"的 L0。它对外只暴露一个统一的词组级
// valid/ready/data 接口 —— 不暴露具体 SerDes 电气, 便于顶层用同一内核。
//
// 模型语义 —— 连续位流(最接近真实 SerDes / CDR):
//   - 线上位流连续, 每个 clk 移出一位, 低位在前(LSB-first), 词组间无空隙。
//   - TX 采用双缓冲(当前发送 + 下一个缓存), tx_valid/tx_ready 背压。
//   - 位经回环延迟链(传播延迟 BIT_DELAY 拍)后到 RX。
//   - RX 每 clk 连续轨一位, 每收满 DATAW 位恰好构成一个词组输出。
//
// 参数:
//   DATAW    : 并行词宽(用户数据负载宽度)
//   N_LANE   : 串行 lane 数(逻辑上多 lane 并行; 本模型按单链路建模)
//   BIT_DELAY: 回环位延迟(仿真用, 制造流水深度 > 0)
// ============================================================================

`timescale 1ns/1ps

module serdes_phy #(
    parameter DATAW    = 8,
    parameter N_LANE   = 1,
    parameter BIT_DELAY= 3,          // 回环位周期延迟(>0 制造流水)
    parameter RX_DEPTH = 4           // RX 同步 FIFO 深度(背压缓存, 防下游忙时丢字)
)(
    input  wire        clk,
    input  wire        rst_n,

    // ---- TX 侧: 并行词组入口 ----
    input  wire        tx_valid,
    output wire        tx_ready,
    input  wire [DATAW-1:0] tx_data,

    // ---- RX 侧: 并行词组出口 ----
    output wire        rx_valid,
    input  wire        rx_ready,
    output wire [DATAW-1:0] rx_data,
    // 组合指示: RX FIFO 中有数据待读 (供多 lane 聚合判拍使用)
    output wire        rx_pending
);

    // =========================================================================
    // TX: 双缓冲连续位流
    //   tx_shift : 当前正在逐位移出的位组
    //   tx_buf   : 下一个待发位组(缓冲, 消除词组间空隙)
    //   tx_ready = tx_buf 空闲(可接受新词组)
    //   tx_busy  : 位流中尚有数据可发(tx_shift 未发完 或 tx_buf 非空)
    // =========================================================================
    reg [DATAW-1:0] tx_cur;      // 当前正在逐位发送的字组
    reg [DATAW-1:0] tx_buf;      // 下一个待发字组(缓冲, 消除词组间空隙)
    reg [15:0]      tx_bit;      // 当前组内位序号 0..DATAW-1
    reg             tx_buf_full; // 1 = tx_buf 持有待发数据
    reg             tx_in_send;  // 1 = 位流正在输出

    assign tx_ready = !tx_buf_full;

    always @(posedge clk) begin
        if (!rst_n) begin
            tx_cur      <= {DATAW{1'b0}};
            tx_buf      <= {DATAW{1'b0}};
            tx_bit      <= 16'd0;
            tx_buf_full <= 1'b0;
            tx_in_send  <= 1'b0;
        end else begin
            // 1) 若 tx_buf 空闲且收到新词组 -> 装入缓冲
            if (!tx_buf_full && tx_valid) begin
                tx_buf      <= tx_data;
                tx_buf_full <= 1'b1;
            end
            // 2) 位流推进
            if (tx_in_send) begin
                if (tx_bit == DATAW-1) begin
                    // 本组发完; 若有缓存则接上, 保持位流连续
                    if (tx_buf_full) begin
                        tx_cur      <= tx_buf;
                        tx_buf_full <= 1'b0;
                        tx_bit      <= 16'd0;
                    end else begin
                        tx_in_send  <= 1'b0;               // 无数据, 停
                    end
                end else begin
                    tx_bit <= tx_bit + 16'd1;
                end
            end else begin
                // 空闲: 一旦有缓存, 立即开始移出
                if (tx_buf_full) begin
                    tx_cur      <= tx_buf;
                    tx_buf_full <= 1'b0;
                    tx_bit      <= 16'd0;
                    tx_in_send  <= 1'b1;
                end
            end
        end
    end

    // 线上当前位(LSB-first)。用组合按下标取, 载入当拍即发该组 bit0, 无 off-by-one。
    wire tx_line_bit = tx_in_send ? tx_cur[tx_bit] : 1'b0;

    // =========================================================================
    // 回环延迟链: 位延时 BIT_DELAY 拍(制造传播延迟)
    // =========================================================================
    reg [BIT_DELAY-1:0] line_delay;
    reg rx_serial_bit;
    always @(posedge clk) begin
        if (!rst_n) begin
            line_delay    <= {BIT_DELAY{1'b0}};
            rx_serial_bit <= 1'b0;
        end else begin
            line_delay    <= {line_delay[BIT_DELAY-2:0], tx_line_bit};
            rx_serial_bit <= line_delay[BIT_DELAY-1];
        end
    end

    // =========================================================================
    // RX: 每 clk 连续采样一位, 每收满 DATAW 位恰好组一个词组。
    // 只用 rx_active 门控"是否有数据", 位流本身连续, 故字节边界天然对齐。
    // =========================================================================
    reg [BIT_DELAY-1:0] act_delay;
    reg rx_active;
    always @(posedge clk) begin
        if (!rst_n) begin
            act_delay <= {BIT_DELAY{1'b0}};
            rx_active <= 1'b0;
        end else begin
            act_delay <= {act_delay[BIT_DELAY-2:0], tx_in_send};
            rx_active <= act_delay[BIT_DELAY-1];
        end
    end

    // =========================================================================
    // RX: 每 clk 连续采样一位, 每收满 DATAW 位恰好组一个词组。
    // 只用 rx_active 门控"是否有数据", 位流本身连续, 故字节边界天然对齐。
    // 收满的字组写入同步 FIFO; rx_valid = FIFO 非空, rx_ready 弹出。
    // 这样 rx_ready=0 时数据缓存在 FIFO 不丢(真正背压, 防下游忙时丢字)。
    // =========================================================================
    reg  [DATAW-1:0] rx_shift;
    reg  [15:0]      rx_cnt;

    always @(posedge clk) begin
        if (!rst_n) begin
            rx_shift      <= {DATAW{1'b0}};
            rx_cnt        <= 16'd0;
        end else begin
            if (rx_active) begin
                rx_shift[rx_cnt] <= rx_serial_bit;
                if (rx_cnt == DATAW-1) begin
                    rx_cnt <= 16'd0;
                end else begin
                    rx_cnt <= rx_cnt + 16'd1;
                end
            end
        end
    end

    // ---- 同步环形 FIFO (深度 RX_DEPTH, 需 >=2) ----
    reg [DATAW-1:0] fifo_mem [0:RX_DEPTH-1];
    reg [15:0]      wr_ptr, rd_ptr, fifo_cnt;
    wire fifo_full  = (fifo_cnt == RX_DEPTH[15:0]);
    wire fifo_empty = (fifo_cnt == 16'd0);

    // 组合读头: rx_data 恒等于 FIFO 头, rx_valid=非空(电平)。
    // 下游每拍可直接取走 FIFO 头字节, 无脉冲/滞后拍, 出口吞吐=1 字节/拍。
    assign rx_data   = fifo_mem[rd_ptr];
    assign rx_valid  = !fifo_empty;
    assign rx_pending = !fifo_empty;

    // 同拍组合: 采满一位(rx_cnt==DATAW-1)时, rx_word_in 即完整字组
    wire rx_fifo_push = rx_active && (rx_cnt == DATAW-1);
    wire [DATAW-1:0] rx_word_in = {rx_serial_bit, rx_shift[DATAW-2:0]};

    always @(posedge clk) begin
        if (!rst_n) begin
            wr_ptr   <= 16'd0;
            rd_ptr   <= 16'd0;
            fifo_cnt <= 16'd0;
        end else begin
            // 写: 采满一字组且 FIFO 未满 (满则丢; 深度足够即不丢)
            if (rx_fifo_push && !fifo_full) begin
                fifo_mem[wr_ptr] <= rx_word_in;
                wr_ptr           <= (wr_ptr == RX_DEPTH-1) ? 16'd0 : wr_ptr + 16'd1;
                fifo_cnt         <= fifo_cnt + 16'd1;
            end

            // 读: 下游就绪且 FIFO 非空 -> 头指针前进
            if (rx_ready && !fifo_empty) begin
                rd_ptr   <= (rd_ptr == RX_DEPTH-1) ? 16'd0 : rd_ptr + 16'd1;
                if (rx_fifo_push && !fifo_full)
                    fifo_cnt <= fifo_cnt;          // 同拍读写, 数量不变
                else
                    fifo_cnt <= fifo_cnt - 16'd1;  // 仅读, 数量减一
            end
        end
    end

endmodule
