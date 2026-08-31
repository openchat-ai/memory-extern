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
    output reg [NB-1:0] inode_table_blk_o
);

    localparam S_IDLE=0, S_SB_REQ=1, S_SB_WAIT=2, S_SB_FILL=3, S_SB_P=4,
               S_GD_REQ=5, S_GD_WAIT=6, S_GD_FILL=7, S_GD_P=8, S_DONE=9;
    reg [3:0] st;

    // 块缓冲: 32 位字数组(1024 字 = 4096B)
    reg [31:0] wbuf [0:1023];
    reg [15:0] beat;
    reg [NB-1:0] req_blk;
    integer k;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_IDLE; busy<=0; done<=0; err<=0;
            blk_fd_req<=0; blk_fd_blk<=0; beat<=0; req_blk<=0;
            blocks_per_grp_o<=0; inodes_per_grp_o<=0;
            inode_size_o<=0; inode_table_blk_o<=0;
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