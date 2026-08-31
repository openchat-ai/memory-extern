// ============================================================================
// tb_file2lba.v — 文件→LBA 映射接口验证(多文件句柄 + extent 全局拼接)
//
// 验证点:
//   F1 复位后未配置: 查询 -> fault
//   F2 命令帧配分区起始 + extent 表 + 文件0 目录(size)
//   F3 文件0 段内连续块 -> 正确物理 LBA(分区起始+段base+块内偏移)
//   F4 跨段跳转: 第二段起点映射到累计起点
//   F5 越界块号 -> fault=1(文件内 size 判界)
//   F6 动态重配表后查询仍正确
//   F7 多文件句柄: file0/file1 各占全局块空间一段, extent 全局拼接 -> 正确 LBA
// ============================================================================

`timescale 1ns/1ps

module tb_file2lba;
    parameter LBAW     = 48;
    parameter BLKW     = 16;
    parameter ENTRYS   = 8;
    parameter FILES    = 4;

    reg clk=0, rst_n=0;
    reg [31:0] cd=0; reg cv=0; wire cr;
    reg [1:0]  rf=0;
    reg [BLKW-1:0] rb=0;
    wire [LBAW-1:0] pl;
    wire lf;

    integer err=0;

    always #5 clk=~clk;

    file2lba #(.LBAW(LBAW), .BLKW(BLKW), .ENTRYS(ENTRYS), .FILES(FILES), .FILE_IDW(2)) u (
        .clk(clk), .rst_n(rst_n),
        .cmd_data(cd), .cmd_valid(cv), .cmd_ready(cr),
        .req_file(rf), .req_blk(rb),
        .phys_lba(pl), .lba_fault(lf)
    );

    // 两拍命令帧: (reg_addr, data)
    task cfg(input [7:0] rega, input [31:0] d); begin
        @(posedge clk); cd <= {24'b0, rega, 8'h50}; cv <= 1;
        @(posedge clk); cd <= d; cv <= 1;
        @(posedge clk); cv <= 0; cd <= 0;
    end endtask

    // 查询: (文件句柄, 文件内块号) 组合直出
    task qry(input [1:0] f, input [BLKW-1:0] b, output [LBAW-1:0] l, output fo); begin
        #1; rf = f; rb = b;
        #1;
        l = pl; fo = lf;
    end endtask

    reg [LBAW-1:0] got_l;
    reg            got_f;

    task chk(input [8*24:0] tag, input [LBAW-1:0] want, input wantf, input ok); begin
        if (ok) begin
            if (got_f !== wantf || (got_f==0 && got_l !== want)) begin
                $display("FAIL %s: got_l=%h got_f=%b want_l=%h want_f=%b", tag, got_l, got_f, want, wantf); err=err+1;
            end else
                $display("PASS %s: lba=%h fault=%b", tag, got_l, got_f);
        end
    end endtask

    initial begin
        #30 rst_n=1; #10;

        // ---- F1 复位后未配置: fault ----
        qry(0, 8'd0, got_l, got_f);
        chk("F1 复位未配置 fault", 48'h0, 1'b1, 1'b1);

        // ---- F2 配表: 分区 0x1000_0000; ext0 base=0x20 cnt=4; ext1 base=0x40 cnt=2;
        //     file0: base=0 size=6 (单文件语义) ----
        cfg(8'h00, 32'h1000_0000);          // part_lba_lo
        cfg(8'h01, 32'h0000_0000);          // part_lba_hi
        cfg(8'h10, 32'h0000_0020);          // ext0 base_lo
        cfg(8'h11, 32'h0000_0000);          // ext0 base_hi
        cfg(8'h20, 32'h0000_0004);          // ext0 cnt=4
        cfg(8'h12, 32'h0000_0040);          // ext1 base_lo
        cfg(8'h13, 32'h0000_0000);          // ext1 base_hi
        cfg(8'h21, 32'h0000_0002);          // ext1 cnt=2
        cfg(8'h30, 32'h0000_0000);          // file0 base_lo = 0
        cfg(8'h31, 32'h0000_0000);          // file0 base_hi = 0
        cfg(8'h40, 32'h0000_0006);          // file0 size = 6

        // ---- F3 段内连续块(文件0) ----
        qry(0, 0, got_l, got_f);
        chk("F3 块0->分区+段0", 48'h1000_0020, 1'b0, 1'b1);
        qry(0, 1, got_l, got_f);
        chk("F3 块1->+1",      48'h1000_0021, 1'b0, 1'b1);
        qry(0, 3, got_l, got_f);
        chk("F3 块3->段末",    48'h1000_0023, 1'b0, 1'b1);

        // ---- F4 跨段: 文件0 块4(第2段起点) -> 段1 base ----
        qry(0, 4, got_l, got_f);
        chk("F4 块4->段1起点", 48'h1000_0040, 1'b0, 1'b1);
        qry(0, 5, got_l, got_f);
        chk("F4 块5->段1末",   48'h1000_0041, 1'b0, 1'b1);

        // ---- F5 越界: 文件0 size=6 ----
        qry(0, 6, got_l, got_f);
        chk("F5 块6越界 fault", 48'h0, 1'b1, 1'b1);
        qry(0, 65535, got_l, got_f);
        chk("F5 块65535越界",   48'h0, 1'b1, 1'b1);

        // ---- F6 动态重配: 换分区/换段后查询 ----
        cfg(8'h00, 32'h2000_0000);          // 换分区
        cfg(8'h10, 32'h0000_0100);          // ext0 base 改 0x100, cnt=2
        cfg(8'h20, 32'h0000_0002);
        qry(0, 0, got_l, got_f);
        chk("F6 重配分区后块0", 48'h2000_0100, 1'b0, 1'b1);
        qry(0, 1, got_l, got_f);
        chk("F6 重配后块1",     48'h2000_0101, 1'b0, 1'b1);
        qry(0, 2, got_l, got_f);            // 落 ext1(未动): 0x2000_0040
        chk("F6 重配后块2->ext1", 48'h2000_0040, 1'b0, 1'b1);
        qry(0, 4, got_l, got_f);            // 重配后 total=4, 块4 超段表
        chk("F6 块4越界",       48'h0, 1'b1, 1'b1);

        // ---- F7 多文件: 分区 0x3000_0000; extent 全局拼接;
        //     file0 base=0 size=8 (全局0..7); file1 base=8 size=4 (全局8..11) ----
        cfg(8'h00, 32'h3000_0000);
        cfg(8'h10, 32'h0000_0020);  cfg(8'h20, 32'h0000_0006);  // ext0: 全局0..5 -> 0x20
        cfg(8'h12, 32'h0000_00A0);  cfg(8'h21, 32'h0000_0002);  // ext1: 全局6..7 -> 0xA0
        cfg(8'h14, 32'h0000_0400);  cfg(8'h22, 32'h0000_0004);  // ext2: 全局8..11 -> 0x400
        cfg(8'h30, 32'h0000_0000);  cfg(8'h40, 32'h0000_0008);  // file0: base=0 size=8
        cfg(8'h32, 32'h0000_0008);  cfg(8'h41, 32'h0000_0004);  // file1: base=8 size=4

        qry(0, 3, got_l, got_f);
        chk("F7 file0块3 -> 全局3", 48'h3000_0023, 1'b0, 1'b1);
        qry(0, 6, got_l, got_f);
        chk("F7 file0块6 -> 跨ext1", 48'h3000_00A0, 1'b0, 1'b1);
        qry(0, 7, got_l, got_f);
        chk("F7 file0块7 -> ext1末", 48'h3000_00A1, 1'b0, 1'b1);
        qry(1, 0, got_l, got_f);
        chk("F7 file1块0 -> 全局8",  48'h3000_0400, 1'b0, 1'b1);
        qry(1, 3, got_l, got_f);
        chk("F7 file1块3 -> 全局11", 48'h3000_0403, 1'b0, 1'b1);
        qry(0, 8, got_l, got_f);            // file0 size=8 -> 块8 越界
        chk("F7 file0块8 越界",      48'h0, 1'b1, 1'b1);
        qry(1, 4, got_l, got_f);            // file1 size=4 -> 块4 越界
        chk("F7 file1块4 越界",      48'h0, 1'b1, 1'b1);
        qry(3, 0, got_l, got_f);            // file3 未配(size=0) -> fault
        chk("F7 file3未配 越界",     48'h0, 1'b1, 1'b1);

        #20;
        if (err==0) $display("PASS: file2lba 文件->LBA 多文件映射 全过");
        else        $display("FAIL: file2lba err=%0d", err);
        $finish;
    end

endmodule