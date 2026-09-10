`timescale 1ps/1ps
`default_nettype none

// M12 kv_writeback——v2 层 KV 写回件 (P1 状态搬移件, 板上源头)
//
// 基线 §5 定案(2026-09-10, K3_KV_QUANT_PROBE.md):
//   latent 512×INT8(每 token 1 scale) + rope 64×4bit → 24 层 × 544B = 12.75KB/token,
//   append-only 落主机 pinned 区, 严格层序。
// 本件 = P1 SDMA / 主机模拟器(sim_layer_flow.py 字节序对账)的板上源头:
//   · pass0 全梳理: go 后先把整 token 的 24 层 latent+rope 过一遍 → 求 token 级单一
//     scale(口径: 每 token 1 scale, 非每层)——跨层共 quant 域
//   · pass1 建帧:  逐层 [8B 头][512×INT8 latent][64×4bit rope→32B], 552B/帧连发
//   · credit 门:   DMA 弹性 FIFO(主机侧)无信用 → 停推不丢序, 等 credit 恢复续推;
//                 脉冲推 f_ 1B/拍, 挂起字节恒有
//   · 罪证 order_bad: pass1 每层首词校验层号 == 期望计数(防越序推翻 layer-ordered 前提)
//   · 簿记: bytes_written/frames 全 token 累计(快照差对账), stalls=等 credit 拍数
//
// 纪律: 撤 f_valid/f_we 一律非阻塞; 吸收成功给 lat_abs/rope_abs 脉冲, 输送侧据此出词
//       (pass0 用同一接口; pass0 只求峰, 不必校层号)。
// 场景: decode 逐字自回归(two-pass 认 token); 预填 batch 同层同步为布局题, 不在此件。

