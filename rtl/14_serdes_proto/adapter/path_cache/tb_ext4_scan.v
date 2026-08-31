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

    // 阶段4: 目录块逐条枚举(MAXENT=4)
    localparam D0_INO=32'h0000000C, D0_FTYPE=8'h01, D0_NLEN=8'h03, D0_NAME=24'h746163; // cat
    localparam D1_INO=32'h0000000D, D1_FTYPE=8'h01, D1_NLEN=8'h03, D1_NAME=24'h676F64; // dog
    localparam D2_INO=32'h0000000E, D2_FTYPE=8'h01, D2_NLEN=8'h03, D2_NAME=24'h676970; // pig
    localparam D_RECLEN = 16'd16;

    // 阶段5: 文件 inode(12) extent 期望值(@ inode 表块 word 704, depth=0 内联)
    localparam F_MODE   = 16'h81A4;      // 0x8000 常规文件
    localparam F_SIZE   = 32'h0000_0800; // 文件字节数
    localparam F_EBLK   = 32'h0000_0000; // 首 extent 逻辑块号
    localparam F_ELEN   = 16'd2;         // 首 extent 长度(块)
    localparam F_ESTART = 32'h0000_0020; // 首 extent 物理起始块(32)

    // 阶段7: 全文件收集 — ino13 depth0 内联(estart=48) / ino14 depth1 索引(跳过)
    localparam E7_INO13   = 32'd13;      // 第二个文件
    localparam E7_EST13   = 32'h0000_0030; // ino13 数据物理块 48
    localparam E7_ELEN13  = 16'd1;
    // ino13 @ word (13-1)%16*64 = 12*64 = 768
    localparam INO13_WORD = 768;
    localparam E7_INO14   = 32'd14;      // 第三个文件 = 索引

    // 阶段9: ino14 索引(depth=1) → 递归读子块41, 收集其全部叶(2 叶)
    localparam G14_EBLK   = 32'h0000_0000;
    localparam G14_ELKN   = 16'd1;
    localparam G14_ESTRT  = 32'h0000_0064; // 叶0 → 物理块 100
    localparam G14_E0_EB  = 32'h0000_0000; // 叶0: 逻辑块0
    localparam G14_E0_EL  = 16'd1;         //       长度1
    localparam G14_E0_ST  = 32'h0000_0064; //       物理块100
    localparam G14_E1_EB  = 32'h0000_0001; // 叶1: 逻辑块1
    localparam G14_E1_EL  = 16'd2;         //       长度2
    localparam G14_E1_ST  = 32'h0000_0078; //       物理块120

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
    wire [31:0] o_ino [0:3];
    wire [7:0] o_ftype [0:3], o_nlen [0:3];
    wire [23:0] o_name3 [0:3];
    wire [2:0] o_cnt;
    wire [31:0] f_ino, f_size, f_ebe, f_estart, s_ebe, s_estart;
    wire [15:0] f_mode, f_elen, s_elen;
    wire [31:0] x_ino [0:3], x_ebe [0:3], x_estart [0:3];
    wire [15:0] x_elen [0:3];
    wire [2:0] x_cnt;
    wire [31:0] r_ino [0:3], r_ebe [0:3], r_estart [0:3];
    wire [15:0] r_elen [0:3];
    reg qreq=0;
    reg [NB-1:0] qino=0;
    wire qbusy, qvalid, qdone;
    wire [31:0] qebe, qestart;
    wire [15:0] qelen;

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

    ext4_scan_core #(.NB(NB), .DATAW(DATAW), .NBEAT(NBEAT), .MAXENT(4)) u (
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
        .out_ino(o_ino), .out_ftype(o_ftype), .out_nlen(o_nlen),
        .out_name3(o_name3), .out_count(o_cnt),
        .f_ino_o(f_ino), .f_mode_o(f_mode), .f_size_lo_o(f_size),
        .f_ebe_o(f_ebe), .f_elen_o(f_elen), .f_estart_o(f_estart),
        .s_ebe_o(s_ebe), .s_elen_o(s_elen), .s_estart_o(s_estart),
        .ext_ino_o(x_ino), .ext_ebe_o(x_ebe), .ext_elen_o(x_elen),
        .ext_estart_o(x_estart), .ext_count_o(x_cnt),
        .ram_ino(r_ino), .ram_ebe(r_ebe), .ram_elen(r_elen),
        .ram_estart(r_estart),
        .qreq(qreq), .qino(qino),
        .qbusy(qbusy), .qvalid(qvalid), .qdone(qdone),
        .qebe(qebe), .qelen(qelen), .qestart(qestart)
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

        // 目录块(块8) 逐条: entry k @ 字 k*4, 每条 16B
        // entry0 = cat
        widx=8*1024+0;  img[widx] = D0_INO;
        widx=8*1024+1;  img[widx] = (D0_FTYPE<<24)|(D0_NLEN<<16)|D_RECLEN;
        widx=8*1024+2;  img[widx] = D0_NAME;
        // entry1 = dog
        widx=8*1024+4;  img[widx] = D1_INO;
        widx=8*1024+5;  img[widx] = (D1_FTYPE<<24)|(D1_NLEN<<16)|D_RECLEN;
        widx=8*1024+6;  img[widx] = D1_NAME;
        // entry2 = pig
        widx=8*1024+8;  img[widx] = D2_INO;
        widx=8*1024+9;  img[widx] = (D2_FTYPE<<24)|(D2_NLEN<<16)|D_RECLEN;
        widx=8*1024+10; img[widx] = D2_NAME;
        // entry3 = 块尾(ino=0)

        // ino12 @ word 704 — depth=0 内联叶 (阶段5: f_*)
        widx=4*1024+704;  img[widx] = F_MODE;
        widx=4*1024+705;  img[widx] = F_SIZE;
        widx=4*1024+714;  img[widx] = (32'h0001<<16)|32'hF30A; // entries=1 magic
        widx=4*1024+715;  img[widx] = 0;                        // depth=0
        widx=4*1024+717;  img[widx] = F_EBLK;                   // ee_block
        widx=4*1024+718;  img[widx] = F_ELEN;                   // ee_len
        widx=4*1024+719;  img[widx] = F_ESTART;                 // ee_start=32

        // ino13 @ word 768 — depth=0 内联叶 (阶段7 收集)
        widx=4*1024+768;  img[widx] = 16'h81A4;
        widx=4*1024+769;  img[widx] = 32'h0000_0400;            // size=1024
        widx=4*1024+778;  img[widx] = (32'h0001<<16)|32'hF30A;  // extent 头
        widx=4*1024+779;  img[widx] = 0;                        // depth=0
        widx=4*1024+781;  img[widx] = 0;                        // ee_block
        widx=4*1024+782;  img[widx] = E7_ELEN13;                // ee_len
        widx=4*1024+783;  img[widx] = E7_EST13;                 // ee_start=48

        // ino14 @ word 832 — depth=1 索引 (阶段10: 递归2层 → 块41索引 → 块42叶)
        widx=4*1024+832;  img[widx] = 16'h81A4;
        widx=4*1024+842;  img[widx] = (32'h0001<<16)|32'hF30A;  // extent 头
        widx=4*1024+843;  img[widx] = (32'h0001<<16);           // depth=1 (索引)
        widx=4*1024+845;  img[widx] = 0;                        // ei_block
        widx=4*1024+846;  img[widx] = 32'd41;                   // ei_leaf=41(索引块)

        // 块41 — 索引块(depth=1), 第一索引项 ei_leaf=42
        widx=41*1024+0;   img[widx] = (32'h0001<<16)|32'hF30A;  // entries=1 magic
        widx=41*1024+1;   img[widx] = (32'h0001<<16);           // depth=1 (索引)
        widx=41*1024+3;   img[widx] = 0;                        // ei_block=0
        widx=41*1024+4;   img[widx] = 32'd42;                   // ei_leaf=42(下层叶块)

        // 块42 — 叶块 depth=0, entries=2 叶 → 收集为 ino14×2 表项
        widx=42*1024+0;   img[widx] = (32'h0002<<16)|32'hF30A;  // entries=2 magic
        widx=42*1024+1;   img[widx] = 0;                        // depth=0
        widx=42*1024+3;   img[widx] = G14_E0_EB;                // 叶0 ee_block=0
        widx=42*1024+4;   img[widx] = G14_E0_EL;                // 叶0 ee_len=1
        widx=42*1024+5;   img[widx] = G14_E0_ST;                // 叶0 ee_start=100
        widx=42*1024+6;   img[widx] = G14_E1_EB;                // 叶1 ee_block=1
        widx=42*1024+7;   img[widx] = G14_E1_EL;                // 叶1 ee_len=2
        widx=42*1024+8;   img[widx] = G14_E1_ST;                // 叶1 ee_start=120

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

        // ---- 阶段4: 目录块逐条枚举 ----
        if (o_cnt!==3) begin
            $display("FAIL out_count: got %0d want %0d", o_cnt, 3); errc=errc+1;
        end else $display("PASS out_count=%0d", o_cnt);
        if (o_ino[0]!==D0_INO) begin
            $display("FAIL e0 ino: %0h want %0h", o_ino[0], D0_INO); errc=errc+1;
        end else $display("PASS e0 ino=%0d", o_ino[0]);
        if (o_name3[0]!==D0_NAME) begin
            $display("FAIL e0 name"); errc=errc+1;
        end else $display("PASS e0 name=%0h", o_name3[0]);
        if (o_ftype[0]!==D0_FTYPE) begin
            $display("FAIL e0 ftype"); errc=errc+1;
        end else $display("PASS e0 ftype=%0h", o_ftype[0]);
        if (o_ino[1]!==D1_INO) begin
            $display("FAIL e1 ino"); errc=errc+1;
        end else $display("PASS e1 ino=%0d", o_ino[1]);
        if (o_name3[1]!==D1_NAME) begin
            $display("FAIL e1 name"); errc=errc+1;
        end else $display("PASS e1 name=%0h", o_name3[1]);
        if (o_ino[2]!==D2_INO) begin
            $display("FAIL e2 ino"); errc=errc+1;
        end else $display("PASS e2 ino=%0d", o_ino[2]);
        if (o_name3[2]!==D2_NAME) begin
            $display("FAIL e2 name"); errc=errc+1;
        end else $display("PASS e2 name=%0h", o_name3[2]);

        // ---- 阶段7/9: 全文件收集 → "文件→物理块"映射表 ----
        // (阶段5 的单文件 ino12 映射已被全文件收集取代; 阶段9 对 ino14 索引递归2叶)
        if (x_cnt!==4) begin
            $display("FAIL ext_count: got %0d want 4 (ino14 索引递归成2叶)", x_cnt); errc=errc+1;
        end else $display("PASS ext_count=%0d (ino14 递归2叶)", x_cnt);
        if (x_ino[0]!==D0_INO) begin
            $display("FAIL ext[0] ino"); errc=errc+1;
        end else $display("PASS ext[0] ino=%0d", x_ino[0]);
        if (x_estart[0]!==F_ESTART) begin
            $display("FAIL ext[0] estart: got %0h want %0h", x_estart[0], F_ESTART); errc=errc+1;
        end else $display("PASS ext[0] estart=%0d", x_estart[0]);
        if (x_ino[1]!==E7_INO13) begin
            $display("FAIL ext[1] ino: got %0d want %0d", x_ino[1], E7_INO13); errc=errc+1;
        end else $display("PASS ext[1] ino=%0d", x_ino[1]);
        if (x_estart[1]!==E7_EST13) begin
            $display("FAIL ext[1] estart: got %0h want %0h", x_estart[1], E7_EST13); errc=errc+1;
        end else $display("PASS ext[1] estart=%0d", x_estart[1]);
        if (x_elen[1]!==E7_ELEN13) begin
            $display("FAIL ext[1] elen"); errc=errc+1;
        end else $display("PASS ext[1] elen=%0d", x_elen[1]);

        // ---- 阶段9: ino14 索引(depth=1)递归 → 收集子块41 全部叶(2 叶) ----
        if (x_ino[2]!==E7_INO14 || x_ebe[2]!==G14_E0_EB || x_estart[2]!==G14_E0_ST) begin
            $display("FAIL ext[2] ino14叶0: ino=%0d ebe=%0h est=%0h",
                     x_ino[2], x_ebe[2], x_estart[2]); errc=errc+1;
        end else $display("PASS ext[2] ino14叶0 → estart=%0d len=%0d", x_estart[2], x_elen[2]);
        if (x_ino[3]!==E7_INO14 || x_ebe[3]!==G14_E1_EB ||
            x_elen[3]!==G14_E1_EL || x_estart[3]!==G14_E1_ST) begin
            $display("FAIL ext[3] ino14叶1: ebe=%0h elen=%0d est=%0h",
                     x_ebe[3], x_elen[3], x_estart[3]); errc=errc+1;
        end else $display("PASS ext[3] ino14叶1 → estart=%0d len=%0d", x_estart[3], x_elen[3]);
        if (r_ino[0]!==D0_INO || r_estart[0]!==F_ESTART) begin
            $display("FAIL ram[0]: ino=%0d estart=%0h", r_ino[0], r_estart[0]); errc=errc+1;
        end else $display("PASS ram[0] ino=%0d estart=%0d", r_ino[0], r_estart[0]);
        if (r_ino[1]!==E7_INO13 || r_estart[1]!==E7_EST13) begin
            $display("FAIL ram[1]"); errc=errc+1;
        end else $display("PASS ram[1] ino=%0d estart=%0d", r_ino[1], r_estart[1]);
        if (r_ino[2]!==E7_INO14 || r_estart[2]!==G14_E0_ST ||
            r_ino[3]!==E7_INO14 || r_estart[3]!==G14_E1_ST) begin
            $display("FAIL ram[2/3] ino14 两叶"); errc=errc+1;
        end else $display("PASS ram[2/3] ino14 两叶(st=%0d,%0d)", r_estart[2], r_estart[3]);

        // 查询 ino=13(dog) → 应返回 estart=48
        qino=13; qreq=1;
        #20;
        qreq=0;
        wait(qdone); #10;
        if (qvalid!==1 || qestart!==E7_EST13 || qebe!==0 || qelen!==E7_ELEN13) begin
            $display("FAIL query ino13: valid=%0d estart=%0h ebe=%0h elen=%0d",
                     qvalid, qestart, qebe, qelen); errc=errc+1;
        end else $display("PASS query ino13 → estart=%0d ebe=%0d elen=%0d", qestart, qebe, qelen);

        // 查询不存在 ino=99 → 未找到
        qino=99; qreq=1;
        #20;
        qreq=0;
        wait(qdone); #10;
        if (qvalid!==0) begin
            $display("FAIL query ino99 应未找到, valid=%0d", qvalid); errc=errc+1;
        end else $display("PASS query ino99 未找到 (qvalid=0)");

        #20;
        if (errc==0) $display("PASS: ext4_scan 阶段10 多层(2层)索引递归 ino14→块41索引→块42叶(2叶) + 全表/RAM/查询 全过");
        else         $display("FAIL: err=%0d", errc);
        $finish;
    end

endmodule