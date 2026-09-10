// sched_flow.v — 专家装配调度器: 把自我调度 sched4 接入层循环 (M10)
//
// 基线 §9 "router 先行 / 专家库侧装配":
//   每层 router top-16 选出的专家实体标签 (tag 流) 由本模块按层节拍喂入
//   selfsched4 (06_sched): 每层恰 16 次查询 (q_req), 层尾以本层最热 PF 个
//   实体标签预取下一层 (pf_req), 层首实体 (必查头) 在线 pin 进 L0 热表 (hot_wen)。
//   层号推进受双缓冲栅栏约束: 进入层 L+1 前须 wb_flow 已释放本层
//   (layer_sync >= L+1) —— 与 wb_flow 的 allow_fill 规则互为镜像, 绝不多领跑。
//   层序严格性 (逐层恰 16 词、词序单调) 由 TB 逐词对账承担 (gold 层谱),
//   本模块只负责"不越栅栏、不丢字"。
//
// 语义要点:
//   - 组合门控: t_ready = (stage==FEED); 收词即查询 (q_req 与 t_valid 同拍,
//     sched4 沿上同时看到 req 与 tag 快照)。
//   - 层尾预取: PREFETCH 阶段逐拍发 PF 个 pf_req; 预测 = 本层前 PF 个 tag
//     (跨层热门复用是装配流真实局部性); 去重/落池由 sched4 自理。
//   - hot pin: FEED 首词同时写 L0 (hot_addr=层号低 2 位), 首词沿即自命中。
//   - 每层独立计量 tags_per_layer == K; q_done/pf_done/layers_done 簿记。
//
// 例化参数与 selfsched4 匹配: AW=16, K=16 (router top-16), PF=4, NL=层数。

module sched_flow #(
    parameter AW    = 16,
    parameter K     = 16,      // 每层查询词数 (router top-16)
    parameter PF    = 4,       // 层尾预取条数
    parameter NL    = 8        // 层数
)(
    input  wire           clk,
    input  wire           rst_n,
    input  wire           go,
    output reg            busy,

    // 层 tag 源 (router 输出面)
    input  wire           t_valid,
    input  wire [AW-1:0]  t_data,
    output reg            t_ready,

    // → selfsched4
    output reg            q_req,
    output reg  [AW-1:0]  q_tag,
    output reg            pf_req,
    output reg  [AW-1:0]  pf_tag,
    output reg            hot_wen,
    output reg  [1:0]     hot_addr,
    output reg  [AW-1:0]  hot_data,

    // 层节拍 (wb_flow.layers_done)
    input  wire [31:0]    layer_sync,

    // 簿记
    output reg [31:0]     layer_now,
    output reg [31:0]     q_done,
    output reg [31:0]     pf_done,
    output reg [31:0]     layers_done
);

    localparam IDLE   = 0;
    localparam FEED   = 1;
    localparam PFETCH = 2;
    localparam WAITL  = 3;

    localparam LW = $clog2(NL + 1);
    localparam KW = $clog2(K + 1);
    localparam PW = $clog2(PF + 1);

    reg [1:0]       st;
    reg [LW-1:0]    lay;
    reg [KW-1:0]    tc;         // 当前层已收词数
    reg [PW-1:0]    pc;         // 预取发射计数
    reg [AW-1:0]    pf_mem [0:PF-1];   // 本层前 PF 个 tag (下一层预测源)

    wire stage_feed   = (st == FEED);
    wire stage_pfetch = (st == PFETCH);
    wire stage_waitl  = (st == WAITL);

    integer i;

    // —— 组合门控 (sched4 沿上读快照)
    always @* begin
        q_req     = 1'b0;
        q_tag     = t_data;
        pf_req    = 1'b0;
        pf_tag    = pf_mem[0];
        hot_wen   = 1'b0;
        hot_addr  = lay[1:0];
        hot_data  = t_data;
        t_ready   = stage_feed;

        if (stage_feed) begin
            // 收词即查询
            q_req     = t_valid;
            q_tag     = t_data;
            // 层首词 pin 进 L0 (必查头)
            hot_wen   = (tc == 0) && t_valid;
            hot_addr  = lay[1:0];
            hot_data  = t_data;
        end
        if (stage_pfetch) begin
            pf_req    = (pc < PF);
            pf_tag    = pf_mem[pc];
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st         <= IDLE;
            lay        <= 0;
            tc         <= 0;
            pc         <= 0;
            busy       <= 1'b0;
            layer_now  <= 0;
            q_done     <= 0;
            pf_done    <= 0;
            layers_done<= 0;
            for (i = 0; i < PF; i = i + 1) pf_mem[i] <= 0;
        end else begin
            case (st)
                IDLE: begin
                    if (go) begin
                        st   <= FEED;
                        lay  <= 0;
                        tc   <= 0;
                        pc   <= 0;
                        busy <= 1'b1;
                        // 会话清账 (与 wb_flow 的 go 沿清账同训)
                        layer_now   <= 0;
                        q_done      <= 0;
                        pf_done     <= 0;
                        layers_done <= 0;
                    end
                end

                FEED: begin
                    if (t_valid) begin
                        // 记忆预测源 (本层前 PF 词)
                        if (tc < PF) pf_mem[tc] <= t_data;
                        tc <= tc + 1;
                        // 收满 K 词 → 层尾预取
                        if (tc == K - 1) begin
                            st  <= PFETCH;
                            pc  <= 0;
                        end
                    end
                end

                PFETCH: begin
                    // 本层 latest: 预测 = 本层前 PF 个 tag
                    if (pc < PF) begin
                        pc <= pc + 1;
                        if (pc == PF - 1) begin
                            st  <= WAITL;
                            pc  <= 0;
                        end
                    end
                end

                WAITL: begin
                    // 双缓冲栅栏: 进层 L+1 前须 wb_flow 已释放本层 (层序不越界)
                    if (layer_sync >= lay + 1) begin
                        st           <= FEED;
                        tc           <= 0;
                        lay          <= lay + 1;
                        layer_now    <= lay + 1;
                        layers_done  <= layers_done + 1;
                        if (lay + 1 >= NL) begin
                            st   <= IDLE;
                            busy <= 1'b0;
                        end
                    end
                end

                default: st <= IDLE;
            endcase

            // 每层词/预取/完成计量 (在 FEED/PFETCH 完成沿累加)
            if (st == FEED && t_valid && tc == K - 1) q_done <= q_done + K;
            if (st == PFETCH && pc == PF - 1)         pf_done <= pf_done + PF;
        end
    end

endmodule