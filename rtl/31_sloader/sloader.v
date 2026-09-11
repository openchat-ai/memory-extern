//────────────────────────────────────────────────────────────────────────────
// sloader.v — M16 S[L] 层流灌入件 (P1 状态搬移件, 读侧)
//
// 契约(基线 §4/§5):
//   层流节 = [S[L] 3MB 读][权重 632MB][S'[L] 3MB 写]; M13(wb_diff)是 S'[L] 写,
//   本件 = S[L] 读灌入 —— 板上零常驻, 算一层换一层
//   每 v1 层 S = 96 头 × 128×128 个 BFloat16 元素 = 3,145,728B; 每 token 69 v1 层
//   粒序 = 元素(2B)级, 严格 (层序 v1 asc → 头 0..95 → 头内 i 0..16383) 连进
//   吸收 = sel_valid 时吃, 门限 credit(灌入侧弹性背压): !credit 挂起记 stall,
//     回补后续吸 —— 不丢不序不乱
//   逐头完工 → head_done 单拍脉冲(供下游 tile-pool 双缓冲预取),
//   层完工 → layer_done(barrier), 第 69 层完工 → token_done → round++ 等 go
// 吸收速度: 1 元素/拍 (sel_valid && credit)
//────────────────────────────────────────────────────────────────────────────
module sloader #(
    parameter NL    = 93,
    parameter NL2   = 24,     // v2 层数 (确定 v1 掩码)
    parameter HEADS = 96,
    parameter DIM   = 128
)(
    input  clk, rst_n, go, credit,
    input  sel_valid, input [15:0] s_sel,
    output reg busy, token_done, layer_done, head_done,
    output reg [7:0] round,
    output reg [31:0] elems_loaded, layers, heads, stalls
);
    localparam integer HEAD_E  = DIM * DIM;              // 每头元素数
    localparam integer V1_N    = NL - NL2;               // 69 条 v1 层

    reg [1:0] st;
    localparam ST_IDLE = 2'd0, ST_LOAD = 2'd1;
    reg [6:0] pl_l;      // v1 层序号 0..68
    reg [6:0] pl_h;      // 头 0..95
    reg [13:0] pl_i;     // 头内元素 0..16383 (全尺寸)

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= ST_IDLE; busy <= 0; token_done <= 0; layer_done <= 0; head_done <= 0;
            round <= 0; pl_l <= 0; pl_h <= 0; pl_i <= 0;
            elems_loaded <= 0; layers <= 0; heads <= 0; stalls <= 0;
        end
        else begin
            token_done <= 0; layer_done <= 0; head_done <= 0;
            case (st)
                ST_IDLE: if (go) begin
                    st <= ST_LOAD; busy <= 1; pl_l <= 0; pl_h <= 0; pl_i <= 0;
                end

                ST_LOAD: if (sel_valid) begin
                    if (credit) begin
                        elems_loaded <= elems_loaded + 1;
                        if (pl_i + 1 == HEAD_E) begin
                            // 本元素完成一个头
                            heads <= heads + 1;
                            head_done <= 1;
                            pl_i <= 0;
                            if (pl_h + 1 == HEADS) begin
                                // 同时完成该层
                                layers <= layers + 1;
                                layer_done <= 1;
                                pl_l <= pl_l + 1; pl_h <= 0;
                                if (pl_l + 1 == V1_N) begin
                                    // 同时完成该 token
                                    st <= ST_IDLE; busy <= 0;
                                    token_done <= 1; round <= round + 1;
                                    pl_l <= 0;
                                end
                            end
                            else pl_h <= pl_h + 1;
                        end
                        else pl_i <= pl_i + 1;
                    end
                    else stalls <= stalls + 1;
                end
                default: st <= ST_IDLE;
            endcase
        end
    end
endmodule