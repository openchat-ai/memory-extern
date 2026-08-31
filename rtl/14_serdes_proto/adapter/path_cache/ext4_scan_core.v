// ============================================================================
// ext4_scan_core.v — RTL ext4 扫描 · 阶段1: superblock/组描述符解析(可综合)
//
// 从磁盘块流灌入块0/块1, 解析 superblock 与组0 描述符关键字段并输出。
// 目的: 打通"块流->字节游标->字段抽取"的 RTL 解析链路, 后续阶段逐级扩展。
//
// 磁盘块读(窄总线 DATAW=32bit * NBEAT=32 拍 = 4096B/块):
//   请求: blk_fd_req + blk_fd_blk;  blk_fd_ready 握手
//   数据: blk_fd_dvalid + blk_fd_data[31:0] + blk_fd_dblk —— 每块连送 32 拍
//
// 块缓冲用 32 位字数组 wbuf[0:1023] (integer), 时序读取经 iverilog 验证可用;
// 字段大多 4 字节对齐, 直接取整字或取低 16 位。
// ============================================================================
`timescale 1ns/1ps

module ext4_scan_core #(
    parameter NB    = 16,     // 块号位宽
    parameter DATAW = 32,     // 数据拍位宽(4 字节)
    parameter NBEAT = 1024    // 每块拍数(4096/4)
)(
    input  wire             clk, rst_n,
    input  wire             go,
    output reg              busy, done, err,

    // ---- 块读请求 ----
    output reg              blk_fd_req,
    output reg  [NB-1:0]    blk_fd_blk,
    input  wire             blk_fd_ready,
    // ---- 块数据 ----
    input  wire             blk_fd_dvalid,
    input  wire [DATAW-1:0] blk_fd_data,
    input  wire [NB-1:0]    blk_fd_dblk,

    // ---- 解析输出 ----
    output reg [31:0]  blocks_per_grp_o,
    output reg [31:0]  inodes_per_grp_o,
    output reg [15:0]  inode_size_o,
    output reg [NB-1:0] inode_table_blk_o,
    // 阶段2: 根 inode(2) 解析输出
    output reg [15:0]  root_mode_o,
    output reg [31:0]  root_size_lo_o,
    output reg [15:0]  root_ee_magic_o,
    output reg [15:0]  root_ee_entries_o,
    output reg [31:0]  root_ee_block_o,
    output reg [15:0]  root_ee_len_o,
    output reg [31:0]  root_ee_start_o
);

    localparam S_IDLE=0, S_SB_REQ=1, S_SB_WAIT=2, S_SB_FILL=3, S_SB_P=4,
               S_GD_REQ=5, S_GD_WAIT=6, S_GD_FILL=7, S_GD_P=8,
               S_IT_REQ=9, S_IT_WAIT=10, S_IT_FILL=11, S_IT_P=12, S_DONE=13;
    reg [4:0] st;

    // 块缓冲: 32 位字数组(1024 字 = 4096B)
    reg [31:0] wbuf [0:1023];
    reg [15:0] beat;
    reg [NB-1:0] req_blk;
    integer k;

    // 阶段2 内部: inode 表块号 / inode 尺寸
    reg [NB-1:0] itbl_r;
    reg [15:0] isz_r;
    // inode2 块内 word(固定 inode_size=256: offset=(2-1)*256=256 -> word 64)
    localparam INO2_WORD = 64;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_IDLE; busy<=0; done<=0; err<=0;
            blk_fd_req<=0; blk_fd_blk<=0; beat<=0; req_blk<=0;
            itbl_r<=0; isz_r<=0;
            blocks_per_grp_o<=0; inodes_per_grp_o<=0;
            inode_size_o<=0; inode_table_blk_o<=0;
            root_mode_o<=0; root_size_lo_o<=0;
            root_ee_magic_o<=0; root_ee_entries_o<=0;
            root_ee_block_o<=0; root_ee_len_o<=0; root_ee_start_o<=0;
        end else begin
            case (st)
                S_IDLE: begin
                    busy<=1; done<=0; err<=0;
                    st<=S_SB_REQ;
                end

                // ---- 读块0(superblock) ----
                S_SB_REQ: begin
                    blk_fd_blk <= 0;
                    req_blk    <= 0;
                    blk_fd_req <= 1;
                    st <= S_SB_WAIT;
                end
                S_SB_WAIT: begin
                    if (blk_fd_ready) begin
                        blk_fd_req <= 0;
                        beat <= 0;
                        st <= S_SB_FILL;
                    end
                end
                S_SB_FILL: begin
                    if (blk_fd_dvalid && blk_fd_dblk==req_blk) begin
                        wbuf[beat] <= blk_fd_data;      // 每拍存一个字(4B)
                        if (beat==NBEAT-1) begin
                            st<=S_SB_P;
                        end else beat<=beat+1;
                    end
                end
                // superblock 字段(块0 偏移1024 = 字索引 256):
                //   bpg@0x28 -> word 256+0x28/4=256+10=266
                //   ipg@0x2C -> word 267
                //   inode_size@0x58 -> word 256+0x16=278, 取低16位
                S_SB_P: begin
                    blocks_per_grp_o <= wbuf[266];
                    inodes_per_grp_o <= wbuf[267];
                    inode_size_o     <= wbuf[278][15:0];
                    isz_r            <= wbuf[278][15:0];
                    st <= S_GD_REQ;
                end

                // ---- 读块1(组0 描述符) ----
                S_GD_REQ: begin
                    blk_fd_blk <= 1;
                    req_blk    <= 1;
                    blk_fd_req <= 1;
                    st <= S_GD_WAIT;
                end
                S_GD_WAIT: begin
                    if (blk_fd_ready) begin
                        blk_fd_req <= 0;
                        beat <= 0;
                        st <= S_GD_FILL;
                    end
                end
                S_GD_FILL: begin
                    if (blk_fd_dvalid && blk_fd_dblk==req_blk) begin
                        wbuf[beat] <= blk_fd_data;
                        if (beat==NBEAT-1) begin
                            st<=S_GD_P;
                        end else beat<=beat+1;
                    end
                end
                // bg_inode_table_lo @ desc偏移0x08 = word 2
                S_GD_P: begin
                    inode_table_blk_o <= wbuf[2];
                    itbl_r            <= wbuf[2];
                    st <= S_IT_REQ;
                end

                // ---- 读 inode 表块, 解析根 inode(2) ----
                S_IT_REQ: begin
                    blk_fd_blk <= itbl_r;
                    req_blk    <= itbl_r;
                    blk_fd_req <= 1;
                    st <= S_IT_WAIT;
                end
                S_IT_WAIT: begin
                    if (blk_fd_ready) begin
                        blk_fd_req <= 0;
                        beat <= 0;
                        st <= S_IT_FILL;
                    end
                end
                S_IT_FILL: begin
                    if (blk_fd_dvalid && blk_fd_dblk==req_blk) begin
                        wbuf[beat] <= blk_fd_data;
                        if (beat==NBEAT-1) begin
                            st<=S_IT_P;
                        end else beat<=beat+1;
                    end
                end
                // 根 inode2 @块内 word INO2_WORD:
                //   i_mode   -> word INO2_WORD   低16
                //   i_size   -> word INO2_WORD+1 低32
                //   extent头 -> word INO2_WORD+0x28/4=INO2_WORD+10: magic低16/entries高16
                //   leaf0    -> word INO2_WORD+52/4=INO2_WORD+13: ee_block
                //              word INO2_WORD+14: ee_len低16
                //              word INO2_WORD+15: ee_start (lo32)
                S_IT_P: begin
                    root_mode_o     <= wbuf[INO2_WORD][15:0];
                    root_size_lo_o  <= wbuf[INO2_WORD+1];
                    root_ee_magic_o <= wbuf[INO2_WORD+10][15:0];
                    root_ee_entries_o<= wbuf[INO2_WORD+10][31:16];
                    root_ee_block_o <= wbuf[INO2_WORD+13];
                    root_ee_len_o   <= wbuf[INO2_WORD+14][15:0];
                    root_ee_start_o <= wbuf[INO2_WORD+15];
                    st <= S_DONE;
                end

                S_DONE: begin
                    busy<=0; done<=1;
                    st<=S_IDLE;
                end
                default: st<=S_DONE;
            endcase
        end
    end

endmodule