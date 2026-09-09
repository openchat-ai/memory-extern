`default_nettype none
//────────────────────────────────────────────────────────────────────────────
// dma_fill.v — A-tile 填充引擎 (§ 预填/解码 DMA 段)
//
// 把外部字流 (NVMe->DDR3 分片流的抽象, src_valid/src_ready 手握手可背压)
// 按 TDEPTH 字/帧 灌入 atile_pingpong 写侧:
//   - 每帧: 等 any_free -> 拉 f_start 一拍 claim -> 逐字灌 (尊重 f_ready)
//   - 帧满 -> 停, 等 any_free 再开下帧 (不覆写 READY/READING 轨)
//   - total 完成 -> done 一拍, 回 IDLE
// 帧内词序/帧边界分组正确性与 "只读一次喂整批" 的复用量即是验收点。
// 纯全帧模式: total 须为 TDEPTH 整数倍 (余帧/切片半帧留给专门件, 见 M-followup)。
//────────────────────────────────────────────────────────────────────────────
module dma_fill #(
    parameter DW     = 32,
    parameter TDEPTH = 64
)(
    input  wire         clk,
    input  wire         rst_n,

    input  wire         go,                // 启动 (一拍)
    input  wire [31:0]  total,             // 总字数 (TDEPTH 整数倍)
    output wire         busy,              // 引擎运转中
    output wire         done,              // 全部灌完 (一拍)

    input  wire         src_valid,         // 来源字流
    output wire         src_ready,
    input  wire [DW-1:0] src_data,

    output wire         f_start,           // -> atile
    output wire         f_valid,
    output wire [DW-1:0] f_data,           // = src_data (直通)
    input  wire         f_ready,
    input  wire         any_free,

    output reg  [31:0]  frames_claimed,
    output reg  [31:0]  prog               // 已灌字数
);

    function integer clog2(input integer n);
        integer k;
        begin
            k = 0;
            while ((1 << k) < n) k = k + 1;
            clog2 = k;
        end
    endfunction
    localparam IDX    = clog2(TDEPTH);
    localparam [1:0] S_IDLE=0, S_WAIT=1, S_FILL=2, S_DONE=3;

    reg [1:0]  st;
    reg [31:0] pending;
    reg [IDX-1:0] wc;                       // 当前帧内字数
    reg        fsync;                       // f_start 脉冲

    wire last_word  = (wc == TDEPTH-1);
    wire frame_done = last_word && src_valid && f_ready;

    // 组合
    assign src_ready = (st == S_FILL) && f_ready;
    assign f_valid   = (st == S_FILL) && src_valid;
    assign f_data    = src_data;
    assign f_start   = fsync;
    assign busy      = (st != S_IDLE);
    assign done      = (st == S_DONE) ? 1'b1 : 1'b0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_IDLE; pending <= 0; wc <= 0; fsync <= 0;
            frames_claimed <= 0; prog <= 0;
        end else begin
            fsync <= 1'b0;
            case (st)
                S_IDLE: begin
                    if (go && total != 0) begin
                        st <= S_WAIT; pending <= total;
                    end
                end
                S_WAIT: begin
                    if (any_free) begin
                        fsync <= 1'b1;          // claim 一拍 (E1)
                        st    <= S_FILL; wc <= 0;
                        frames_claimed <= frames_claimed + 1;
                    end
                end
                S_FILL: begin
                    if (src_valid && f_ready) begin
                        pending <= pending - 1;
                        prog    <= prog + 1;
                        if (frame_done) begin
                            if (pending == 1) begin  // 全部完成
                                st <= S_DONE;
                            end else begin
                                st <= S_WAIT;        // 开下帧
                            end
                            wc <= 0;
                        end else begin
                            wc <= wc + 1;
                        end
                    end
                end
                S_DONE: st <= S_IDLE;
            endcase
        end
    end

endmodule
`default_nettype wire