// ============================================================================
// tb_file2lba.v — 文件→LBA 映射接口验证
//
// 验证点:
//   F1 复位后未配置: 查询 -> fault
//   F2 命令帧配分区起始 + 两段 extent 表
//   F3 查询: 段内连续块 -> 正确物理 LBA(分区起始+段base+块内偏移)
//   F4 跨段跳转: 第二段起点映射到累计起点
//   F5 越界块号 -> fault=1
//   F6 重配分区/段后查询仍正确(动态更新表格)
// ============================================================================

`timescale 1ns/1ps

module tb_file2lba;
    parameter LBAW   = 48;
    parameter BLKW   = 16;
    parameter ENTRYS = 4;

    reg clk=0, rst_n=0;
    reg [31:0] cd=0; reg cv=0; wire cr;
    reg [BLKW-1:0] rb=0;
    wire [LBAW-1:0] pl;
    wire lf;

    integer err=0;

    always #5 clk=~clk;

    file2lba #(.LBAW(LBAW), .BLKW(BLKW), .ENTRYS(ENTRYS)) u (
        .clk(clk), .rst_n(rst_n),
        .cmd_data(cd), .cmd_valid(cv), .cmd_ready(cr),
        .req_blk(rb),
        .phys_lba(pl), .lba_fault(lf)
    );

    // 两拍命令帧: (reg_addr, data)
    task cfg(input [7:0] rega, input [31:0] d); begin
        @(posedge clk); cd <= {24'b0, rega, 8'h50}; cv <= 1;
        @(posedge clk); cd <= d; cv <= 1;
        @(posedge clk); cv <= 0; cd <= 0;
    end endtask

    // 查询: 阻塞改 req_blk, 稳定后读组合输出
    task qry(input [BLKW-1:0] b, output [LBAW-1:0] l, output f); begin
        #1; rb = b;
        #1;
        l = pl; f = lf;
    end endtask

    // 简单断言
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
        qry(8'd0, got_l, got_f);
        chk("F1 复位未配置 fault", 48'h0, 1'b1, 1'b1);

        // ---- F2 配表: 分区起始 0x1000_0000; ext0 base=0x20 cnt=4; ext1 base=0x40 cnt=2 ----
        cfg(8'h00, 32'h1000_0000);          // part_lba_lo
        cfg(8'h01, 32'h0000_0000);          // part_lba_hi
        cfg(8'h10, 32'h0000_0020);          // ext0 base_lo
        cfg(8'h11, 32'h0000_0000);          // ext0 base_hi
        cfg(8'h20, 32'h0000_0004);          // ext0 cnt=4
        cfg(8'h12, 32'h0000_0040);          // ext1 base_lo
        cfg(8'h13, 32'h0000_0000);          // ext1 base_hi
        cfg(8'h21, 32'h0000_0002);          // ext1 cnt=2

        // ---- F3 段内连续块 ----
        qry(0, got_l, got_f);
        chk("F3 块0->分区+段0", 48'h1000_0020, 1'b0, 1'b1);
        qry(1, got_l, got_f);
        chk("F3 块1->+1",      48'h1000_0021, 1'b0, 1'b1);
        qry(3, got_l, got_f);
        chk("F3 块3->段末",    48'h1000_0023, 1'b0, 1'b1);

        // ---- F4 跨段: 文件块4(第2段起点) -> 段1 base ----
        qry(4, got_l, got_f);
        chk("F4 块4->段1起点", 48'h1000_0040, 1'b0, 1'b1);
        qry(5, got_l, got_f);
        chk("F4 块5->段1末",   48'h1000_0041, 1'b0, 1'b1);

        // ---- F5 越界: 文件总块数=6 ----
        qry(6, got_l, got_f);
        chk("F5 块6越界 fault", 48'h0, 1'b1, 1'b1);
        qry(65535, got_l, got_f);
        chk("F5 块65535越界",   48'h0, 1'b1, 1'b1);

        // ---- F6 动态重配: 换分区/换段后查询 ----
        cfg(8'h00, 32'h2000_0000);          // 换分区
        cfg(8'h10, 32'h0000_0100);          // ext0 base 改 0x100, cnt=2
        cfg(8'h20, 32'h0000_0002);
        qry(0, got_l, got_f);
        chk("F6 重配分区后块0", 48'h2000_0100, 1'b0, 1'b1);
        qry(1, got_l, got_f);
        chk("F6 重配后块1",     48'h2000_0101, 1'b0, 1'b1);
        qry(2, got_l, got_f);               // 落 ext1(未动): 0x2000_0040
        chk("F6 重配后块2->ext1", 48'h2000_0040, 1'b0, 1'b1);
        qry(4, got_l, got_f);               // 重配后 total = 2+2 = 4
        chk("F6 块4越界",       48'h0, 1'b1, 1'b1);

        #20;
        if (err==0) $display("PASS: file2lba 文件->LBA 映射 全过");
        else        $display("FAIL: file2lba err=%0d", err);
        $finish;
    end

endmodule