`default_nettype none
//────────────────────────────────────────────────────────────────────────────
// atile_pingpong.v — A-tile 双缓冲 (MAC 热池·GEMM 段, §6)
//
// 轨状态 0=FREE 1=FILLING 2=READY 3=READING (每轨一枚)。
// 显式角色制:
//   - f_start: 若有 FREE 轨则 claim 之(仅一轨可 READY/一轨可 READING,
//     双缓冲下最多一枚 READY 停车, claim 无二义)。
//   - frame_full -> READY 停车; 读完 -> FREE -> 可再 claim。
//   - read_active=0 时若见 READY 轨, 同拍 claim 续读 —— 级联无缝。
// 护栏1不覆写: st[fillr]==READY/READING -> f_ready=0
// 护栏2不空读: 无 READY/active -> r_valid=0, MAC 冒泡计数 bubbles
// r_data 组合直取, MAC 在 r_take 同沿采样。
//────────────────────────────────────────────────────────────────────────────
module atile_pingpong #(
    parameter DW     = 32,
    parameter TDEPTH = 64                // 每轨字数
)(
    input  wire         clk,
    input  wire         rst_n,

    input  wire         f_start,         // 引擎 claim 新帧(须 any_free=1 时确可)
    input  wire         f_valid,
    input  wire [DW-1:0] f_data,
    output wire         f_ready,
    output wire         f_sel,
    output wire         any_free,

    input  wire         r_take,
    output wire         r_valid,
    output wire [DW-1:0] r_data,
    output wire         r_frame_done,
    output wire         swap,
    output wire [IDX-1:0] r_addr,       // 读指针 (读控按词序配对/度量)

    output reg  [31:0]  frames_filled,
    output reg  [31:0]  frames_read,
    output reg  [31:0]  bubbles
);

    function integer clog2(input integer n);
        integer k;
        begin
            k = 0;
            while ((1 << k) < n) k = k + 1;
            clog2 = k;
        end
    endfunction

    localparam IDX = clog2(TDEPTH);
    reg [DW-1:0] A [0:TDEPTH-1];
    reg [DW-1:0] B [0:TDEPTH-1];

    reg [1:0] st [0:1];                  // 0=FREE 1=FILLING 2=READY 3=READING
    reg       fsel;                      // 填充轨
    reg       rrail;                     // 读轨
    reg       fill_active;
    reg       read_active;
    reg [IDX-1:0] fwc;
    reg [IDX-1:0] rwc;
    assign r_addr = rwc;

    wire fill_ok = f_valid && f_ready;
    assign f_ready  = fill_active && (st[fsel] != 2'd2) && (st[fsel] != 2'd3);
    assign any_free = !fill_active && (st[0] == 2'd0 || st[1] == 2'd0);
    assign f_sel    = fsel;

    wire r_taking  = r_take && r_valid;
    assign r_valid  = read_active;
    assign r_data   = rrail ? B[rwc] : A[rwc];

    wire frame_full   = fill_ok && (fwc == TDEPTH-1);
    wire frame_refill = r_taking && (rwc == TDEPTH-1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fsel <= 0; rrail <= 0;
            fill_active <= 0; read_active <= 0;
            fwc <= 0; rwc <= 0;
            st[0] <= 2'd0; st[1] <= 2'd0;
            frames_filled <= 0; frames_read <= 0; bubbles <= 0;
        end else begin
            //---- claim: 新帧 ----------
            if (f_start && !fill_active) begin
                if (st[0] == 2'd0) begin fsel <= 0; st[0] <= 2'd1; fill_active <= 1; end
                else if (st[1] == 2'd0) begin fsel <= 1; st[1] <= 2'd1; fill_active <= 1; end
                fwc <= 0;
            end

            //---- 写侧 ----------
            if (fill_ok) begin
                if (fsel) B[fwc] <= f_data; else A[fwc] <= f_data;
                if (frame_full) begin
                    st[fsel]      <= 2'd2;         // READY 停车
                    fill_active   <= 0;
                    fwc           <= 0;
                    frames_filled <= frames_filled + 1;
                end else begin
                    fwc <= fwc + 1;
                end
            end

            //---- 读侧: 级联 claim / 推进 / 收尾 ----------
            if (!read_active) begin
                if (st[0] == 2'd2) begin rrail <= 0; st[0] <= 2'd3; read_active <= 1; rwc <= 0; end
                else if (st[1] == 2'd2) begin rrail <= 1; st[1] <= 2'd3; read_active <= 1; rwc <= 0; end
            end else if (r_taking) begin
                if (frame_refill) begin
                    st[rrail]  <= 2'd0;            // FREE
                    read_active <= 0;
                    rwc        <= 0;
                    frames_read <= frames_read + 1;
                end else begin
                    rwc <= rwc + 1;
                end
            end

            //---- 空读冒泡 ----------
            if (r_take && !r_valid) bubbles <= bubbles + 1;
        end
    end

    assign swap         = frame_full;
    assign r_frame_done = frame_refill;

endmodule
`default_nettype wire