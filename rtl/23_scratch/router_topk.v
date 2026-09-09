`timescale 1ns/1ps
`default_nettype none
//────────────────────────────────────────────────────────────────────────────
// router_topk.v — router 排序: 在线 top-K 选路器 (M8 主占位)
//
// 定位 (冻结基线 §13 待办 "router 先行"): gate/e_score 装 scratch 后,
// 先选出 top-16 专家名次, 再按名次去拉实体 —— 选路必须先行于授冲。
//
// 语义:
//   - 候选源 = scratch 组合直读 (mem_rd_addr 自走), 每候选 16bit 槽位,
//     PACK=DW/16; 按扫序号 k 递增喂入 (先到先得 → 稳定);
//   - 领跑榜 K 槽链式插入: 严格 > 才抢占 → 同名次先序(小序号)占位,
//     与黄金 "分大为主, 次序号升序" 同构;
//   - s_run 一次: RUN 逐候选插入 N 拍 → EMIT 名次位出 K 拍 (desc);
//   - busy 电平贯穿, 结果 pair (index,score) 逐名次给出。
// 纪律: 组合读沿采样 (addr=idx 已定型一拍, mem 翻出即取, 无多余寄存器);
//       计数位宽容终值; 消费口电平手拉手。
//────────────────────────────────────────────────────────────────────────────
module router_topk #(
    parameter SW   = 16,     // 分数位宽 (无符号)
    parameter N    = 256,    // 候选数
    parameter K    = 16,     // 名次名额
    parameter DW   = 64,     // 与 scratch 对齐
    parameter PACK = 4       // 每字槽数 = DW/16
)(
    input  wire         clk,
    input  wire         rst_n,
    input  wire         s_run,          // 启动一次选路 (脉冲)

    // ---- 到 scratch 的组合读 ----
    output wire [AW-1:0] mem_rd_addr,
    input  wire [DW-1:0] mem_rd_data,

    // ---- 结果 ----
    input  wire         res_ready,      // 电平: 消费者在取
    output reg          bus_state,      // busy
    output reg          res_valid,      // 名次位出一拍
    output reg  [IWB-1:0] res_index,
    output reg  [SW-1:0]  res_score
);

    localparam AW  = $clog2(N) - $clog2(PACK);       // 字地址位宽 = IWB - 槽位
    localparam IWB = $clog2(N);

    localparam SIDLE = 2'd0, SRUN = 2'd1, SEMIT = 2'd2;

    reg [1:0]       state;
    reg [IWB-1:0]   fed;

    reg [SW-1:0]    rk_score [0:K-1];
    reg [IWB-1:0]   rk_index [0:K-1];
    reg [IWB-1:0]   rp;                       // 名次位出指针 (SEMIT)

    integer i, j;
    reg found;
    reg [SW-1:0]    tmp_score [0:K-1];
    reg [IWB-1:0]   tmp_index [0:K-1];

    wire [SW-1:0]   xin = mem_rd_data[fed[$clog2(PACK)-1:0]*SW +: SW];

    assign mem_rd_addr = state[0] ? fed[IWB-1:$clog2(PACK)] : {AW{1'b0}};
    assign bus_state   = state[0] | state[1];   // RUN 或 EMIT

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= SIDLE; fed <= 0; rp <= 0;
            res_valid <= 0; res_index <= 0; res_score <= 0;
            for (i = 0; i < K; i = i + 1) begin
                rk_score[i] <= {SW{1'b0}};
                rk_index[i] <= {IWB{1'b0}};
            end
        end else begin
            case (state)
                SIDLE: begin
                    res_valid <= 0;
                    if (s_run) begin
                        fed <= 0;
                        rp  <= 0;
                        for (i = 0; i < K; i = i + 1) begin
                            rk_score[i] <= {SW{1'b0}};
                            rk_index[i] <= {IWB{1'b0}};
                        end
                        state <= SRUN;
                    end
                end
                SRUN: begin
                    res_valid <= 0;
                    fed <= fed + 1'b1;
                    // 组合直读当前候选, 插入领跑榜 (严格 >)
                    for (i = 0; i < K; i = i + 1) begin
                        tmp_score[i] = rk_score[i];
                        tmp_index[i] = rk_index[i];
                    end
                    found = 1'b0; j = K;
                    for (i = 0; i < K && !found; i = i + 1) begin
                        if (xin > tmp_score[i]) begin
                            j = i; found = 1'b1;
                        end
                    end
                    if (found) begin
                        for (i = 0; i < K; i = i + 1) begin
                            if (i == j) begin
                                rk_score[i] <= xin;
                                rk_index[i] <= fed;
                            end else if (i > j) begin
                                rk_score[i] <= tmp_score[i-1];
                                rk_index[i] <= tmp_index[i-1];
                            end else begin
                                rk_score[i] <= tmp_score[i];
                                rk_index[i] <= tmp_index[i];
                            end
                        end
                    end
                    if (fed == N-1) begin
                        state <= SEMIT;
                    end
                end
                SEMIT: begin
                    res_valid <= 1'b1;
                    res_index <= rk_index[rp];
                    res_score <= rk_score[rp];
                    if (rp == K-1) begin
                        state <= SIDLE;
                    end
                    rp <= rp + 1'b1;
                end
                default: state <= SIDLE;
            endcase
        end
    end

endmodule
`default_nettype wire