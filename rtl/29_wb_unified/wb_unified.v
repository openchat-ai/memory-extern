//────────────────────────────────────────────────────────────────────────────
// wb_unified.v — M14 统一写回引擎 (P1 状态搬移件)
//
// 契约(基线 §5 写回协议 v0 / tools/sim_layer_flow.py build_events 执行序):
//   每 token 一 go = 93 层帧严格层序 0..92:
//     v1 层(l%4==3 与末层之外) → 秩1 diff 帧:   8B头 + 96×(k128+v128)×2B = 49,160B
//     v2 层(l%4==3 或末层 92)   → KV append 帧: 8B头 + 512 latent INT8 + 32 rope = 552B
//   v2 = {3,7,...,87,91,92}, 69 v1 + 24 v2 = 93 (冻结花纹)
//   两遍: pass0 = 全 token v2 层 KV 一次过出 token 级 lat/rope 峰 → lscale/rscale
//         pass1 = 逐层建帧推字节(credit 门), 层尾推进, 层92完工 = token_done(barrier)
//   帧头 = [层号, 类型(0x11 diff / 0x01 kv), 0,0] + [长度 LE 4B]
//   源纪律: 三路组合源(diff/lat/rope)词序 ≡ 本件计数, 采样同拍
// 时序: v1 元素 = 吸收1拍 + 推2拍(lo/hi); v2 latent = 吸收1拍+推1拍; rope = 偶奇各1拍+推1拍
//────────────────────────────────────────────────────────────────────────────
module wb_unified #(
    parameter NL     = 93,              // 层总数 0..92
    parameter NL2    = 24,              // v2 层数 (冻结花纹)
    parameter LATENT = 512,
    parameter ROPE   = 64,
    parameter HEADS  = 96,
    parameter D      = 128
)(
    input  clk, rst_n, go, credit,
    input  [7:0]  s_lay,
    input         diff_valid,  input [15:0] s_elem,
    input         lat_valid,   input [7:0]  s_lat,
    input         rope_valid,  input [7:0]  s_rope,
    output reg f_valid, f_we, output reg [7:0] f_b,
    output reg busy, token_done, order_bad, output reg [7:0] round,
    output reg [31:0] bytes_written, frames, stalls
);
    localparam [15:0] DIFF_B  = HEADS * (D + D) * 2;              // 49,152
    localparam [15:0] V2_FB   = 8 + LATENT + ROPE/2;              // 552
    localparam [15:0] P0_LAT_T = NL2 * LATENT;
    localparam [15:0] P0_ROPE_T= NL2 * ROPE;
    localparam [7:0] TYPE_V1 = 8'h11, TYPE_V2 = 8'h01;

    reg session;
    reg [1:0] st;
    localparam ST_IDLE = 2'd0, ST_P0 = 2'd1, ST_P1 = 2'd2;

    reg [6:0]  pl_lay;      // 0..92
    reg [14:0] pl_elem;     // v1 元素 0..24575
    reg [8:0]  pl_kvlat;    // v2 latent 0..511
    reg [5:0]  pl_kvrope;   // v2 rope 0..63
    reg [15:0] p0_lat, p0_rope;
    reg [7:0]  latmax, ropemax;
    reg [15:0] lscale, rscale;
    reg [15:0] q;           // 帧内字节槽
    reg [1:0]  ws;          // 0=推 / 1=等词 / 2=rope偶 / 3=rope奇
    reg        pend;
    reg [7:0]  pq;
    reg [15:0] elem;
    reg [3:0]  rope_ev;

    function integer is_v2(input integer l);
        begin is_v2 = (l % 4 == 3) || (l == NL - 1); end
    endfunction
    function integer fsz(input integer l);
        begin fsz = is_v2(l) ? V2_FB : 8 + DIFF_B; end
    endfunction
    function [7:0] hl(input integer k);
        integer vlen;
        begin
            vlen = is_v2(pl_lay) ? V2_FB - 8 : DIFF_B;
            case (k)
                0: hl = pl_lay[7:0];
                1: hl = is_v2(pl_lay) ? TYPE_V2 : TYPE_V1;
                2: hl = 8'd0;
                3: hl = 8'd0;
                4: hl = vlen[7:0];
                5: hl = vlen[15:8];
                6: hl = vlen[23:16];
                7: hl = vlen[31:24];
                default: hl = 8'h00;
            endcase
        end
    endfunction
    function [7:0] qlat8(input [7:0] v, input [15:0] s);
        reg [23:0] t;
        begin t = $unsigned(v)*s; qlat8 = (t + 64) >> 7; if (qlat8 > 8'd127) qlat8 = 8'd127; end
    endfunction
    function [3:0] qr4(input [7:0] v, input [15:0] s);
        reg [23:0] t;
        begin t = $unsigned(v)*s; qr4 = (t + 64) >> 7; if (qr4 > 4'd15) qr4 = 4'd15; end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            session <= 0; busy <= 0; st <= ST_IDLE; round <= 0;
            pl_lay<=0; pl_elem<=0; pl_kvlat<=0; pl_kvrope<=0;
            p0_lat<=0; p0_rope<=0; latmax<=0; ropemax<=0;
            lscale<=0; rscale<=0; q<=0; ws<=0;
            pend<=0; pq<=0; elem<=0; rope_ev<=0;
            f_valid<=0; f_we<=0; f_b<=0;
            bytes_written<=0; frames<=0; stalls<=0;
            order_bad<=0; token_done<=1'b0;
        end
        else begin
            f_valid <= 0; f_we <= 0; token_done <= 1'b0;

            case (st)
                ST_IDLE: if (go) begin
                    session <= 1; busy <= 1; st <= ST_P0;
                    p0_lat<=0; p0_rope<=0; latmax<=0; ropemax<=0;
                    order_bad <= 0;
                end

                // pass0: v2 层全 token KV 峰 → token 级 scale
                ST_P0: begin
                    if (lat_valid) begin
                        if (s_lat > latmax) latmax <= s_lat;
                        p0_lat <= p0_lat + 1;
                    end
                    if (rope_valid) begin
                        if (s_rope > ropemax) ropemax <= s_rope;
                        p0_rope <= p0_rope + 1;
                    end
                    if (p0_lat == P0_LAT_T && p0_rope == P0_ROPE_T) begin
                        lscale <= (latmax == 0) ? 1 : (16'd16256) / {8'd0, latmax};
                        rscale <= (ropemax == 0) ? 1 : (16'd1920) / {8'd0, ropemax};
                        pl_lay<=0; pl_elem<=0; pl_kvlat<=0; pl_kvrope<=0;
                        q<=0; ws<=0; pend<=1'b1; pq<=0;        // 头第0字节 = 层0
                        st <= ST_P1;
                    end
                end

                // pass1: 逐层建帧
                ST_P1: begin
                    case (ws)
                        2'd0: if (pend) begin
                            if (credit) begin
                                f_valid<=1; f_we<=1; f_b<=pq;
                                bytes_written <= bytes_written + 1;
                                pend <= 0;
                                q    <= q + 1;
                                if (q + 1 < 8) begin
                                    pend <= 1; pq <= hl(q + 1); ws <= 0;
                                end
                                else if (is_v2(pl_lay)) begin
                                    if (q + 1 - 8 < LATENT) ws <= 2'd1;     // latent 词
                                    else                     ws <= 2'd2;     // rope 偶位
                                end
                                else begin
                                    if ((q + 1 - 8) % 2 == 1) begin
                                        pend <= 1; pq <= elem[15:8]; ws <= 0;   // 元素 hi
                                    end
                                    else ws <= 2'd1;                            // 元素 lo 待吸收
                                end
                            end
                            else stalls <= stalls + 1;
                        end

                        // 等词: v1=元素(v2 latent 同槽) → lo 是吸收写, hi 在推侧
                        2'd1: begin
                            if (is_v2(pl_lay)) begin
                                if (lat_valid) begin
                                    if (pl_kvlat == 0 && s_lay != pl_lay) order_bad <= 1;
                                    pl_kvlat <= pl_kvlat + 1;
                                    pend <= 1; pq <= qlat8(s_lat, lscale); ws <= 0;
                                end
                            end
                            else if (diff_valid) begin
                                if (pl_elem == 0 && s_lay != pl_lay) order_bad <= 1;
                                pl_elem <= pl_elem + 1;
                                elem <= s_elem;
                                pend <= 1; pq <= s_elem[7:0]; ws <= 0;
                            end
                        end

                        2'd2: if (rope_valid) begin
                            rope_ev <= qr4(s_rope, rscale);
                            ws <= 2'd3;
                        end
                        2'd3: if (rope_valid) begin
                            pl_kvrope <= pl_kvrope + 2;
                            pend <= 1; pq <= {rope_ev, qr4(s_rope, rscale)}; ws <= 0;
                        end
                    endcase

                    // 帧尾 (末字节真推出才推进; 等待期不误触发)
                    if (q + 1 == fsz(pl_lay) && pend) begin
                        frames <= frames + 1;
                        pl_elem<=0; pl_kvlat<=0; pl_kvrope<=0; q<=0; ws<=0;
                        if (pl_lay + 1 == NL) begin
                            st <= ST_IDLE; session <= 0; busy <= 0;
                            token_done <= 1; round <= round + 1;
                        end
                        else begin
                            pl_lay <= pl_lay + 1;
                            pend <= 1; pq <= pl_lay + 1;    // 头第0字节 = 新层号
                        end
                    end
                end
                default: st <= ST_IDLE;
            endcase
        end
    end
endmodule