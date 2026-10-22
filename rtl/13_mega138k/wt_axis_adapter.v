// wt_axis_adapter.v — 14 侧权重字流 → 13 侧引擎 AXI-Stream 帧 (2026-10-22)
// ============================================================================
// 三方汇合 (13↔14) 的语义对接件。两侧原本语义不同:
//
//   14 侧 cachectl_pipeline:  裸权重字流 (DW=32bit/字) + wt_lba(48bit, 与字同拍)
//                             没有帧、没有 cmd、没有字节打包
//   13 侧 pcie_dma_engine:     AXI-Stream 帧
//                             拍0  = [7:0]cmd(0x01推激活/0x02权重) [15:8]seq
//                                    [23:16]rem_bytes(负载总字节数)
//                                    [127:24] 引擎未用 → 本件放 wt_lba(48bit)
//                             拍1..N = 负载, 每拍 AXIS_WIDTH/8 字节 (tkeep 逐字节选通)
//                             权重帧固定 4 拍 = 64 字节 = 128 lane × 4bit 码
//
// 本件做的事 (不改 14 侧任何文件):
//   1. 造 cmd 拍: CMD_RUN_WEIGHT(0x02) + 自增 seq + rem_bytes
//   2. wt_lba 放进帧头 [127:80] (引擎目前忽略, 供 PC 侧回溯校验)
//   3. 32bit 字 → 128bit 拍 (每拍 4 字), 字序保持 (小端打包: 低字节先)
//   4. 帧边界: 每 WORDS_PER_FRAME(=16) 字一帧 = 64 字节 = 引擎权重帧长度
//   5. 反压: 引擎 tready=0 (SETTLE 期间) 时**保持当前拍**, 停收字, 不丢拍不丢字
//
// AXI-Stream 握手纪律 (2026-10-22 被 TB 打出来过):
//   tvalid 一旦拉起就必须**保持到接收方收走**(tvalid && tready)为止,
//   期间 tdata/tkeep/tlast 不得变 → 所以"发拍"要拆成"摆拍"和"被收走"两相。
//   (早期版本在周期顶部无条件清 tvalid → 接收方 tready=0 时整拍丢失)
//
// 线序 (帧头必须在负载之前, 而 LBA 只有拿到帧首字才知道):
//   收帧首字(锁 LBA) → 收满一张拍 → 发帧头 → 发该负载拍 → ... → 帧末拍带 tlast
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

