//────────────────────────────────────────────────────────────────────────────
// kv_restore.v — M15 v2 层 KV 读回件 (P1 状态搬移件, 读侧)
//
// 契约(基线 §5 写回协议 v0 镜像):
//   decode 时 v2 层注意力消费 host 缓存的逐 token KV (append-only, 1K 窗)
//   读序 = 写序镜像: 每 token 一 go = 24 层帧严格层序 0..23, 每帧 552B =
//     8B 头[层号, 01 KV-append, 0,0, 544B 长 LE] + 512 latent INT8 + 32 rope 4bit
//   消费 = 吸收 kv_valid 字节流, 门限 credit(消费侧弹性背压):
//     !credit 时挂起记 stall, credit 回补后续吸 —— 不丢字节, 序不变
//   校验(本件契约 = 序/头/速): 头 8B 逐字段比对 → head_bad;
//   层号连进由 pl_lay 递增 + 头 byte0=层号 保证; barrier 保证 token 串行
//   层 23 帧末 = token 完成 token_done, host 收到 ACK 才发下一 token 头
// 吸收速度: 1B/拍 (kv_valid && credit)
//────────────────────────────────────────────────────────────────────────────
module kv_restore #(
    parameter NL     = 93,
    parameter NL2    = 24,
    parameter LATENT = 512,
    parameter ROPE   = 64
)(
    input  clk, rst_n, go, credit,
    input  kv_valid, input [7:0] s_kv,
    output reg busy, token_done, head_bad, output reg [7:0] round,
    output reg [31:0] bytes_consumed, frames, stalls
);
    localparam [15:0] FB = 8 + LATENT + ROPE/2;      // 552
    reg [1:0] st;
    localparam ST_IDLE = 2'd0, ST_RCV = 2'd1;
    reg [4:0]  pl_lay;    // 0..23
    reg [9:0]  q;         // 帧内字节 0..551

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= ST_IDLE; busy <= 0; token_done <= 1'b0;
            round <= 0; pl_lay <= 0; q <= 0;
            head_bad <= 0;
            bytes_consumed <= 0; frames <= 0; stalls <= 0;
        end
        else begin
            token_done <= 1'b0;
            case (st)
                ST_IDLE: if (go) begin
                    st <= ST_RCV; busy <= 1; pl_lay <= 0; q <= 0;
                end

                ST_RCV: if (kv_valid) begin
                    if (credit) begin
                        bytes_consumed <= bytes_consumed + 1;
                        // 头 8 字节逐字段校验 (字节0 = 层号 → 层序连带)
                        if (q < 8) begin
                            if (s_kv != exp_head(q)) head_bad <= 1;
                        end
                        if (q + 1 == FB) begin
                            frames <= frames + 1;
                            if (pl_lay + 1 == NL2) begin
                                st <= ST_IDLE; busy <= 0;
                                token_done <= 1; round <= round + 1;
                                pl_lay <= 0; q <= 0;
                            end
                            else begin
                                pl_lay <= pl_lay + 1; q <= 0;
                            end
                        end
                        else q <= q + 1;
                    end
                    else begin
                        // 消费侧无信用 → 挂起记 stall (字节仍有序, credit 回补后续吸)
                        stalls <= stalls + 1;
                    end
                end
                default: st <= ST_IDLE;
            endcase
        end
    end

    // 期望帧头字节 (字节0 = 该 v2 层的实际层号: n==NL2-1 → NL-1, 否则 4n+3 ——
    //  ≡ M14 写者实发头, 使 S 层帧与 KV 帧同号空间; 层序由 pl_lay 连进 + 号比对)
    function [7:0] exp_head(input integer k);
        reg [15:0] len;
        integer v2L;
        begin
            len = FB - 8;               // 544
            v2L = (pl_lay == NL2 - 1) ? (NL - 1) : (4 * pl_lay + 3);
            case (k)
                0: exp_head = v2L[7:0];
                1: exp_head = 8'h01;
                2: exp_head = 8'h00;
                3: exp_head = 8'h00;
                4: exp_head = len[7:0];
                5: exp_head = len[15:8];
                6: exp_head = 8'h00;
                7: exp_head = 8'h00;
                default: exp_head = 8'h00;
            endcase
        end
    endfunction
endmodule