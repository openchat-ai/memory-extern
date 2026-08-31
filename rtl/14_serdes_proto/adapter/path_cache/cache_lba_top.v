// ============================================================================
// cache_lba_top.v — ext4_scan 例化接线: 扫描→自动转录 file2lba→cache 管线查询
//
// reset → 自动驱动 ext4_scan_core 扫描块源
// → 扫描 done 后读其 RAM 表
// → 转录 FSM 把目标文件(FILE_INO) extent 段写成 file2lba 配置帧
//   (CMD_CFG_LBA=0x50, 打 pipeline cmd_b)
// → lba_ready=1 后 pipeline 每字 tag=文件块号, wt_lba 组合直出绝对物理 LBA
//
// 仲裁: 转录帧独占 cmd_b, 外部命令走 cmd_a(转录期间外部不发)。
// ============================================================================

`timescale 1ns/1ps

module cache_lba_top #(
    parameter DW          = 32,
    parameter CW          = 32,
    parameter EXPERT_SLOTS= 8,
    parameter FILE_BLKW   = 8,
    parameter FILE_IDW    = 4,
    parameter FILES       = 4,
    parameter ENTRYS      = 8,
    parameter NB          = 16,
    parameter NBEAT       = 1024,
    parameter MAXENT      = 4,
    parameter TABN        = 8,
    parameter MAXDEPTH    = 4,
    parameter NDEP        = 4,
    parameter FILE_INO    = 14,
    parameter CMD_CFG_LBA = 8'h50
)(
    input  wire clk,
    input  wire rst_n,

    output wire [NB-1:0]    blk_fd_blk,
    output wire             blk_fd_req,
    input  wire             blk_fd_ready,
    input  wire             blk_fd_dvalid,
    input  wire [31:0]      blk_fd_data,
    input  wire [NB-1:0]    blk_fd_dblk,

    input  wire [47:0]      part_base,

    input  wire serdes_aligned,
    input  wire pcie_link_up,

    input  wire [DW-1:0]  st_a_data, input wire st_a_valid, output wire st_a_ready,
    input  wire [DW-1:0]  st_b_data, input wire st_b_valid, output wire st_b_ready,

    output wire [DW-1:0]  wt_data, output wire wt_valid, input wire wt_ready,
    output wire [47:0]    wt_lba,  output wire lba_fault,

    input  wire [CW-1:0]  cmd_a_data, input wire cmd_a_valid, output wire cmd_a_ready,
    input  wire [CW-1:0]  cmd_b_data, input wire cmd_b_valid, output wire cmd_b_ready,

    output reg  scan_busy, scan_done, lba_ready
);

    localparam XTAB = $clog2(TABN+1);

    // ================= ext4_scan_core =================
    wire          s_busy, s_done, s_err;
    wire [XTAB-1:0] s_extcnt;
    reg           scan_go;

    wire [31:0]  s_ri  [0:TABN-1];
    wire [31:0]  s_rebe[0:TABN-1];
    wire [15:0]  s_rele[0:TABN-1];
    wire [31:0]  s_re  [0:TABN-1];

    ext4_scan_core #(
        .NB(NB), .DATAW(32), .NBEAT(NBEAT),
        .MAXENT(MAXENT), .TABN(TABN), .MAXDEPTH(MAXDEPTH), .NDEP(NDEP)
    ) u_scan (
        .clk(clk), .rst_n(rst_n),
        .go(scan_go), .busy(s_busy), .done(s_done), .err(s_err),
        .blk_fd_req(blk_fd_req), .blk_fd_blk(blk_fd_blk),
        .blk_fd_ready(blk_fd_ready),
        .blk_fd_dvalid(blk_fd_dvalid), .blk_fd_data(blk_fd_data), .blk_fd_dblk(blk_fd_dblk),
        .blocks_per_grp_o(), .inodes_per_grp_o(), .inode_size_o(), .inode_table_blk_o(),
        .root_mode_o(), .root_size_lo_o(), .root_ee_magic_o(), .root_ee_entries_o(),
        .root_ee_block_o(), .root_ee_len_o(), .root_ee_start_o(),
        .out_ino(), .out_ftype(), .out_nlen(), .out_name3(), .out_count(),
        .f_ino_o(), .f_mode_o(), .f_size_lo_o(), .f_ebe_o(), .f_elen_o(), .f_estart_o(),
        .s_ebe_o(), .s_elen_o(), .s_estart_o(),
        .ext_ino_o(), .ext_ebe_o(), .ext_elen_o(), .ext_estart_o(), .ext_count_o(s_extcnt),
        .ram_ino(s_ri), .ram_ebe(s_rebe), .ram_elen(s_rele), .ram_estart(s_re),
        .qreq(1'b0), .qino(16'd0), .qblk(16'd0), .part_base(48'd0),
        .qbusy(), .qvalid(), .qdone(), .qebe(), .qelen(), .qestart(),
        .q_lba(), .q_fault()
    );

    // ================= cachectl_pipeline =================
    wire [DW-1:0] p_wt; wire p_wtv;
    wire [47:0]   p_lba; wire p_fault;
    wire          p_locked, p_sel;
    reg  [CW-1:0] xfer_cmd_d;
    reg           xfer_cmd_v;

    cachectl_pipeline #(
        .DW(DW), .CW(CW), .EXPERT_SLOTS(EXPERT_SLOTS),
        .FILE_BLKW(FILE_BLKW), .FILE_IDW(FILE_IDW), .FILES_N(FILES),
        .FILE_ID(0), .CMD_CFG_LBA(CMD_CFG_LBA)
    ) u_pipe (
        .clk(clk), .rst_n(rst_n),
        .serdes_aligned(serdes_aligned), .pcie_link_up(pcie_link_up),
        .st_in_a_data(st_a_data), .st_in_a_valid(st_a_valid), .st_in_a_ready(st_a_ready),
        .st_in_b_data(st_b_data), .st_in_b_valid(st_b_valid), .st_in_b_ready(st_b_ready),
        .cmd_a_data(cmd_a_data), .cmd_a_valid(cmd_a_valid), .cmd_a_ready(cmd_a_ready),
        .cmd_b_data(xfer_cmd_d), .cmd_b_valid(xfer_cmd_v), .cmd_b_ready(cmd_b_ready),
        .wt_data(p_wt), .wt_valid(p_wtv), .wt_ready(wt_ready),
        .wt_lba(p_lba), .lba_fault(p_fault),
        .path_locked(p_locked), .path_sel(p_sel),
        .loads(), .hits(), .misses(), .trun_hits(), .trunk_id_out()
    );
    assign wt_data  = p_wt;
    assign wt_valid = p_wtv;
    assign wt_lba   = p_lba;
    assign lba_fault= p_fault;

    // ================= 转录 FSM =================
    localparam TI=0, TS=1, TW=2, TSP=3, TF0=4, TF1=5, TD=6;
    reg [3:0] tst;
    reg [XTAB-1:0] sp_k;           // SPAN 遍历索引
    reg [3:0]  xc;                  // 目标文件 extent 段计数
    reg [15:0] xfsz;               // 目标文件总块数
    reg [7:0]  fs;                  // 帧序号
    reg [31:0] x_et [0:TABN-1];    // 转录缓存 estart
    reg [15:0] x_el [0:TABN-1];    // 转录缓存 elen

    function [31:0] hdr(input [7:0] r);
        hdr = {16'b0, r, CMD_CFG_LBA};
    endfunction

    // 当前帧内容(由 fs 计算)
    reg [7:0]  creg;
    reg [31:0] cdat;
    always @(*) begin
        creg = 0; cdat = 0;
        if (fs < 2) begin
            creg = fs[0] ? 8'h01 : 8'h00;
            cdat = fs[0] ? {16'b0, part_base[47:32]} : part_base[31:0];
        end else if (fs < 2 + 3*xc) begin
            // EXT[k], k=(fs-2)/3, m=(fs-2)%3
            case ((fs-2) % 3)
                0: begin creg = 8'h10 + 2*((fs-2)/3); cdat = x_et[(fs-2)/3]; end
                1: begin creg = 8'h11 + 2*((fs-2)/3); cdat = 0;              end
                2: begin creg = 8'h20 +   ((fs-2)/3); cdat = {16'b0, x_el[(fs-2)/3]}; end
            endcase
        end else begin
            case (fs - 2 - 3*xc)
                0: begin creg = 8'h30; cdat = 0; end
                1: begin creg = 8'h31; cdat = 0; end
                default: begin creg = 8'h40; cdat = {16'b0, xfsz}; end
            endcase
        end
    end

    wire [7:0] nframes = 2 + 3*xc + 3;

    always @(posedge clk) begin
        if (!rst_n) begin
            tst <= TI; scan_go <= 0;
            scan_busy <= 0; scan_done <= 0; lba_ready <= 0;
            xc <= 0; xfsz <= 0; sp_k <= 0; fs <= 0;
            xfer_cmd_v <= 0; xfer_cmd_d <= 0;
        end else begin
            xfer_cmd_v <= 0;
            case (tst)
                TI: begin
                    lba_ready <= 0; scan_done <= 0;
                    scan_go <= 1; tst <= TS;
                end
                TS: begin
                    scan_go <= 0; scan_busy <= 1;
                    tst <= TW;
                end
                TW: begin
                    if (s_done) begin
                        scan_busy <= 0; scan_done <= 1;
                        xc <= 0; xfsz <= 0; sp_k <= 0;
                        tst <= TSP;
                    end
                end
                TSP: begin
                    if (sp_k >= s_extcnt || sp_k >= TABN) begin
                        fs <= 0; tst <= TF0;
                    end else if (s_ri[sp_k] == FILE_INO) begin
                        x_et[xc] <= s_re[sp_k];
                        x_el[xc] <= s_rele[sp_k];
                        xfsz <= xfsz + s_rele[sp_k];
                        xc <= xc + 1;
                        sp_k <= sp_k + 1;
                    end else begin
                        sp_k <= sp_k + 1;
                    end
                end
                TF0: begin
                    if (fs >= nframes) begin
                        tst <= TD;
                    end else begin
                        xfer_cmd_d <= hdr(creg); xfer_cmd_v <= 1;
                        tst <= TF1;
                    end
                end
                TF1: begin
                    xfer_cmd_d <= cdat; xfer_cmd_v <= 1;
                    fs <= fs + 1;
                    tst <= TF0;
                end
                TD: begin
                    lba_ready <= 1;
                    tst <= TI;   // 复位后可重扫
                end
                default: tst <= TI;
            endcase
        end
    end

endmodule
