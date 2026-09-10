//────────────────────────────────────────────────────────────────────────────
// wb_diff.v — M13 v1 层 KDA diff 写回件 (P1 状态搬移件)
//
// 契约(基线 §5 写回协议 v0 / tools/sim_layer_flow.py):
//   v1 层每 token 秩1 diff = 96 头 × (k[128] + v[128]) × BF16 2B = 49,152B
//   帧 = 8B 头(层号+类型 diff + 长度 LE) + payload → 每帧 49,160B
//   严格层序(token 内 0..68), 层完工 = token 完成 barrier, round++ 后下一 token
//   每帧尾 层推进 / token 末帧 → token_done (host ACK 才许下一 token 头)
//   DMA 弹性 FIFO credit 门限: 无信用挂起记 stall; 恢复后续推 (FIFO 128KB ≥ 单笔)
//   无量化无 pass0 (BF16 原字节), order_bad 每帧首元素校验流序
// 时序: 元素吸收(1 拍 ele_valid) → 2 拍字节推 (lo = ele[7:0], hi = ele[15:8])
//────────────────────────────────────────────────────────────────────────────
module wb_diff #(
    parameter NL1 = 69,          // v1 层数
    parameter HEADS = 96,
    parameter D = 128,
    parameter ELEM_PER_HEAD = D + D,           // k+v
    parameter DIFF_B = HEADS * ELEM_PER_HEAD * 2,  // 49,152B
    parameter ELEM_T  = HEADS * ELEM_PER_HEAD     // 24,576 words
)(
    input  clk, rst_n, go,
    input  [7:0]  s_lay,          // 本帧期望层号 (流序校验)
    input         ele_valid,      // 元素就绪 (combinational source 纪律)
    input  [15:0] s_elem,         // BF16 元素
    input         credit,         // DMA 弹性 FIFO 信用
    output reg f_valid, f_we,     // 推 1B/拍
    output reg [7:0] f_b,
    output reg busy, token_done, order_bad,
    output reg [31:0] bytes_written, frames, stalls
);
    localparam [15:0] FRAME_B = 8 + DIFF_B;          // 49,160
    localparam [7:0] TYPE_V1 = 8'h11;

    reg session;
    reg [1:0] st;
    localparam ST_IDLE = 2'd0, ST_P1 = 2'd1;

    reg [5:0]  round;      // token 序号 (源值区分轮次)
    reg [6:0]  pl_lay;     // 0..68
    reg [15:0] pl_elem;    // 元素计数 0..24575
    reg [15:0] q;          // 帧内字节槽 0..49159
    reg [1:0]  ws;         // 0=推字节 / 1=等元素
    reg        pend;       // 字节就绪待推
    reg [7:0]  pq;         // 待推字节
    reg [15:0] elem;       // 当前元素 (hi 字节源)

    // 帧头第 k 字节
    function [7:0] hl(input integer k);
        begin
            case (k)
                0: hl = pl_lay[7:0];
                1: hl = TYPE_V1;
                2: hl = 8'd0;
                3: hl = 8'd0;
                4: hl = DIFF_B[7:0];
                5: hl = DIFF_B[15:8];
                6: hl = DIFF_B[23:16];
                7: hl = DIFF_B[31:24];
                default: hl = 8'h00;
            endcase
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            session <= 1'b0; busy <= 1'b0; st <= ST_IDLE;
            round  <= 0; pl_lay <= 0; pl_elem <= 0; q <= 0; ws <= 0;
            pend <= 0; pq <= 0; elem <= 0;
            f_valid <= 0; f_we <= 0; f_b <= 0;
            bytes_written <= 0; frames <= 0; stalls <= 0;
            order_bad <= 0; token_done <= 1'b0;
        end
        else begin
            f_valid <= 1'b0; f_we <= 1'b0; token_done <= 1'b0;

            case (st)
                ST_IDLE: begin
                    if (go) begin
                        session <= 1'b1; busy <= 1'b1; st <= ST_P1;
                        pl_lay <= 0; pl_elem <= 0; q <= 0; ws <= 0;
                        pend   <= 1'b1; pq <= 0;        // 头第0字节 = 层0
                        order_bad <= 1'b0;
                    end
                end

                ST_P1: begin
                    case (ws)
                        // 字节就绪 → 推 (有信用才推)
                        2'd0: if (pend) begin
                            if (credit) begin
                                f_valid <= 1'b1; f_we <= 1'b1; f_b <= pq;
                                bytes_written <= bytes_written + 1;
                                pend <= 1'b0;
                                q    <= q + 1;
                                if (q + 1 < 8) begin
                                    pend <= 1'b1;               // 下一头字节
                                    pq   <= hl(q + 1);
                                    ws   <= 2'd0;
                                end
                                else if ((q + 1 - 8) % 2 == 1) begin
                                    pend <= 1'b1;               // 元素 hi 字节
                                    pq   <= elem[15:8];
                                    ws   <= 2'd0;
                                end
                                else
                                    ws   <= 2'd1;               // 新元素待吸收
                            end
                            else
                                stalls <= stalls + 1;
                        end

                        // 等元素 (每 2 字节 = lo/hi)
                        2'd1: if (ele_valid) begin
                            if (pl_elem == 0 && s_lay != pl_lay) order_bad <= 1'b1;
                            pl_elem <= pl_elem + 1;
                            elem    <= s_elem;
                            pend    <= 1'b1;
                            pq      <= s_elem[7:0];        // lo
                            ws      <= 2'd0;
                        end
                    endcase

                    // 帧尾 (末字节推出才推进层; 等待期不误触发)
                    if (q + 1 == FRAME_B && pend) begin
                        frames  <= frames + 1;
                        pl_elem <= 0;
                        q       <= 0;
                        if (pl_lay + 1 == NL1) begin
                            st         <= ST_IDLE;
                            session    <= 1'b0;
                            busy       <= 1'b0;
                            token_done <= 1'b1;
                            round      <= round + 1;
                        end
                        else begin
                            pl_lay <= pl_lay + 1;
                            ws     <= 2'd0;
                            pend   <= 1'b1;
                            pq     <= pl_lay + 1;          // 头第0字节 = 新层号
                        end
                    end
                end
                default: st <= ST_IDLE;
            endcase
        end
    end
endmodule