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
    parameter NBEAT = 1024,   // 每块拍数(4096/4)
    parameter MAXENT = 4,     // 目录块可枚举的最大条目数(根目录/子目录各自)
    parameter TABN   = 8,     // 收集映射表容量(含递归展开, >MAXENT)
    parameter MAXDEPTH = 4    // extent 索引递归最大下钻深度(防死循环)
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
    output reg [31:0]  root_ee_start_o,
    // 阶段4: 目录块逐条枚举结果表
    output reg [31:0]  out_ino    [0:MAXENT-1],
    output reg [7:0]   out_ftype  [0:MAXENT-1],
    output reg [7:0]   out_nlen   [0:MAXENT-1],
    output reg [23:0]  out_name3  [0:MAXENT-1],
    output reg [$clog2(MAXENT+1)-1:0] out_count,
    // 阶段5: 首个文件 inode → extent(物理块) 输出
    output reg [31:0]  f_ino_o,
    output reg [15:0]  f_mode_o,
    output reg [31:0]  f_size_lo_o,
    output reg [31:0]  f_ebe_o,
    output reg [15:0]  f_elen_o,
    output reg [31:0]  f_estart_o,
    // 阶段6: depth>0 索引递归 → 子 extent 块叶输出
    output reg [31:0]  s_ebe_o,
    output reg [15:0]  s_elen_o,
    output reg [31:0]  s_estart_o,
    // 阶段7: 全文件 inode → 内联叶收集成"文件→物理块"映射表
    output reg [31:0]  ext_ino_o    [0:TABN-1],
    output reg [31:0]  ext_ebe_o    [0:TABN-1],
    output reg [15:0]  ext_elen_o   [0:TABN-1],
    output reg [31:0]  ext_estart_o [0:TABN-1],
    output reg [$clog2(TABN+1)-1:0] ext_count_o,

    // ---- 阶段8: 外置表 RAM(扫描写入, 供 cache 查询) ----
    output reg [31:0]  ram_ino    [0:TABN-1],
    output reg [31:0]  ram_ebe    [0:TABN-1],
    output reg [15:0]  ram_elen   [0:TABN-1],
    output reg [31:0]  ram_estart [0:TABN-1],
    // 查询请求(扫描完成后): 按 ino 线性查找, 返回文件→物理块段
    input  wire             qreq,
    input  wire [NB-1:0]    qino,
    output reg              qbusy, qvalid, qdone,
    output reg [31:0]       qebe,
    output reg [15:0]       qelen,
    output reg [31:0]       qestart
);

    localparam S_IDLE=0, S_SB_REQ=1, S_SB_WAIT=2, S_SB_FILL=3, S_SB_P=4,
               S_GD_REQ=5, S_GD_WAIT=6, S_GD_FILL=7, S_GD_P=8,
               S_IT_REQ=9, S_IT_WAIT=10, S_IT_FILL=11, S_IT_P=12,
               S_DIR_REQ=13, S_DIR_WAIT=14, S_DIR_FILL=15, S_DIR_P=16,
               S_DIR_LOOP=17,
               S_FILEREQ=18, S_FILEWAIT=19, S_FILEFILL=20, S_FILEP=21,
               S_SUBREQ=22, S_SUBWAIT=23, S_SUBFILL=24, S_SUBP=25,
               S_EXT_REQ=26, S_EXT_WAIT=27, S_EXT_FILL=28, S_EXT_LOOP=29,
               S_SUBLF=30,
               S_DMETCH=31, S_DMSCAN=32, S_DMREQ=33, S_DMWAIT=34, S_DMFILL=35, S_DMFILLP=36,
               S_DBRQ=37, S_DBWAIT=38, S_DBFILL=39, S_DBFILLP=40, S_DBLOOP=41,
               S_DMREQ2=42, S_DMWAIT2=43, S_DMFILL2=44, S_DMFILLP2=45, S_DMEXT=46,
               S_SIREQ=47, S_SIWAIT=48, S_SIFILL=49, S_SIP=50,
               S_DONE=51;
    reg [5:0] st;

    // 块缓冲: 32 位字数组(1024 字 = 4096B)
    reg [31:0] wbuf [0:1023];
    reg [15:0] beat;
    reg [NB-1:0] req_blk;
    integer k;

    // 内部: inode 表块号 / inode 尺寸 / 目录数据块号
    reg [NB-1:0] itbl_r;
    reg [15:0] isz_r;
    reg [NB-1:0] dir_blk_r;
    // 阶段6: 索引子 extent 块号
    reg [NB-1:0] subblk_r;
    // 阶段7: 全文件收集游标/表号
    reg [$clog2(MAXENT+1)-1:0] fidx;
    // 阶段9: 索引文件递归 — 当前文件 ino 暂存 / 子块内叶游标
    reg [31:0] cur_ino_r;
    reg [15:0] sleaf;
    reg [15:0] sentries;
    // 阶段10: 多层下钻深度计数
    reg [3:0] cdepth;
    // 阶段12: 索引块多路遍历(遍历索引块全部 ei_leaf)
    reg si;                                // 当前索引块内索引项游标
    reg [15:0] sientries;                  // 当前索引块条目数
    reg sinidx;                            // 是否正处索引块多路遍历中
    reg [NB-1:0] sidx_blk_r;               // 当前索引块号(下钻返回重读用)
    // 阶段11: 一级子目录递归
    reg [31:0] subdir_ino_r;      // 子目录 inode 号
    reg [NB-1:0] subd_blk_r;      // 子目录数据块号
    reg [31:0] subd_ino [0:MAXENT-1];  // 子目录内文件 ino 列表
    reg [$clog2(MAXENT+1)-1:0] subd_cnt;
    reg [$clog2(MAXENT+1)-1:0] sdcur;  // 子文件收集游标
    reg [15:0] sdpos;             // 子目录块枚举游标
    // 阶段8: 查询 FSM(独立于扫描主 FSM)
    reg qst;
    reg [$clog2(TABN+1)-1:0] qi;
    // 阶段4: 目录块枚举游标
    reg [15:0] dpos;
    reg [$clog2(MAXENT+1)-1:0] idx;
    // inode2 块内 word(固定 inode_size=256: offset=(2-1)*256=256 -> word 64)
    localparam INO2_WORD = 64;
    // 文件 inode(取目录首个, ino=12) 块内 word:
    //   inode号12 -> 组内下标11, per_block=16, blk偏移0, 块内偏移=(11%16)*256=2816 -> word 704
    localparam INO12_WORD = 704;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_IDLE; busy<=0; done<=0; err<=0;
            blk_fd_req<=0; blk_fd_blk<=0; beat<=0; req_blk<=0;
            itbl_r<=0; isz_r<=0; dir_blk_r<=0; dpos<=0; idx<=0; subblk_r<=0;
            fidx<=0; ext_count_o<=0;
            cur_ino_r<=0; sleaf<=0; sentries<=0; cdepth<=0;
            si<=0; sientries<=0; sinidx<=0; sidx_blk_r<=0;
            subdir_ino_r<=0; subd_blk_r<=0; subd_cnt<=0; sdcur<=0; sdpos<=0;
            qst<=0; qi<=0; qbusy<=0; qvalid<=0; qdone<=0;
            qebe<=0; qelen<=0; qestart<=0;
            blocks_per_grp_o<=0; inodes_per_grp_o<=0;
            inode_size_o<=0; inode_table_blk_o<=0;
            root_mode_o<=0; root_size_lo_o<=0;
            root_ee_magic_o<=0; root_ee_entries_o<=0;
            root_ee_block_o<=0; root_ee_len_o<=0; root_ee_start_o<=0;
            out_count<=0;
            f_ino_o<=0; f_mode_o<=0; f_size_lo_o<=0;
            f_ebe_o<=0; f_elen_o<=0; f_estart_o<=0;
            s_ebe_o<=0; s_elen_o<=0; s_estart_o<=0;
            for (k=0;k<MAXENT;k=k+1) begin
                out_ino[k]<=0; out_ftype[k]<=0; out_nlen[k]<=0; out_name3[k]<=0;
            end
            for (k=0;k<TABN;k=k+1) begin
                ext_ino_o[k]<=0; ext_ebe_o[k]<=0; ext_elen_o[k]<=0;
                ext_estart_o[k]<=0;
                ram_ino[k]<=0; ram_ebe[k]<=0; ram_elen[k]<=0; ram_estart[k]<=0;
            end
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
                    dir_blk_r       <= wbuf[INO2_WORD+15];
                    st <= S_DIR_REQ;
                end

                // ---- 读目录数据块(根 inode 首 extent 指向 ee_start), 解析首条目 ----
                S_DIR_REQ: begin
                    blk_fd_blk <= dir_blk_r;
                    req_blk    <= dir_blk_r;
                    blk_fd_req <= 1;
                    st <= S_DIR_WAIT;
                end
                S_DIR_WAIT: begin
                    if (blk_fd_ready) begin
                        blk_fd_req <= 0;
                        beat <= 0;
                        st <= S_DIR_FILL;
                    end
                end
                S_DIR_FILL: begin
                    if (blk_fd_dvalid && blk_fd_dblk==req_blk) begin
                        wbuf[beat] <= blk_fd_data;
                        if (beat==NBEAT-1) begin
                            st<=S_DIR_P;
                        end else beat<=beat+1;
                    end
                end
                // 目录块 fill 完成, 初始化枚举游标
                S_DIR_P: begin
                    dpos <= 0;
                    idx  <= 0;
                    st <= S_DIR_LOOP;
                end
                // 逐条解析 dir_entry2: ino/rec_len/name_len/ftype/名字节
                //   ino     -> wbuf[dpos>>2]   低32
                //   rec_len -> wbuf[(dpos>>2)+1][15:0]  name_len -> [23:16]  ftype -> [31:24]
                //   name 首3字节 -> wbuf[(dpos>>2)+2][23:0](小端)
                S_DIR_LOOP: begin
                    if (dpos>=1024 || idx>=MAXENT ||
                        wbuf[dpos>>2]==0) begin
                        out_count <= idx;
                        st <= S_EXT_REQ;
                    end else begin
                        out_ino[idx]   <= wbuf[dpos>>2];
                        out_ftype[idx] <= wbuf[(dpos>>2)+1][31:24];
                        out_nlen[idx]  <= wbuf[(dpos>>2)+1][23:16];
                        out_name3[idx] <= wbuf[(dpos>>2)+2][23:0];
                        dpos <= dpos + wbuf[(dpos>>2)+1][15:0];
                        idx  <= idx + 1;
                    end
                end

                // 阶段5: 重新读 inode 表块, 解析首个文件 inode(out_ino[0]) 的 extent
                S_FILEREQ: begin
                    blk_fd_blk <= itbl_r;
                    req_blk    <= itbl_r;
                    blk_fd_req <= 1;
                    st <= S_FILEWAIT;
                end
                S_FILEWAIT: begin
                    if (blk_fd_ready) begin
                        blk_fd_req <= 0;
                        beat <= 0;
                        st <= S_FILEFILL;
                    end
                end
                S_FILEFILL: begin
                    if (blk_fd_dvalid && blk_fd_dblk==req_blk) begin
                        wbuf[beat] <= blk_fd_data;
                        if (beat==NBEAT-1) begin
                            st<=S_FILEP;
                        end else beat<=beat+1;
                    end
                end
                // 文件 inode12 @块内 word INO12_WORD:
                //   i_mode   -> word INO12_WORD    低16
                //   i_size   -> word INO12_WORD+1  低32
                //   extent头 -> word INO12_WORD+10: magic低16/entries高16
                //              word INO12_WORD+11: depth高16
                //   leaf0/索引项 -> word INO12_WORD+13: ee_block / ei_block
                //              word INO12_WORD+14: ee_len低16 / ei_leaf
                //              word INO12_WORD+15: ee_start_lo
                S_FILEP: begin
                    f_ino_o     <= out_ino[0];
                    f_mode_o    <= wbuf[INO12_WORD][15:0];
                    f_size_lo_o <= wbuf[INO12_WORD+1];
                    if (wbuf[INO12_WORD+11][31:16] != 0) begin
                        // depth>0: 索引根, 递归读子 extent 块(ei_leaf)
                        subblk_r <= wbuf[INO12_WORD+14][15:0];
                        st <= S_SUBREQ;
                    end else begin
                        // depth=0: 内联叶(阶段5)
                        f_ebe_o    <= wbuf[INO12_WORD+13];
                        f_elen_o   <= wbuf[INO12_WORD+14][15:0];
                        f_estart_o <= wbuf[INO12_WORD+15];
                        st <= S_DONE;
                    end
                end

                // 阶段6: 读子 extent 块(subblk_r), 解析其内联叶
                S_SUBREQ: begin
                    blk_fd_blk <= subblk_r;
                    req_blk    <= subblk_r;
                    blk_fd_req <= 1;
                    st <= S_SUBWAIT;
                end
                S_SUBWAIT: begin
                    if (blk_fd_ready) begin
                        blk_fd_req <= 0;
                        beat <= 0;
                        st <= S_SUBFILL;
                    end
                end
                S_SUBFILL: begin
                    if (blk_fd_dvalid && blk_fd_dblk==req_blk) begin
                        wbuf[beat] <= blk_fd_data;
                        if (beat==NBEAT-1) begin
                            st<=S_SUBP;
                        end else beat<=beat+1;
                    end
                end
                // 子块 extent 头 @word0(magic低16/entries高16) word1(depth高16)
                // 叶 @word3 + i*3: ee_block; word4+ 低16 ee_len; word5+ ee_start
                // 阶段10/12: 索引块(depth>0)首次进入 → 多路遍历全部索引项(ei_leaf)
                S_SUBP: begin
                    if (wbuf[1][31:16]!=0) begin
                        if (sinidx==0) begin
                            if (cdepth+1>=MAXDEPTH) begin
                                err<=1; st<=S_DONE;
                            end else begin
                                sinidx <= 1;
                                si <= 0;
                                sientries <= wbuf[0][31:16];
                                sidx_blk_r <= subblk_r;       // 保存索引块号(重读用)
                                subblk_r   <= wbuf[4][15:0];  // 下钻索引项0 的 ei_leaf
                                cdepth <= cdepth + 1;
                                st <= S_SUBREQ;
                            end
                        end else begin
                            // 遍历中再遇索引块(嵌套加深, 暂不支撑) — 防御报错
                            err<=1; st<=S_DONE;
                        end
                    end else begin
                        // 叶子块(阶段9 原逻辑)
                        s_ebe_o    <= wbuf[3];
                        s_elen_o   <= wbuf[4][15:0];
                        s_estart_o <= wbuf[5];
                        sleaf    <= 0;
                        sentries <= wbuf[0][31:16];
                        st <= S_SUBLF;
                    end
                end
                // 阶段9: 遍历子块全部叶(索引文件递归收集)
                S_SUBLF: begin
                    if (sleaf>=sentries) begin
                        if (sinidx) begin
                            st <= S_SIREQ;           // 阶段12: 重读索引块取下一索引项
                        end else begin
                            fidx <= fidx + 1;
                            st <= S_EXT_LOOP;
                        end
                    end else begin
                        ext_ino_o[ext_count_o]    <= cur_ino_r;
                        ext_ebe_o[ext_count_o]    <= wbuf[3 + sleaf*3];
                        ext_elen_o[ext_count_o]   <= wbuf[4 + sleaf*3][15:0];
                        ext_estart_o[ext_count_o] <= wbuf[5 + sleaf*3];
                        ram_ino[ext_count_o]      <= cur_ino_r;
                        ram_ebe[ext_count_o]      <= wbuf[3 + sleaf*3];
                        ram_elen[ext_count_o]     <= wbuf[4 + sleaf*3][15:0];
                        ram_estart[ext_count_o]   <= wbuf[5 + sleaf*3];
                        ext_count_o               <= ext_count_o + 1;
                        sleaf <= sleaf + 1;
                    end
                end

                // 阶段12: 重读索引块, 取下一个索引项 ei_leaf 继续下钻(或直接退出)
                S_SIREQ: begin
                    blk_fd_blk <= sidx_blk_r;
                    req_blk    <= sidx_blk_r;
                    blk_fd_req <= 1;
                    st <= S_SIWAIT;
                end
                S_SIWAIT: begin
                    if (blk_fd_ready) begin
                        blk_fd_req <= 0;
                        beat <= 0;
                        st <= S_SIFILL;
                    end
                end
                S_SIFILL: begin
                    if (blk_fd_dvalid && blk_fd_dblk==req_blk) begin
                        wbuf[beat] <= blk_fd_data;
                        if (beat==NBEAT-1) begin
                            st <= S_SIP;
                        end else beat<=beat+1;
                    end
                end
                S_SIP: begin
                    if (si+1>=sientries) begin
                        // 全部索引项处理完 → 退出多路, 回主循环
                        sinidx <= 0;
                        fidx <= fidx + 1;
                        st <= S_EXT_LOOP;
                    end else begin
                        // 下钻下一个索引项 si+1 的 ei_leaf
                        si <= si + 1;
                        subblk_r <= wbuf[3 + (si+1)*3 + 1][15:0];
                        st <= S_SUBREQ;
                    end
                end

                // 阶段7: 读 inode 表块一次, 遍历结果表全部文件 → 收集 depth=0 内联叶
                S_EXT_REQ: begin
                    blk_fd_blk <= itbl_r;
                    req_blk    <= itbl_r;
                    blk_fd_req <= 1;
                    st <= S_EXT_WAIT;
                end
                S_EXT_WAIT: begin
                    if (blk_fd_ready) begin
                        blk_fd_req <= 0;
                        beat <= 0;
                        st <= S_EXT_FILL;
                    end
                end
                S_EXT_FILL: begin
                    if (blk_fd_dvalid && blk_fd_dblk==req_blk) begin
                        wbuf[beat] <= blk_fd_data;
                        if (beat==NBEAT-1) begin
                            fidx<=0; ext_count_o<=0; st<=S_EXT_LOOP;
                        end else beat<=beat+1;
                    end
                end
                // 逐文件: word_base=((ino-1)%16)*64 (isz=256, per_block=16)
                //   depth=0 内联叶 → ext_*[fidx]   (depth>0 索引文件跳过)
                S_EXT_LOOP: begin
                    if (fidx>=out_count) begin
                        st <= S_DMETCH;
                    end else if (out_ftype[fidx]==8'd2) begin
                        fidx <= fidx + 1;          // 跳过子目录条目(阶段11 单独递归)
                        st <= S_EXT_LOOP;
                    end else begin
                        if (wbuf[(((out_ino[fidx]-1)&15)*64)+11][31:16]==0) begin
                            ext_ino_o[ext_count_o]    <= out_ino[fidx];
                            ext_ebe_o[ext_count_o]    <= wbuf[(((out_ino[fidx]-1)&15)*64)+13];
                            ext_elen_o[ext_count_o]   <= wbuf[(((out_ino[fidx]-1)&15)*64)+14][15:0];
                            ext_estart_o[ext_count_o] <= wbuf[(((out_ino[fidx]-1)&15)*64)+15];
                            // 阶段8: 同步落外置表 RAM
                            ram_ino[ext_count_o]      <= out_ino[fidx];
                            ram_ebe[ext_count_o]      <= wbuf[(((out_ino[fidx]-1)&15)*64)+13];
                            ram_elen[ext_count_o]     <= wbuf[(((out_ino[fidx]-1)&15)*64)+14][15:0];
                            ram_estart[ext_count_o]   <= wbuf[(((out_ino[fidx]-1)&15)*64)+15];
                            ext_count_o               <= ext_count_o + 1;
                            fidx <= fidx + 1;
                        end else begin
                            // 阶段9/10: depth>0 索引文件 — 递归下钻 ei_leaf 子块
                            cur_ino_r <= out_ino[fidx];
                            subblk_r  <= wbuf[(((out_ino[fidx]-1)&15)*64)+14][15:0];
                            cdepth <= 0;
                            st <= S_SUBREQ;
                        end
                    end
                end

                // ===== 阶段11: 一级子目录递归 =====
                // S_DMETCH/SCAN: 在根 out_ftype 里找第一个 type=2(目录) 条目
                S_DMETCH: begin
                    sdcur <= 0;
                    st <= S_DMSCAN;
                end
                S_DMSCAN: begin
                    if (sdcur>=out_count || out_ftype[sdcur]==8'd2) begin
                        if (sdcur>=out_count) begin
                            st <= S_DONE;                       // 无子目录
                        end else begin
                            subdir_ino_r <= out_ino[sdcur];
                            st <= S_DMREQ;                      // 读块4 取子目录数据块
                        end
                    end else begin
                        sdcur <= sdcur + 1;
                    end
                end
                S_DMREQ: begin
                    blk_fd_blk <= itbl_r; req_blk <= itbl_r;
                    blk_fd_req <= 1;
                    st <= S_DMWAIT;
                end
                S_DMWAIT: begin
                    if (blk_fd_ready) begin
                        blk_fd_req <= 0; beat <= 0;
                        st <= S_DMFILL;
                    end
                end
                S_DMFILL: begin
                    if (blk_fd_dvalid && blk_fd_dblk==req_blk) begin
                        wbuf[beat] <= blk_fd_data;
                        if (beat==NBEAT-1) begin
                            st <= S_DMFILLP;
                        end else beat<=beat+1;
                    end
                end
                S_DMFILLP: begin
                    // 子目录 inode 内联叶(depth=0) → 数据块 = ee_start(word+15)
                    subd_blk_r <= wbuf[(((subdir_ino_r-1)&15)*64)+15];
                    sdcur <= 0; subd_cnt <= 0;
                    st <= S_DBRQ;
                end
                S_DBRQ: begin
                    blk_fd_blk <= subd_blk_r; req_blk <= subd_blk_r;
                    blk_fd_req <= 1;
                    st <= S_DBWAIT;
                end
                S_DBWAIT: begin
                    if (blk_fd_ready) begin
                        blk_fd_req <= 0; beat <= 0;
                        st <= S_DBFILL;
                    end
                end
                S_DBFILL: begin
                    if (blk_fd_dvalid && blk_fd_dblk==req_blk) begin
                        wbuf[beat] <= blk_fd_data;
                        if (beat==NBEAT-1) begin
                            st <= S_DBFILLP;
                        end else beat<=beat+1;
                    end
                end
                S_DBFILLP: begin
                    sdpos <= 0;
                    st <= S_DBLOOP;
                end
                // 枚举子目录块内条目(同 dir_entry2 格式), 收集 ftype=1 文件
                S_DBLOOP: begin
                    if (sdpos>=1024 || subd_cnt>=MAXENT ||
                        wbuf[sdpos>>2]==0) begin
                        st <= S_DMREQ2;            // 去收集子文件 extent
                    end else begin
                        if (wbuf[(sdpos>>2)+1][31:24]==8'd1) begin
                            subd_ino[subd_cnt] <= wbuf[sdpos>>2];
                            subd_cnt <= subd_cnt + 1;
                        end
                        sdpos <= sdpos + wbuf[(sdpos>>2)+1][15:0];
                    end
                end
                S_DMREQ2: begin
                    blk_fd_blk <= itbl_r; req_blk <= itbl_r;
                    blk_fd_req <= 1; sdcur <= 0;
                    st <= S_DMWAIT2;
                end
                S_DMWAIT2: begin
                    if (blk_fd_ready) begin
                        blk_fd_req <= 0; beat <= 0;
                        st <= S_DMFILL2;
                    end
                end
                S_DMFILL2: begin
                    if (blk_fd_dvalid && blk_fd_dblk==req_blk) begin
                        wbuf[beat] <= blk_fd_data;
                        if (beat==NBEAT-1) begin
                            st <= S_DMFILLP2;
                        end else beat<=beat+1;
                    end
                end
                S_DMFILLP2: begin
                    st <= S_DMEXT;
                end
                // 子目录文件: 解析内联叶(depth=0) 续写 ext/RAM 表
                S_DMEXT: begin
                    if (sdcur>=subd_cnt) begin
                        st <= S_DONE;
                    end else begin
                        ext_ino_o[ext_count_o]    <= subd_ino[sdcur];
                        ext_ebe_o[ext_count_o]    <= wbuf[(((subd_ino[sdcur]-1)&15)*64)+13];
                        ext_elen_o[ext_count_o]   <= wbuf[(((subd_ino[sdcur]-1)&15)*64)+14][15:0];
                        ext_estart_o[ext_count_o] <= wbuf[(((subd_ino[sdcur]-1)&15)*64)+15];
                        ram_ino[ext_count_o]      <= subd_ino[sdcur];
                        ram_ebe[ext_count_o]      <= wbuf[(((subd_ino[sdcur]-1)&15)*64)+13];
                        ram_elen[ext_count_o]     <= wbuf[(((subd_ino[sdcur]-1)&15)*64)+14][15:0];
                        ram_estart[ext_count_o]   <= wbuf[(((subd_ino[sdcur]-1)&15)*64)+15];
                        ext_count_o               <= ext_count_o + 1;
                        sdcur <= sdcur + 1;
                    end
                end

                S_DONE: begin
                    busy<=0; done<=1;
                    st<=S_IDLE;
                end
                default: st<=S_DONE;
            endcase
        end
    end

    // ---- 阶段8: 独立查询 FSM — 按 ino 线性遍历外置表 RAM, 返回文件→物理块段 ----
    // 时序动态索引读 reg 数组(同 wbuf 模式)已验证可行; 避免组合 for 遍历(组合环 bug)。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            qst<=0; qi<=0; qbusy<=0; qvalid<=0; qdone<=0;
            qebe<=0; qelen<=0; qestart<=0;
        end else begin
            case (qst)
                0: begin
                    if (qreq && !qbusy) begin
                        qbusy<=1; qi<=0; qvalid<=0; qdone<=0;
                        qst<=1;
                    end
                end
                1: begin
                    if (qi>=ext_count_o) begin
                        qdone<=1; qbusy<=0; qst<=0;   // 未找到
                    end else if (ram_ino[qi]==qino) begin
                        qvalid<=1; qdone<=1; qbusy<=0;
                        qebe<=ram_ebe[qi];
                        qelen<=ram_elen[qi];
                        qestart<=ram_estart[qi];
                        qst<=0;
                    end else begin
                        qi<=qi+1;
                    end
                end
            endcase
        end
    end

endmodule