// ============================================================================
// tb_cache_lba.v — cache_lba_top 端到端: 自动扫描→转录→管线查询→绝对 LBA
//
// 验证点:
//   V0 reset 后自动扫描(复用阶段15 合成镜像: 多层目录/跨块/索引递归→RAM 表)
//   V1 scan_done + lba_ready 拉高(转录 FILE_INO=14 两叶 estart=300/310 → file2lba)
//   V2 管线路径锁定, 字流 st_a 通过, 伴随 wt_lba:
//        ino14 叶0(逻辑块0,len1,estart300) + 叶1(逻辑块1-2,len2,estart310)
//        tag=0 → part_base+300 ; tag=1 → part_base+310 ; tag=2 → part_base+311
//
// 镜像与块源桩完全复用 tb_ext4_scan(已验证)。
// ============================================================================

`timescale 1ns/1ps

module tb_cache_lba;
    parameter NB=16, DATAW=32, NBEAT=1024, BLKSZ=4096;
    parameter DW=32, CW=32;
    parameter EXPERT_SLOTS=8;
    parameter FILES=8, ENTRYS=8;
    parameter TABN=8, MAXENT=4, MAXDEPTH=4, NDEP=4;

    localparam INODES_PER_GRP=16;
    localparam BLOCKS_PER_GRP=128;
    localparam INODE_SIZE=256;
    localparam INODE_TABLE=4;
    localparam INODE_TABLE_G1=6;
    localparam NWORDS=64*1024;

    localparam ROOT_MODE   = 16'h41ED;
    localparam ROOT_SIZE   = 32'h0000_0200;
    localparam ROOT_EMAGIC = 16'hF30A;
    localparam ROOT_EENT   = 16'h0001;
    localparam ROOT_EBLK   = 32'h0000_0000;
    localparam ROOT_ELEN   = 16'h0001;
    localparam ROOT_ESTART = 32'h0000_0008;

    localparam D0_INO=32'h0000000C, D0_FTYPE=8'h01, D0_NLEN=8'h03, D0_NAME=24'h746163;
    localparam D1_INO=32'h0000000D, D1_FTYPE=8'h01, D1_NLEN=8'h03, D1_NAME=24'h676F64;
    localparam D2_INO=32'h0000000E, D2_FTYPE=8'h01, D2_NLEN=8'h03, D2_NAME=24'h676970;
    localparam D3_INO=32'h00000014, D3_FTYPE=8'h02, D3_NLEN=8'h03, D3_NAME=24'h737362;
    localparam D_RECLEN = 16'd16;

    localparam F_MODE   = 16'h81A4;
    localparam F_SIZE   = 32'h0000_0800;
    localparam F_EBLK   = 32'h0000_0000;
    localparam F_ELEN   = 16'd2;
    localparam F_ESTART = 32'h0000_0020;

    localparam E7_INO13   = 32'd13;
    localparam E7_EST13   = 32'h0000_0030;
    localparam E7_ELEN13  = 16'd1;
    localparam INO13_WORD = 768;
    localparam E7_INO14   = 32'd14;

    localparam G14_EBLK   = 32'h0000_0000;
    localparam G14_ELKN   = 16'd1;
    localparam G14_ESTRT  = 32'h0000_012C;
    localparam G14_E0_EB  = 32'h0000_0000;
    localparam G14_E0_EL  = 16'd1;
    localparam G14_E0_ST  = 32'h0000_012C;
    localparam G14_E1_EB  = 32'h0000_0001;
    localparam G14_E1_EL  = 16'd2;
    localparam G14_E1_ST  = 32'h0000_0136;

    localparam S12_SIENT  = 16'd2;
    localparam S12_LEAF0  = 32'd42;
    localparam S12_LEAF1  = 32'd43;

    localparam SUBDIR_INO = 32'd20;
    localparam SUBDIR_BLK = 32'd45;
    localparam SUBDIR_WORD = 192;
    localparam S11_INO15 = 32'd17;
    localparam S11_EST15 = 32'h0000_00C8;
    localparam S11_EL15  = 16'd1;
    localparam S11_INO16 = 32'd18;
    localparam S11_EST16 = 32'h0000_00DC;
    localparam S11_EL16  = 16'd2;
    localparam S11_INO17_BLK = INODE_TABLE_G1;
    localparam S11_INO17_WORD = 0;
    localparam S11_INO18_WORD = 64;
    localparam S15_INO_SS  = 32'd21;
    localparam SUBDIR_BLK2 = 32'd46;
    localparam S15_INO19   = 32'd19;
    localparam S15_EST19   = 32'h0000_0190;

    reg clk=0, rst_n=0;
    reg serdes_aligned=0, pcie_link_up=0;
    reg rescan=0;

    // 块源桩(同 tb_ext4_scan)
    wire [NB-1:0] blk_fd_blk;
    wire blk_fd_req;
    reg blk_fd_ready=0;
    reg blk_fd_dvalid=0;
    wire [DATAW-1:0] blk_fd_data;
    reg [NB-1:0] blk_fd_dblk=0;
    reg [31:0] img [0:NWORDS-1];
    reg [NB-1:0] serv_blk=0;
    integer beat_cnt=0;
    reg serving=0;
    assign blk_fd_data = img[serv_blk*1024 + beat_cnt];

    // 管线字流(A) + 出口
    reg [DW-1:0] sa_dat=0; reg sa_v=0; wire sa_r;
    wire [DW-1:0] wt; wire wt_v; reg wt_r=1;
    wire [47:0] wt_lba; wire lba_fault;
    wire [CW-1:0] cb_dat; wire cb_v, cb_r;
    wire scan_busy, scan_done, lba_ready;
    integer err=0;

    always #5 clk=~clk;

    // 块源桩
    always @(posedge clk) begin
        if (!serving) begin
            if (blk_fd_req && blk_fd_ready) begin
                serv_blk <= blk_fd_blk; beat_cnt <= 0; serving <= 1;
                blk_fd_dvalid <= 1; blk_fd_dblk <= blk_fd_blk;
            end
        end else begin
            blk_fd_dblk <= serv_blk;
            if (beat_cnt==NBEAT-1) begin serving<=0; blk_fd_dvalid<=0; end
            else beat_cnt<=beat_cnt+1;
        end
    end

    cache_lba_top #(
        .NB(NB), .DW(DW), .CW(CW), .NBEAT(NBEAT),
        .TABN(TABN), .MAXENT(MAXENT), .MAXDEPTH(MAXDEPTH), .NDEP(NDEP),
        .EXPERT_SLOTS(EXPERT_SLOTS), .FILES(FILES), .ENTRYS(ENTRYS)
    ) u (
        .clk(clk), .rst_n(rst_n),
        .blk_fd_blk(blk_fd_blk), .blk_fd_req(blk_fd_req), .blk_fd_ready(blk_fd_ready),
        .blk_fd_dvalid(blk_fd_dvalid), .blk_fd_data(blk_fd_data), .blk_fd_dblk(blk_fd_dblk),
        .part_base(48'h0010_0000_2334),
        .serdes_aligned(serdes_aligned), .pcie_link_up(pcie_link_up),
        .st_a_data(sa_dat), .st_a_valid(sa_v), .st_a_ready(sa_r),
        .st_b_data(32'd0), .st_b_valid(1'b0), .st_b_ready(),
        .wt_data(wt), .wt_valid(wt_v), .wt_ready(wt_r),
        .wt_lba(wt_lba), .lba_fault(lba_fault),
        .cmd_a_data(32'd0), .cmd_a_valid(1'b0), .cmd_a_ready(),
        .cmd_b_data(cb_dat), .cmd_b_valid(cb_v), .cmd_b_ready(cb_r),
        .rescan(rescan),
        .scan_busy(scan_busy), .scan_done(scan_done), .lba_ready(lba_ready)
    );

    task send_a(input [DW-1:0] d);
        integer ack; begin
            ack=0; @(posedge clk); sa_dat<=d; sa_v<=1;
            while(!ack) begin @(posedge clk); if(sa_r) ack=1; end
            sa_v<=0; sa_dat<=0;
        end
    endtask

    reg [47:0] g_lba; reg g_fault;
    always @(posedge clk) if (wt_v && wt_r) begin
        g_lba = wt_lba; g_fault = lba_fault;
    end

    // ---- 镜像构建(同 tb_ext4_scan) ----
    integer i;
    reg [15:0] widx;
    initial begin
        for (i=0;i<NWORDS;i=i+1) img[i]=0;

        widx=266; img[widx]=BLOCKS_PER_GRP;
        widx=267; img[widx]=INODES_PER_GRP;
        widx=278; img[widx]=INODE_SIZE;
        widx=270; img[widx]=32'h0000EF53;
        widx=1024+2; img[widx]=INODE_TABLE;
        widx=1024+16+2; img[widx]=INODE_TABLE_G1;

        widx=4*1024+64;  img[widx]=ROOT_MODE;
        widx=4*1024+65;  img[widx]=ROOT_SIZE;
        widx=4*1024+74;  img[widx]=(ROOT_EENT<<16)|ROOT_EMAGIC;
        widx=4*1024+77;  img[widx]=ROOT_EBLK;
        widx=4*1024+78;  img[widx]=ROOT_ELEN;
        widx=4*1024+79;  img[widx]=ROOT_ESTART;

        // 目录块(块8)
        widx=8*1024+0; img[widx]=D0_INO;
        widx=8*1024+1; img[widx]=(D0_FTYPE<<24)|(D0_NLEN<<16)|D_RECLEN;
        widx=8*1024+2; img[widx]=D0_NAME;
        widx=8*1024+4; img[widx]=D1_INO;
        widx=8*1024+5; img[widx]=(D1_FTYPE<<24)|(D1_NLEN<<16)|D_RECLEN;
        widx=8*1024+6; img[widx]=D1_NAME;
        widx=8*1024+8; img[widx]=D2_INO;
        widx=8*1024+9; img[widx]=(D2_FTYPE<<24)|(D2_NLEN<<16)|D_RECLEN;
        widx=8*1024+10; img[widx]=D2_NAME;
        widx=8*1024+12; img[widx]=D3_INO;
        widx=8*1024+13; img[widx]=(D3_FTYPE<<24)|(D3_NLEN<<16)|D_RECLEN;
        widx=8*1024+14; img[widx]=D3_NAME;
        widx=8*1024+16; img[widx]=0;

        // ino20 子目录 inode @ 组1 表(块6) word192 — 数据块45
        widx=INODE_TABLE_G1*1024+192; img[widx]=16'h41ED;
        widx=INODE_TABLE_G1*1024+202; img[widx]=(32'h0001<<16)|32'hF30A;
        widx=INODE_TABLE_G1*1024+203; img[widx]=0;
        widx=INODE_TABLE_G1*1024+205; img[widx]=0;
        widx=INODE_TABLE_G1*1024+206; img[widx]=16'd1;
        widx=INODE_TABLE_G1*1024+207; img[widx]=SUBDIR_BLK;
        // 子目录数据块(块45)
        widx=45*1024+0; img[widx]=S11_INO15;
        widx=45*1024+1; img[widx]=(32'h01<<24)|(32'h05<<16)|D_RECLEN;
        widx=45*1024+2; img[widx]=24'h6D6F75;
        widx=45*1024+4; img[widx]=S11_INO16;
        widx=45*1024+5; img[widx]=(32'h01<<24)|(32'h03<<16)|D_RECLEN;
        widx=45*1024+6; img[widx]=24'h79656B;
        widx=45*1024+8; img[widx]=S15_INO_SS;
        widx=45*1024+9; img[widx]=(32'h02<<24)|(32'h05<<16)|D_RECLEN;
        widx=45*1024+10; img[widx]=24'h627573;
        widx=45*1024+12; img[widx]=0;
        // 阶段15: 子目录 sub2(ino21) 数据块=46
        widx=46*1024+0; img[widx]=S15_INO19;
        widx=46*1024+1; img[widx]=(32'h01<<24)|(32'h04<<16)|D_RECLEN;
        widx=46*1024+2; img[widx]=24'h6669;
        widx=46*1024+4; img[widx]=0;
        // ino21 @ 组1 表块6 word256
        widx=INODE_TABLE_G1*1024+256; img[widx]=16'h41ED;
        widx=INODE_TABLE_G1*1024+266; img[widx]=(32'h0001<<16)|32'hF30A;
        widx=INODE_TABLE_G1*1024+267; img[widx]=0;
        widx=INODE_TABLE_G1*1024+269; img[widx]=0;
        widx=INODE_TABLE_G1*1024+270; img[widx]=16'd1;
        widx=INODE_TABLE_G1*1024+271; img[widx]=SUBDIR_BLK2;
        // ino19 @ 组1 表块6 word128
        widx=INODE_TABLE_G1*1024+128; img[widx]=16'h81A4;
        widx=INODE_TABLE_G1*1024+138; img[widx]=(32'h0001<<16)|32'hF30A;
        widx=INODE_TABLE_G1*1024+139; img[widx]=0;
        widx=INODE_TABLE_G1*1024+141; img[widx]=0;
        widx=INODE_TABLE_G1*1024+142; img[widx]=16'd1;
        widx=INODE_TABLE_G1*1024+143; img[widx]=S15_EST19;
        // ino17 @ 块5 word0, ino18 @ 块5 word64
        widx=S11_INO17_BLK*1024+0;    img[widx]=16'h81A4;
        widx=S11_INO17_BLK*1024+10;    img[widx]=(32'h0001<<16)|32'hF30A;
        widx=S11_INO17_BLK*1024+11;    img[widx]=0;
        widx=S11_INO17_BLK*1024+13;    img[widx]=0;
        widx=S11_INO17_BLK*1024+14;    img[widx]=S11_EL15;
        widx=S11_INO17_BLK*1024+15;    img[widx]=S11_EST15;
        widx=S11_INO17_BLK*1024+64;    img[widx]=16'h81A4;
        widx=S11_INO17_BLK*1024+74;    img[widx]=(32'h0001<<16)|32'hF30A;
        widx=S11_INO17_BLK*1024+75;    img[widx]=0;
        widx=S11_INO17_BLK*1024+77;    img[widx]=0;
        widx=S11_INO17_BLK*1024+78;    img[widx]=S11_EL16;
        widx=S11_INO17_BLK*1024+79;    img[widx]=S11_EST16;
        // ino12 @ word704
        widx=4*1024+704; img[widx]=F_MODE;
        widx=4*1024+705; img[widx]=F_SIZE;
        widx=4*1024+714; img[widx]=(32'h0001<<16)|32'hF30A;
        widx=4*1024+715; img[widx]=0;
        widx=4*1024+717; img[widx]=F_EBLK;
        widx=4*1024+718; img[widx]=F_ELEN;
        widx=4*1024+719; img[widx]=F_ESTART;
        // ino13 @ word768
        widx=4*1024+768; img[widx]=16'h81A4;
        widx=4*1024+769; img[widx]=32'h0000_0400;
        widx=4*1024+778; img[widx]=(32'h0001<<16)|32'hF30A;
        widx=4*1024+779; img[widx]=0;
        widx=4*1024+781; img[widx]=0;
        widx=4*1024+782; img[widx]=E7_ELEN13;
        widx=4*1024+783; img[widx]=E7_EST13;
        // ino14 @ word832 — extent 根=索引(depth=1) → 索引块41
        widx=4*1024+832; img[widx]=16'h81A4;
        widx=4*1024+842; img[widx]=(32'h0001<<16)|32'hF30A;
        widx=4*1024+843; img[widx]=(32'h0001<<16);
        widx=4*1024+845; img[widx]=0;
        widx=4*1024+846; img[widx]=32'd41;
        // 索引块41 — entries=2 → 叶块42/43
        widx=41*1024+0; img[widx]=(S12_SIENT<<16)|32'hF30A;
        widx=41*1024+1; img[widx]=(32'h0001<<16);
        widx=41*1024+3; img[widx]=0;
        widx=41*1024+4; img[widx]=S12_LEAF0;
        widx=41*1024+6; img[widx]=1;
        widx=41*1024+7; img[widx]=S12_LEAF1;
        // 叶块42 — 叶0 → estart300
        widx=42*1024+0; img[widx]=(32'h0001<<16)|32'hF30A;
        widx=42*1024+1; img[widx]=0;
        widx=42*1024+3; img[widx]=G14_E0_EB;
        widx=42*1024+4; img[widx]=G14_E0_EL;
        widx=42*1024+5; img[widx]=G14_E0_ST;
        // 叶块43 — 叶0 → estart310
        widx=43*1024+0; img[widx]=(32'h0001<<16)|32'hF30A;
        widx=43*1024+1; img[widx]=0;
        widx=43*1024+3; img[widx]=G14_E1_EB;
        widx=43*1024+4; img[widx]=G14_E1_EL;
        widx=43*1024+5; img[widx]=G14_E1_ST;

        blk_fd_ready=1;
    end

    // ---- 主测试(件1: 多文件全目录转录) ----
    // RAM 顺序: ino12, ino13, ino14(×2), ino17, ino18, ino19
    // 期望 file2lba 目录:
    //   F[0] ino12: base=0,  size=2 (estart=32,elen=2)
    //   F[1] ino13: base=2,  size=1 (estart=48,elen=1)
    //   F[2] ino14: base=3,  size=3 (estart=300/1 + 310/2)
    //   F[3] ino17: base=6,  size=1 (estart=200,elen=1)
    //   F[4] ino18: base=7,  size=2 (estart=220,elen=2)
    //   F[5] ino19: base=9,  size=1 (estart=400,elen=1)
    //   共 6 文件, 7 段, 10 块
    initial begin
        #30 rst_n=1; #10;
        $display("t=%0t [cache_lba] 等待自动扫描+多文件转录...", $time);

        wait(lba_ready);
        #10;
        $display("t=%0t [cache_lba] lba_ready=1 扫描+多文件转录完成", $time);

        // --- V1: file2lba 目录寄存器校验 ---
        // nfiles
        if (u.u_pipe.u_f2l.file_size[0] !== 16'd2) begin
            $display("FAIL F[0] size: got=%0d want=2", u.u_pipe.u_f2l.file_size[0]); err=err+1;
        end else $display("PASS F[0](ino12) size=2");
        if (u.u_pipe.u_f2l.file_base_lo[0] !== 32'd0) begin
            $display("FAIL F[0] base: got=%0d want=0", u.u_pipe.u_f2l.file_base_lo[0]); err=err+1;
        end else $display("PASS F[0](ino12) base=0");

        if (u.u_pipe.u_f2l.file_size[1] !== 16'd1) begin
            $display("FAIL F[1] size: got=%0d want=1", u.u_pipe.u_f2l.file_size[1]); err=err+1;
        end else $display("PASS F[1](ino13) size=1");
        if (u.u_pipe.u_f2l.file_base_lo[1] !== 32'd2) begin
            $display("FAIL F[1] base: got=%0d want=2", u.u_pipe.u_f2l.file_base_lo[1]); err=err+1;
        end else $display("PASS F[1](ino13) base=2");

        if (u.u_pipe.u_f2l.file_size[2] !== 16'd3) begin
            $display("FAIL F[2] size: got=%0d want=3", u.u_pipe.u_f2l.file_size[2]); err=err+1;
        end else $display("PASS F[2](ino14) size=3");
        if (u.u_pipe.u_f2l.file_base_lo[2] !== 32'd3) begin
            $display("FAIL F[2] base: got=%0d want=3", u.u_pipe.u_f2l.file_base_lo[2]); err=err+1;
        end else $display("PASS F[2](ino14) base=3");

        if (u.u_pipe.u_f2l.file_size[3] !== 16'd1) begin
            $display("FAIL F[3] size: got=%0d want=1", u.u_pipe.u_f2l.file_size[3]); err=err+1;
        end else $display("PASS F[3](ino17) size=1");
        if (u.u_pipe.u_f2l.file_size[4] !== 16'd2) begin
            $display("FAIL F[4] size: got=%0d want=2", u.u_pipe.u_f2l.file_size[4]); err=err+1;
        end else $display("PASS F[4](ino18) size=2");
        if (u.u_pipe.u_f2l.file_size[5] !== 16'd1) begin
            $display("FAIL F[5] size: got=%0d want=1", u.u_pipe.u_f2l.file_size[5]); err=err+1;
        end else $display("PASS F[5](ino19) size=1");

        // EXT 段校验(关键几项)
        if (u.u_pipe.u_f2l.ext_base_lo[0] !== 32'd32 || u.u_pipe.u_f2l.ext_cnt[0] !== 16'd2) begin
            $display("FAIL EXT[0]: base=%0d cnt=%0d", u.u_pipe.u_f2l.ext_base_lo[0], u.u_pipe.u_f2l.ext_cnt[0]); err=err+1;
        end else $display("PASS EXT[0](ino12) base=32 cnt=2");
        if (u.u_pipe.u_f2l.ext_base_lo[2] !== 32'd300 || u.u_pipe.u_f2l.ext_cnt[2] !== 16'd1) begin
            $display("FAIL EXT[2]: base=%0d cnt=%0d", u.u_pipe.u_f2l.ext_base_lo[2], u.u_pipe.u_f2l.ext_cnt[2]); err=err+1;
        end else $display("PASS EXT[2](ino14叶0) base=300 cnt=1");
        if (u.u_pipe.u_f2l.ext_base_lo[3] !== 32'd310 || u.u_pipe.u_f2l.ext_cnt[3] !== 16'd2) begin
            $display("FAIL EXT[3]: base=%0d cnt=%0d", u.u_pipe.u_f2l.ext_base_lo[3], u.u_pipe.u_f2l.ext_cnt[3]); err=err+1;
        end else $display("PASS EXT[3](ino14叶1) base=310 cnt=2");
        if (u.u_pipe.u_f2l.ext_base_lo[6] !== 32'd400 || u.u_pipe.u_f2l.ext_cnt[6] !== 16'd1) begin
            $display("FAIL EXT[6]: base=%0d cnt=%0d", u.u_pipe.u_f2l.ext_base_lo[6], u.u_pipe.u_f2l.ext_cnt[6]); err=err+1;
        end else $display("PASS EXT[6](ino19) base=400 cnt=1");

        // --- V2: 管线路径锁定 ---
        serdes_aligned=1; #30;
        if (!u.p_locked || u.p_sel!==0) begin
            $display("FAIL 锁本地: pl=%b ps=%b", u.p_locked, u.p_sel); err=err+1;
        end else $display("PASS 锁本地");

        // trunk 恒命中(启动目录)
        send_a({24'hAB, 8'd0}); #10;

        // --- V3: 管线 LBA 查询(file 0 = ino12) ---
        // tag=0 → gblk=F[0].base+0=0 → EXT[0](estart=32,cnt=2) → part+32
        send_a({24'hFF, 8'd0}); #10;
        if (g_fault || g_lba !== (48'h0010_0000_2334 + 32)) begin
            $display("FAIL tag=0: lba=%h fault=%b want=%h", g_lba, g_fault, 48'h0010_0000_2334+32);
            err=err+1;
        end else $display("PASS tag=0 → LBA=%h (ino12 叶0)", g_lba);

        // tag=1 → gblk=1 → EXT[0] → part+33
        send_a({24'hFF, 8'd1}); #10;
        if (g_fault || g_lba !== (48'h0010_0000_2334 + 33)) begin
            $display("FAIL tag=1: lba=%h fault=%b want=%h", g_lba, g_fault, 48'h0010_0000_2334+33);
            err=err+1;
        end else $display("PASS tag=1 → LBA=%h (ino12 叶1)", g_lba);

        // tag=2 → gblk=2 ≥ F[0].size=2 → fault
        send_a({24'hFF, 8'd2}); #10;
        if (!g_fault) begin
            $display("FAIL tag=2 应 fault: lba=%h", g_lba); err=err+1;
        end else $display("PASS tag=2 → fault(ino12 越界)");

        // --- V4: 件4 重扫测试(rescan) ---
        $display("t=%0t [cache_lba] 测试 rescan...", $time);
        @(posedge clk); rescan<=1; @(posedge clk); rescan<=0;
        // 等 lba_ready 拉低(TI)
        repeat(5) @(posedge clk);
        if (lba_ready !== 1'b0)
            $display("INFO: lba_ready=%b (rescan 后预期0)", lba_ready);
        // 等重扫完成
        wait(lba_ready);
        #10;
        $display("t=%0t [cache_lba] rescan 完成, lba_ready=1", $time);
        // 重扫后 F[0] 不变
        if (u.u_pipe.u_f2l.file_size[0] !== 16'd2 || u.u_pipe.u_f2l.file_base_lo[0] !== 32'd0) begin
            $display("FAIL rescan F[0]: base=%0d size=%0d", u.u_pipe.u_f2l.file_base_lo[0], u.u_pipe.u_f2l.file_size[0]);
            err=err+1;
        end else $display("PASS rescan → F[0] 不变(base=0,size=2)");
        // 重扫后管线查询仍正确
        send_a({24'hFF, 8'd0}); #10;
        if (g_fault || g_lba !== (48'h0010_0000_2334 + 32)) begin
            $display("FAIL rescan tag=0: lba=%h", g_lba); err=err+1;
        end else $display("PASS rescan tag=0 → LBA=%h (仍正确)", g_lba);

        #20;
        if (err==0) $display("PASS: cache_lba_top 件1多文件转录+件4重扫+管线查询 全过");
        else         $display("FAIL: err=%0d", err);
        $finish;
    end

endmodule
