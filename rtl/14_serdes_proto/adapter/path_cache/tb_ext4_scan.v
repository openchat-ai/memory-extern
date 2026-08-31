// tb_ext4_scan.v — 验证 ext4_scan_core 阶段1(superblock/组描述符解析)
// 用合成 ext4 镜像布局喂给 RTL, 断言 bpg/ipg/inode_size/inode_table 读对。
`timescale 1ns/1ps

module tb_ext4_scan;
    parameter NB=16, DATAW=32, NBEAT=1024, BLKSZ=4096;

    localparam INODES_PER_GRP=64;
    localparam BLOCKS_PER_GRP=128;
    localparam INODE_SIZE=256;
    localparam INODE_TABLE=4;
    localparam NWORDS=64*1024;              // 64 块 * 1024 字

    // 阶段2: 根 inode(2) 期望值(inode 表块 = INODE_TABLE=4, word 起点 64)
    localparam ROOT_MODE   = 16'h41ED;      // 0x4000 目录位 + 权限
    localparam ROOT_SIZE   = 32'h0000_0200; // 目录字节数
    localparam ROOT_EMAGIC = 16'hF30A;      // EXT4_EXT_MAGIC
    localparam ROOT_EENT   = 16'h0001;      // extent 条目数
    localparam ROOT_EBLK   = 32'h0000_0000; // 首 extent 逻辑块号
    localparam ROOT_ELEN   = 16'h0001;      // 首 extent 长度(块)
    localparam ROOT_ESTART = 32'h0000_0008; // 首 extent 物理起始块

    // 阶段3: 目录块(块8)首条目期望值
    localparam D_INO    = 32'h0000_000C;    // inode 号
    localparam D_FTYPE  = 8'h01;            // 常规文件
    localparam D_NAMELEN= 8'h03;            // "cat"
    localparam D_RECLEN = 16'd16;
    localparam D_NAME   = 24'h746163;       // 'c','a','t' (小端: 首字符在低8位)

    reg clk=0, rst_n=0, go=0;
    wire busy, done, err;
    wire [NB-1:0] blk_fd_blk;
    wire blk_fd_req;
    reg blk_fd_ready=0;
    reg blk_fd_dvalid=0;
    wire [DATAW-1:0] blk_fd_data;
    reg [NB-1:0] blk_fd_dblk=0;

    wire [31:0] bpg, ipg;
    wire [15:0] isz;
    wire [NB-1:0] itbl;
    wire [15:0] rm, re_mag, re_ent, re_len;
    wire [31:0] rs, re_blk, re_start;
    wire [31:0] d_ino;
    wire [7:0] d_ftype, d_namelen;
    wire [23:0] d_name;

    integer errc=0;

    // 合成镜像: 32 位字数组(索引 = 字)
    reg [31:0] img [0:NWORDS-1];

    reg [NB-1:0] serv_blk = 0;
    integer beat_cnt = 0;
    reg serving = 0;

    // ---- 数据服务: 由 serv_blk/beat_cnt 组合出当前字 ----
    // 字地址 = serv_blk*1024 + beat_cnt (用 assign 避开 always@(*) 数组读 bug)
    assign blk_fd_data = img[serv_blk*1024 + beat_cnt];

    always #5 clk=~clk;

    always @(posedge clk) begin
        if (!serving) begin
            if (blk_fd_req && blk_fd_ready) begin
                serv_blk <= blk_fd_blk;
                beat_cnt <= 0;
                serving  <= 1;
                blk_fd_dvalid <= 1;
                blk_fd_dblk <= blk_fd_blk;
            end
        end else begin
            blk_fd_dblk <= serv_blk;
            if (beat_cnt == NBEAT-1) begin
                serving  <= 0;
                blk_fd_dvalid <= 0;
            end else begin
                beat_cnt <= beat_cnt + 1;
            end
        end
    end

    ext4_scan_core #(.NB(NB), .DATAW(DATAW), .NBEAT(NBEAT)) u (
        .clk(clk), .rst_n(rst_n), .go(go),
        .busy(busy), .done(done), .err(err),
        .blk_fd_req(blk_fd_req), .blk_fd_blk(blk_fd_blk),
        .blk_fd_ready(blk_fd_ready),
        .blk_fd_dvalid(blk_fd_dvalid), .blk_fd_data(blk_fd_data),
        .blk_fd_dblk(blk_fd_dblk),
        .blocks_per_grp_o(bpg), .inodes_per_grp_o(ipg),
        .inode_size_o(isz), .inode_table_blk_o(itbl),
        .root_mode_o(rm), .root_size_lo_o(rs),
        .root_ee_magic_o(re_mag), .root_ee_entries_o(re_ent),
        .root_ee_block_o(re_blk), .root_ee_len_o(re_len), .root_ee_start_o(re_start),
        .d_ino_o(d_ino), .d_ftype_o(d_ftype), .d_namelen_o(d_namelen), .d_name_o(d_name)
    );

    integer i;
    reg [15:0] widx;
    initial begin
        for (i=0;i<NWORDS;i=i+1) img[i]=0;

        // 写操作用 initial 在 initial 块内做(读才受限)
        // superblock @块0+1024 字节 => 字索引 1024/4=256
        //   bpg@0x28 => 字 256+0x0A=266
        widx=266;
        img[widx] = BLOCKS_PER_GRP;
        widx=267;
        img[widx] = INODES_PER_GRP;
        widx=278;
        img[widx] = INODE_SIZE;    // inode_size@0x58 -> word 278, 取低16位
        widx=270;
        img[widx]=32'h0000EF53;    // magic 占位(非断言)
        // 组0 desc @块1+0x08 => 块1字索引 1024 + 2 = 1026
        widx=1024+2;
        img[widx] = INODE_TABLE;

        // 根 inode(2) @ inode 表块(块4) word 64
        widx=4*1024+64;
        img[widx] = ROOT_MODE;                 // i_mode (低16)
        widx=4*1024+65;
        img[widx] = ROOT_SIZE;                 // i_size 低32
        widx=4*1024+74;
        img[widx] = (ROOT_EENT<<16) | ROOT_EMAGIC;  // extent 头
        widx=4*1024+77;
        img[widx] = ROOT_EBLK;                 // ee_block
        widx=4*1024+78;
        img[widx] = ROOT_ELEN;                 // ee_len (低16)
        widx=4*1024+79;
        img[widx] = ROOT_ESTART;               // ee_start

        // 目录块(块8)首条目: word1 = {ftype,name_len,rec_len}
        widx=8*1024+0;
        img[widx] = D_INO;
        widx=8*1024+1;
        img[widx] = (D_FTYPE<<24) | (D_NAMELEN<<16) | D_RECLEN;
        widx=8*1024+2;
        img[widx] = D_NAME;                    // name 首3字符(小端)

        #30 rst_n=1; #10;
        blk_fd_ready=1;
        go=1; #10; go=0;

        wait(done);
        #10;
        $display("bpg=%0d ipg=%0d isz=%0d itbl=%0h", bpg, ipg, isz, itbl);
        if (bpg!==BLOCKS_PER_GRP) begin
            $display("FAIL bpg: got %0d want %0d", bpg, BLOCKS_PER_GRP); errc=errc+1;
        end else $display("PASS bpg=%0d", bpg);
        if (ipg!==INODES_PER_GRP) begin
            $display("FAIL ipg"); errc=errc+1;
        end else $display("PASS ipg=%0d", ipg);
        if (isz!==INODE_SIZE) begin
            $display("FAIL isz"); errc=errc+1;
        end else $display("PASS isz=%0d", isz);
        if (itbl!==INODE_TABLE) begin
            $display("FAIL itbl: got %0h want %0h", itbl, INODE_TABLE); errc=errc+1;
        end else $display("PASS itbl=%0d", itbl);

        // ---- 阶段2: 根 inode(2) ----
        if (rm!==ROOT_MODE) begin
            $display("FAIL root_mode: got %0h want %0h", rm, ROOT_MODE); errc=errc+1;
        end else $display("PASS root_mode=%0h", rm);
        if (rs!==ROOT_SIZE) begin
            $display("FAIL root_size: got %0h want %0h", rs, ROOT_SIZE); errc=errc+1;
        end else $display("PASS root_size=%0d", rs);
        if (re_mag!==ROOT_EMAGIC) begin
            $display("FAIL ee_magic: got %0h want %0h", re_mag, ROOT_EMAGIC); errc=errc+1;
        end else $display("PASS ee_magic=%0h", re_mag);
        if (re_ent!==ROOT_EENT) begin
            $display("FAIL ee_entries: got %0d want %0d", re_ent, ROOT_EENT); errc=errc+1;
        end else $display("PASS ee_entries=%0d", re_ent);
        if (re_blk!==ROOT_EBLK) begin
            $display("FAIL ee_block: got %0h want %0h", re_blk, ROOT_EBLK); errc=errc+1;
        end else $display("PASS ee_block=%0d", re_blk);
        if (re_len!==ROOT_ELEN) begin
            $display("FAIL ee_len: got %0d want %0d", re_len, ROOT_ELEN); errc=errc+1;
        end else $display("PASS ee_len=%0d", re_len);
        if (re_start!==ROOT_ESTART) begin
            $display("FAIL ee_start: got %0h want %0h", re_start, ROOT_ESTART); errc=errc+1;
        end else $display("PASS ee_start=%0d", re_start);

        // ---- 阶段3: 目录块首条目 ----
        if (d_ino!==D_INO) begin
            $display("FAIL d_ino: got %0h want %0h", d_ino, D_INO); errc=errc+1;
        end else $display("PASS d_ino=%0d", d_ino);
        if (d_ftype!==D_FTYPE) begin
            $display("FAIL d_ftype: got %0h want %0h", d_ftype, D_FTYPE); errc=errc+1;
        end else $display("PASS d_ftype=%0h", d_ftype);
        if (d_namelen!==D_NAMELEN) begin
            $display("FAIL d_namelen: got %0d want %0d", d_namelen, D_NAMELEN); errc=errc+1;
        end else $display("PASS d_namelen=%0d", d_namelen);
        if (d_name!==D_NAME) begin
            $display("FAIL d_name: got %0h want %0h", d_name, D_NAME); errc=errc+1;
        end else $display("PASS d_name=%0h", d_name);

        #20;
        if (errc==0) $display("PASS: ext4_scan 阶段3 目录块首条目(ino/ftype/name_len/name) 全过");
        else         $display("FAIL: err=%0d", errc);
        $finish;
    end

endmodule