module kv_writeback #(
    parameter NL2     = 24,   // 产 KV 的 v2 层数(实配 24)
    parameter LATENT  = 512,  // latent 元素(INT8, 每 token 1 scale)
    parameter ROPE    = 64    // rope 元素(4bit)
)(
    input  wire                clk,
    input  wire                rst_n,
    input  wire                go,        // 新一轮(token 起点; 须 token_done 后)
    output reg                 busy,

    // 输送侧(层内投影器; 逐字手拉手)
    input  wire [7:0]          s_lay,     // pass1 时当前层号(pass0 忽略)
    input  wire                lat_valid,
    input  wire [7:0]          s_lat,     // latent 源幅 0..255
    input  wire                rope_valid,
    input  wire [7:0]          s_rope,    // rope 源幅 0..255
    output reg                 lat_abs,   // 吸收成功脉冲
    output reg                 rope_abs,

    // DMA 弹性 FIFO(主机)推口: credit=1 方能推
    input  wire                credit,
    output reg                 f_valid,   // 字节有效(与 f_we 同脉冲)
    output reg                 f_we,
    output reg  [7:0]          f_b,

    // 观测
    output reg  [31:0]         bytes_written, // 累计下发字节
    output reg  [31:0]         frames,        // 累计下发帧
    output reg  [31:0]         stalls,        // 等 credit 拍数
    output reg                 order_bad,     // 层序罪证
    output reg                 token_done     // token 整轮完工脉冲
);
    localparam  IDLE = 2'd0, P0 = 2'd1, P1 = 2'd2;
    localparam  LAT_T = NL2 * LATENT, ROPE_T = NL2 * ROPE;
    localparam  LBT   = $clog2(LAT_T + 1);   // p0_lat 计数位宽
    localparam  RBTW  = $clog2(ROPE_T + 1);  // p0_rope 计数位宽
    localparam  QB    = $clog2(LATENT + ROPE/2 + 8 + 1); // 帧字节指针位宽 552

    reg [1:0]   st;
    reg         session;
    reg [LBT-1:0] p0_lat;    // pass0 已收 latent 词(累计到 24×512)
    reg [RBTW-1:0] p0_rope;  // pass0 已收 rope 词
    reg [7:0]   latmax, ropemax;  // token 级峰(INT8 / rope 域)
    reg [15:0]  lscale, rscale;   // (127<<7)/max, (15<<7)/max

    // pass1 帧内
    reg [QB-1:0]  q;          // 帧字节指针 0..551
    reg [8:0]     pl_lat;     // 本层已收 latent 词(0..511)
    reg [6:0]     pl_rope;    // 本层已收 rope 词(0..63)
    reg [7:0]     pl_lay;     // 本层期望层号(0..23)
    reg [2:0]     ws;         // 0=就绪可推 1=等lat 2=等rope偶 3=等rope奇
    reg          pend;        // 有待推字节
    reg [7:0]    pq;          // 待推字节
    reg [3:0]    rope_ev, rope_od;

    localparam [15:0] FRAME_LEN = LATENT + ROPE/2;   // 544

    function [7:0] hl(input integer k);   // 8B 帧头
        begin
            case (k)
                0: hl = pl_lay[7:0];
                1: hl = 8'h00;
                2: hl = 8'h01;            // 类型: v2=KV-append
                3: hl = 8'h00;
                4: hl = 8'h00;            // 头偏移(本帧内 0)
                5: hl = 8'h00;
                6: hl = FRAME_LEN[7:0];   // 长度 544 = {0x02,0x20}
                7: hl = FRAME_LEN[15:8];
                default: hl = 8'h00;
            endcase
        end
    endfunction

    function [7:0] qlat(input [7:0] v, input [15:0] s);  // INT8, per-token scale
        reg [23:0] t;
        begin
            t = $unsigned(v) * s;
            qlat = (t + 64) >> 7;
            if (qlat > 8'd127) qlat = 8'd127;
        end
    endfunction

    function [3:0] qrope(input [7:0] v, input [15:0] s);  // 4bit
        reg [23:0] t;
        begin
            t = $unsigned(v) * s;
            qrope = (t + 64) >> 7;
            if (qrope > 4'd15) qrope = 4'd15;
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st            <= IDLE;
            session       <= 1'b0;
            busy          <= 1'b0;
            p0_lat        <= 0;
            p0_rope       <= 0;
            latmax        <= 0;
            ropemax       <= 0;
            lscale        <= 0;
            rscale        <= 0;
            q             <= 0;
            pl_lat        <= 0;
            pl_rope       <= 0;
            pl_lay        <= 0;
            ws            <= 0;
            pend          <= 1'b0;
            pq            <= 0;
            rope_ev       <= 0;
            rope_od       <= 0;
            f_valid       <= 1'b0;
            f_we          <= 1'b0;
            f_b           <= 0;
            lat_abs       <= 1'b0;
            rope_abs      <= 1'b0;
            bytes_written <= 0;
            frames        <= 0;
            stalls        <= 0;
            order_bad     <= 1'b0;
            token_done    <= 1'b0;
        end
        else begin
            // 默认撤脉冲
            f_valid <= 1'b0;
            f_we    <= 1'b0;
            lat_abs <= 1'b0;
            rope_abs<= 1'b0;
            token_done <= 1'b0;

            case (st)
                //---------------- go: 开一轮, 求 token 级峰 ----------------
                IDLE: begin
                    if (go) begin
                        session  <= 1'b1;
                        busy     <= 1'b1;
                        st       <= P0;
                        p0_lat   <= 0;
                        p0_rope  <= 0;
                        latmax   <= 0;
                        ropemax  <= 0;
                        order_bad<= 1'b0;
                    end
                end

                //---------------- pass0: 全 token latent+rope 过一遍求 max ----------------
                P0: begin
                    if (lat_valid) begin
                        lat_abs <= 1'b1;
                        if (s_lat > latmax) latmax <= s_lat;
                        p0_lat <= p0_lat + 1;
                    end
                    if (rope_valid) begin
                        rope_abs <= 1'b1;
                        if (s_rope > ropemax) ropemax <= s_rope;
                        p0_rope <= p0_rope + 1;
                    end
                    if (p0_lat == LAT_T && p0_rope == ROPE_T) begin
                        // token 全词过完, max 已落定: 定 token 级 scale, 进 pass1
                        lscale <= (latmax == 0) ? 1 : ((16'd16256) / {8'd0, latmax});
                        rscale <= (ropemax == 0) ? 1 : ((16'd1920) / {8'd0, ropemax});
                        pl_lay <= 0;
                        pl_lat <= 0;
                        pl_rope<= 0;
                        q      <= 0;
                        ws     <= 3'd0;
                        pend   <= 1'b1;
                        pq     <= 0;        // 头第0字节
                        st     <= P1;
                    end
                end

                //---------------- pass1: 逐层建帧, credit 门限 ---------------
                P1: begin
                    case (ws)
                        // 字节就绪 → 推(有信用才推, 无则挂起记 stall)
                        3'd0: if (pend) begin
                            if (credit) begin
                                f_valid  <= 1'b1;
                                f_we     <= 1'b1;
                                f_b      <= pq;
                                bytes_written <= bytes_written + 1;
                                pend     <= 1'b0;
                                q        <= q + 1;
                                case (q + 1)
                                   1: begin ws <= 3'd0; pend <= 1'b1; pq <= hl(1); end
                                   2: begin ws <= 3'd0; pend <= 1'b1; pq <= hl(2); end
                                   3: begin ws <= 3'd0; pend <= 1'b1; pq <= hl(3); end
                                   4: begin ws <= 3'd0; pend <= 1'b1; pq <= hl(4); end
                                   5: begin ws <= 3'd0; pend <= 1'b1; pq <= hl(5); end
                                   6: begin ws <= 3'd0; pend <= 1'b1; pq <= hl(6); end
                                   7: begin ws <= 3'd0; pend <= 1'b1; pq <= hl(7); end
                                   default: ws <= (q + 1 >= (8 + LATENT)) ? 3'd2  // 进 rope 段
                                                              : 3'd1;          // latent 段
                                 endcase
                            end
                            else
                                stalls <= stalls + 1;
                        end

                        // 等 latent 词(每槽一个)
                        3'd1: if (lat_valid) begin
                            if (pl_lat == 0 && s_lay != pl_lay) order_bad <= 1'b1;
                            lat_abs <= 1'b1;
                            pl_lat  <= pl_lat + 1;
                            pend    <= 1'b1;
                            pq      <= qlat(s_lat, lscale);
                            ws      <= 3'd0;
                        end

                        // 等 rope 偶位
                        3'd2: if (rope_valid) begin
                            rope_abs <= 1'b1;
                            rope_ev  <= qrope(s_rope, rscale);
                            ws       <= 3'd3;
                        end

                        // 等 rope 奇位 → 拼 4bit 字节
                        3'd3: if (rope_valid) begin
                            rope_abs <= 1'b1;
                            rope_od  <= qrope(s_rope, rscale);
                            pl_rope  <= pl_rope + 2;
                            pend     <= 1'b1;
                            pq       <= {rope_ev, qrope(s_rope, rscale)};   // 用本拍新算的奇位
                            ws       <= 3'd0;
                        end
                    endcase

                    // 帧尾(末字节 551 真正推出时才推进层 / token 完工; q=551 等待期不误触发)
                    if (q + 1 == (LATENT + ROPE/2 + 8) && pend) begin
                        frames <= frames + 1;
                        pl_lat <= 0;
                        pl_rope<= 0;
                        if (pl_lay + 1 == NL2) begin
                            st         <= IDLE;
                            session    <= 1'b0;
                            busy       <= 1'b0;
                            token_done <= 1'b1;
                        end
                        else begin
                            pl_lay <= pl_lay + 1;
                            q      <= 0;
                            ws     <= 3'd0;
                            pend   <= 1'b1;
                            pq     <= pl_lay + 1;      // 头第0字节 = 新层号
                        end
                    end
                end
                default: st <= IDLE;
            endcase
        end
    end
endmodule