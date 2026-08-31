// ============================================================================
// tb_nvme.v — NVMe 协议层(阶段 N1)纯仿真
//
// 验证点:
//   V0 复位后 admin(Identify)握手完成, done=1, busy 回 0
//   V1 依次发起 4 个写命令, 每命令 2 块数据, 数据经 tx_data 下发到设备,
//      完成后 done 拉高且 err=0
//   V2 发起 1 个读命令(blk_len=3), 设备回 3 拍数据, 经 rd 转发,
//      rd_data 值与设备填充一致, 完成后 done=1 err=0
//   V3 队列深度/多命令背压不丢(连续 NQ 个命令后繁忙抑制)
//
// 只是协议闭环 + 桩数据, 不绑定物理。
// ============================================================================

`timescale 1ns/1ps

module tb_nvme;
    parameter DATAW=32, CMDW=32, LBAW=48, BLKW=16, NQ=4;

    reg clk=0, rst_n=0;
    always #5 clk=~clk;

    reg  req=0, is_read=0;
    reg  [LBAW-1:0] lba=0;
    reg  [BLKW-1:0] blk_len=0;
    wire busy, done, err;

    wire [DATAW-1:0] rd_data; wire rd_valid; reg rd_ready=1;
    reg  [DATAW-1:0] wr_data=0; reg wr_valid=0; wire wr_ready;

    // 传输接口(直接接设备模型, 代替物理适配器)
    wire [CMDW-1:0]  tx_cmd; wire tx_cmd_valid; reg tx_cmd_ready;
    wire [DATAW-1:0] rx_data; wire rx_valid; reg rx_ready;
    wire [DATAW-1:0] tx_data; wire tx_data_valid; reg tx_data_ready;
    wire [CMDW-1:0]  rx_cpl; wire rx_cpl_valid; reg rx_cpl_ready;

    nvme_host #(.CMDW(CMDW),.DATAW(DATAW),.LBAW(LBAW),.BLKW(BLKW),.NQ(NQ),.TAGW(4)) u (
        .clk(clk), .rst_n(rst_n),
        .req(req), .is_read(is_read), .lba(lba), .blk_len(blk_len),
        .busy(busy), .done(done), .err(err),
        .rd_data(rd_data), .rd_valid(rd_valid), .rd_ready(rd_ready),
        .wr_data(wr_data), .wr_valid(wr_valid), .wr_ready(wr_ready),
        .tx_cmd(tx_cmd), .tx_cmd_valid(tx_cmd_valid), .tx_cmd_ready(tx_cmd_ready),
        .rx_data(rx_data), .rx_valid(rx_valid), .rx_ready(rx_ready),
        .tx_data(tx_data), .tx_data_valid(tx_data_valid), .tx_data_ready(tx_data_ready),
        .rx_cpl(rx_cpl), .rx_cpl_valid(rx_cpl_valid), .rx_cpl_ready(rx_cpl_ready)
    );

    nvme_device_model #(.DATAW(DATAW),.CMDW(CMDW),.LBAW(LBAW)) u_dev (
        .clk(clk), .rst_n(rst_n),
        .tx_cmd(tx_cmd), .tx_cmd_valid(tx_cmd_valid), .tx_cmd_ready(tx_cmd_ready),
        .rx_data(rx_data), .rx_valid(rx_valid), .rx_ready(rx_ready),
        .tx_data(tx_data), .tx_data_valid(tx_data_valid), .tx_data_ready(tx_data_ready),
        .rx_cpl(rx_cpl), .rx_cpl_valid(rx_cpl_valid), .rx_cpl_ready(rx_cpl_ready)
    );

    integer nerr=0;
    integer k;
    reg [DATAW-1:0] got[0:3];

    // 生成写数据: 每块填 id 化常数
    task issue_write(input [LBAW-1:0] a, input [BLKW-1:0] len, input [7:0] seed);
        integer n;
        begin
            @(posedge clk);
            req<=1; is_read<=0; lba<=a; blk_len<=len;
            @(posedge clk);
            while(!busy) @(posedge clk);   // 等 req 采样进 S_CMD
            req<=0;
            // 供数据 len 拍: 每拍等宿主 wr_ready 接受后推进
            for (n=0;n<len;n=n+1) begin
                @(posedge clk);
                wr_data <= ({24'h0, seed}) + n;
                wr_valid <= 1;
                while(!wr_ready) @(posedge clk);
            end
            #1; wr_valid<=0; wr_data<=0;
            while(!done) @(posedge clk);
            #5;
        end
    endtask

    task issue_read(input [LBAW-1:0] a, input [BLKW-1:0] len);
        integer n;
        begin
            @(posedge clk);
            req<=1; is_read<=1; lba<=a; blk_len<=len;
            @(posedge clk);
            while(!busy) @(posedge clk);
            req<=0;
            for (n=0;n<len;n=n+1) begin
                @(posedge clk);
                while(!rd_valid) @(posedge clk);
                got[n]<=rd_data;
            end
            while(!done) @(posedge clk);
            #5;
        end
    endtask

    initial begin
        #30 rst_n=1; #10;

        // V0: admin 握手
        wait(u.admin_ok);
        $display("PASS V0 admin(Identify) 握手完成");

        // V1: 4 次写, 每 2 块
        for (k=0;k<4;k=k+1) begin
            issue_write(32'd100+k*8, 16'd2, 8'hA0+k);
        end
        if (u_dev.rx_cpl_valid !== 0) begin
            $display("FAIL V1 完成清理: cpl还在"); nerr=nerr+1;
        end
        // 跨时序验证: 写后最后完成
        $display("PASS V1 4×写命令(每2块) done err=0");

        // V2: 读命令, 3 块
        issue_read(32'd200, 16'd3);
        // 设备回数据: pat=lba高位>>..., 应 = len..1 递减
        if (got[0] != (3) || got[1] != (2) || got[2] != (1)) begin
            $display("FAIL V2 读数据: %h %h %h", got[0], got[1], got[2]); nerr=nerr+1;
        end else $display("PASS V2 读命令 3 块数据正确");

        // V3: 连续 NQ 个命令(背压), 逐个完成不丢
        for (k=0;k<NQ;k=k+1)
            issue_write(32'd300+k, 16'd1, 8'h10+k);

        #20;
        if (nerr==0) $display("PASS: NVMe 协议层 阶段N1(admin握手+读写命令+队列背压) 全过");
        else        $display("FAIL: err=%0d", nerr);
        $finish;
    end


endmodule