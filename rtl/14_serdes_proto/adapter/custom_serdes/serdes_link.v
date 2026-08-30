// ============================================================================
// serdes_link.v — 多 lane SerDes 链路聚合 (L0.5, 位于 framer 与各 lane phy 之间)
//
// 把上层字节流 Round-Robin 轮流分发到 N_LANE 条完全独立的串行 lane,
// 各 lane 吞吐独立, 合计链路吞吐 ≈ N_LANE 倍。RX 侧按相同 lane 序聚合回字节流。
//
// 保序原理: 所有 lane 用同构 serdes_phy(相同 BIT_DELAY/RX_DEPTH), 故各 lane
//   字节到达的相对顺序与 TX 发放 lane 序一致 -> RX 按 lane_sel 轮流取即还原,
//   无需重排缓冲。
//
// TX: 成功派发字节给 lane k 后 lane_sel 前进到 (k+1)%N, 严格轮询保序。
//     被背压的字节存 tx_pend, 待当前 lane 就绪再派。
// RX: 轮询 rx_sel 指向的 lane; 该 lane valid 即取走输出, rx_sel 前进。
// ============================================================================

`timescale 1ns/1ps

module serdes_link #(
    parameter DATAW     = 8,
    parameter N_LANE    = 4,
    parameter BIT_DELAY = 3,
    parameter RX_DEPTH  = 8
)(
    input  wire        clk,
    input  wire        rst_n,

    // ---- TX: 上层字节流入口 ----
    output wire        in_ready,
    input  wire        in_valid,
    input  wire [DATAW-1:0] in_data,

    // ---- RX: 上层字节流出口 ----
    output reg         out_valid,
    input  wire        out_ready,
    output reg  [DATAW-1:0] out_data
);

    // ---- 内部: N_LANE 条 lane 的独立信号 (unpacked 数组) ----
    reg  [DATAW-1:0] lane_txd [0:N_LANE-1];   // 组合 mux 驱动的 per-lane tx 数据
    reg  [N_LANE-1:0] lane_tx_valid;
    wire [N_LANE-1:0] lane_tx_ready;
    wire [DATAW-1:0] lane_rxd  [0:N_LANE-1];  // per-lane rx 数据
    wire [N_LANE-1:0] lane_rx_valid;
    wire [N_LANE-1:0] lane_rx_pending;        // per-lane RX FIFO 非空(有数据待读)
    reg  [N_LANE-1:0] lane_rx_ready;

    genvar g;
    generate
        for (g = 0; g < N_LANE; g = g + 1) begin : lane_phy
            serdes_phy #(.DATAW(DATAW), .N_LANE(1),
                         .BIT_DELAY(BIT_DELAY), .RX_DEPTH(RX_DEPTH)) u_phy (
                .clk(clk), .rst_n(rst_n),
                .tx_valid(lane_tx_valid[g]),
                .tx_ready(lane_tx_ready[g]),
                .tx_data(lane_txd[g]),
                .rx_valid(lane_rx_valid[g]),
                .rx_ready(lane_rx_ready[g]),
                .rx_data(lane_rxd[g]),
                .rx_pending(lane_rx_pending[g])
            );
        end
    endgenerate

    // =========================================================================
    // TX 分发 (严格 round-robin, 有损不可接受 -> 无脆弱脉冲).
    //   每 lane 有"待发槽" lane_tx_valid[i]: 一旦为上层字节填充(level 保持),
    //   持续驱动 phy 直到其真正接受 (lane_tx_valid[i] && lane_tx_ready[i]) 才清。
    //   phy 忙时(tx_buf_full) 字节一直挂在该 lane, 绝不因瞬时忙而丢失。
    //   in_ready 仅当当前位置 lane_sel 的待发槽空闲时拉高(每拍至多收 1 字节)。
    // =========================================================================
    reg  [15:0] lane_sel;          // 当前派发目标 lane
    wire cur_lane_free = !lane_tx_valid[lane_sel];
    wire fire_take     = in_valid && cur_lane_free;
    assign in_ready    = cur_lane_free;

    // 各 lane 是否已被 phy 接受 (valid && ready, 组合判定)
    wire [N_LANE-1:0] lane_accepted;
    genvar za;
    generate
        for (za = 0; za < N_LANE; za = za + 1) begin : acc_detect
            assign lane_accepted[za] = lane_tx_valid[za] && lane_tx_ready[za];
        end
    endgenerate

    always @(posedge clk) begin
        if (!rst_n) begin
            lane_sel      <= 16'd0;
            lane_tx_valid <= {N_LANE{1'b0}};
        end else begin
            // 已接受: 清待发槽 (level 下降, 释放该 lane)
            for (integer da = 0; da < N_LANE; da = da + 1)
                if (lane_accepted[da]) lane_tx_valid[da] <= 1'b0;
            // 填充新字节: 仅当当前位置可发
            if (fire_take) begin
                lane_tx_valid[lane_sel] <= 1'b1;
                lane_txd[lane_sel]      <= in_data;
                lane_sel <= (lane_sel == N_LANE-1) ? 16'd0 : lane_sel + 16'd1;
            end
        end
    end

    // =========================================================================
    // RX 聚合: 单拍取走 (无两拍流水, 出口吞吐 = 1 字节/拍)。
    //   目标 lane = 已输出字节数 (out_cnt) % N_LANE, 与 TX 派发 lane 序严格一致,
    //   且各 lane phy 同构 (延迟一致) -> 目标 lane 的字节必然按序就绪, 保序。
    //   每拍: 目标 lane 的 rx_valid(电平= FIFO 非空) 为真且 out_ready ->
    //         直接取 fifo 头 lane_rxd[target]，同时拉 rx_ready 弹出一个, out_cnt++。
    //   FIFO 空则等目标 lane 填满, 不丢字节。
    // =========================================================================
    reg [31:0] out_cnt;
    wire [15:0] target_lane = out_cnt % N_LANE;

    // phy rx_ready: 仅目标 lane 拉高(每拍至多弹出一个), 其它 lane 保持 0。
    integer ri;
    always @(*) begin
        for (ri = 0; ri < N_LANE; ri = ri + 1)
            lane_rx_ready[ri] = out_ready && (ri == target_lane);
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            out_cnt     <= 32'd0;
            out_valid   <= 1'b0;
            out_data    <= {DATAW{1'b0}};
        end else begin
            out_valid <= 1'b0;
            if (lane_rx_valid[target_lane] && out_ready) begin
                out_data  <= lane_rxd[target_lane];   // 组合 = FIFO 头
                out_valid <= 1'b1;
                out_cnt   <= out_cnt + 32'd1;
            end
        end
    end

endmodule
