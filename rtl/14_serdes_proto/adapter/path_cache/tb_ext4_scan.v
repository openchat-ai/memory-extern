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
        .inode_size_o(isz), .inode_table_blk_o(itbl)
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

        #20;
        if (errc==0) $display("PASS: ext4_scan 阶段1 superblock/组描述符 全过");
        else         $display("FAIL: err=%0d", errc);
        $finish;
    end

endmodule