module wt_axis_adapter #(
    parameter DW        = 32,      // 权重字宽 (14 侧 wt_data)
    parameter AXIS_WIDTH = 128,     // 引擎侧拍宽
    parameter LBAW      = 48,       // LBA 位宽 (14 侧 wt_lba)
    parameter WORDS_PER_FRAME = 16,  // 每帧字数 (16 字 × 4B = 64B = 引擎权重帧)
    parameter CMD_RUN_WEIGHT = 8'h02
)(
    input  wire                    clk,
    input  wire                    rst_n,

    // ---- 14 侧: 权重字流 + LBA ----
    input  wire [DW-1:0]           wt_data,
    input  wire                    wt_valid,
    output wire                    wt_ready,
    input  wire [LBAW-1:0]         wt_lba,

    // ---- 13 侧: 引擎 AXI-Stream ----
    output reg  [AXIS_WIDTH-1:0]    s_axis_tdata,
    output reg                      s_axis_tvalid,
    input  wire                     s_axis_tready,
    output reg  [AXIS_WIDTH/8-1:0]  s_axis_tkeep,
    output reg                      s_axis_tlast,

    // ---- 观测 ----
    output wire [LBAW-1:0]         frame_lba,   // 当前帧 LBA (帧头里那一份)
    output wire [7:0]              frame_seq,   // 当前帧 seq
    output reg                      frame_done   // 每帧完成 1 拍脉冲
);

    localparam integer WPB  = AXIS_WIDTH / DW;    // 每拍字数 (128/32 = 4)
    localparam integer PPB  = AXIS_WIDTH / 8;     // 每拍字节数 (16)
    localparam integer LEN_BYTES = WORDS_PER_FRAME * (DW/8);   // 帧负载字节数 (64)
    localparam integer BPF  = WORDS_PER_FRAME / WPB;           // 每帧拍数 (4)

    localparam [1:0] S_W = 2'd0,   // 收字填拍
                     S_H = 2'd1,   // 发帧头
                     S_P = 2'd2;   // 发负载拍

    reg [1:0]  st;
    reg [AXIS_WIDTH-1:0] beat_buf;    // 正在填的拍
    reg [2:0]  wcnt;                 // 本拍已填字数
    reg [2:0]  fb;                   // 本帧已发拍数
    reg [7:0]  seq;
    reg [LBAW-1:0] lba_q;

    assign wt_ready = (st == S_W);   // 只在收字态收; 发拍期间停收 (反压上游)
    assign frame_lba = lba_q;
    assign frame_seq = seq;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_W; beat_buf <= {AXIS_WIDTH{1'b0}}; wcnt <= 3'd0; fb <= 3'd0;
            seq <= 8'd0; lba_q <= {LBAW{1'b0}}; frame_done <= 1'b0;
            s_axis_tdata <= {AXIS_WIDTH{1'b0}}; s_axis_tvalid <= 1'b0;
            s_axis_tkeep <= {PPB{1'b0}}; s_axis_tlast <= 1'b0;
        end else begin
            case (st)
                // ---------------------------------------------------------
                S_W: begin
                    s_axis_tvalid <= 1'b0;      // 无挂起拍
                    s_axis_tlast  <= 1'b0;
                    frame_done    <= 1'b0;       // 帧完成脉冲只保持 1 拍
                    if (wt_valid) begin
                        beat_buf[wcnt*DW +: DW] <= wt_data;   // 小端: 低字节先
                        if (wcnt == 3'd0) begin
                            if (fb == 3'd0) lba_q <= wt_lba;   // 帧首字带 LBA
                            wcnt <= 3'd1;
                        end else if (wcnt == WPB[2:0] - 3'd1) begin
                            wcnt <= 3'd0;                       // 本拍收满
                            st   <= (fb == 3'd0) ? S_H : S_P;   // 帧首拍先发帧头
                        end else begin
                            wcnt <= wcnt + 3'd1;
                        end
                    end
                end
                // ---------------------------------------------------------
                S_H: begin
                    // 帧头: [127:80]=LBA  [79:24]=0  [23:16]=rem_bytes  [15:8]=seq  [7:0]=cmd
                    if (!s_axis_tvalid) begin
                        s_axis_tdata  <= {lba_q, {(AXIS_WIDTH-80){1'b0}}, LEN_BYTES[15:0], seq, CMD_RUN_WEIGHT};
                        s_axis_tkeep <= {PPB{1'b1}};
                        s_axis_tvalid <= 1'b1;
                    end
                    else if (s_axis_tready) begin
                        s_axis_tvalid <= 1'b0;        // 头被收走 → 接着发这张负载拍
                        seq <= seq + 8'd1;
                        st  <= S_P;
                    end
                end
                // ---------------------------------------------------------
                S_P: begin
                    if (!s_axis_tvalid) begin
                        s_axis_tdata  <= beat_buf;
                        s_axis_tkeep <= {PPB{1'b1}};
                        s_axis_tvalid <= 1'b1;
                        if (fb == BPF[2:0] - 3'd1) s_axis_tlast <= 1'b1;   // 帧末拍
                    end
                    else if (s_axis_tready) begin
                        s_axis_tvalid <= 1'b0;
                        s_axis_tlast  <= 1'b0;
                        if (fb == BPF[2:0] - 3'd1) begin
                            fb <= 3'd0;
                            frame_done <= 1'b1;
                        end else begin
                            fb <= fb + 3'd1;
                        end
                        st <= S_W;
                    end
                end
                default: st <= S_W;
            endcase
        end
    end
endmodule
`default_nettype wire
