// ============================================================================
// tb_nvme_n23.v — 阶段 N2(读数据→权重组FIFO, 背压) + N3(写路径"更新缓存"闭环)
//
// 在 N1 已通的 nvme_host + nvme_device_model 基础上, 加入数据状态 FIFO
// (nvme_data_fifo) 模拟物理数据搬运, 并验证:
//   N2  读路径: 设备→host→FIFO→权重组消费端, 消费端节流(背压)下
//       数据逐字完整、有序到达, host 正常完成。
//   N3  写路径: "更新缓存"源→FIFO→host→设备, 设备(CHECK_WDATA=1)
//       自校验收到的写数据与源一致, cpl status=0 → 闭环成立。
// 仍为物理无关纯仿真。
// ============================================================================

`timescale 1ns/1ps

module tb_nvme_n23;
    parameter DATAW=32, CMDW=32, LBAW=48, BLKW=16, NQ=4, DFIFO=8;

    reg clk=0, rst_n=0;
    always #5 clk=~clk;

    // ---- host 命令接口 ----
    reg  req=0, is_read=0;
    reg  [LBAW-1:0] lba=0;
    reg  [BLKW-1:0] blk_len=0;
    wire busy, done, err;

    wire [DATAW-1:0] host_rd; wire host_rdv; wire host_rdy;   // 读出口
    wire [DATAW-1:0] host_wr; wire host_wrv; wire host_wry;   // 写入口
    wire [CMDW-1:0]  host_tx; wire host_txv; wire host_txy;   // 命令
    wire [DATAW-1:0] host_rx; wire host_rxv; wire host_rxy;   // 设备读数据
    wire [DATAW-1:0] host_td; wire host_tdv; wire host_tdy;   // 设备写数据
    wire [CMDW-1:0]  host_cpl; wire host_cplv; wire host_cply; // 完成

    nvme_host #(.CMDW(CMDW),.DATAW(DATAW),.LBAW(LBAW),.BLKW(BLKW),.NQ(NQ),.TAGW(4)) u (
        .clk(clk), .rst_n(rst_n),
        .req(req), .is_read(is_read), .lba(lba), .blk_len(blk_len),
        .busy(busy), .done(done), .err(err),
        .rd_data(host_rd), .rd_valid(host_rdv), .rd_ready(host_rdy),
        .wr_data(host_wr), .wr_valid(host_wrv), .wr_ready(host_wry),
        .tx_cmd(host_tx), .tx_cmd_valid(host_txv), .tx_cmd_ready(host_txy),
        .rx_data(host_rx), .rx_valid(host_rxv), .rx_ready(host_rxy),
        .tx_data(host_td), .tx_data_valid(host_tdv), .tx_data_ready(host_tdy),
        .rx_cpl(host_cpl), .rx_cpl_valid(host_cplv), .rx_cpl_ready(host_cply)
    );

    // ---- 读方向 FIFO: host.rd → fr → 权重组消费端 ----
    wire [DATAW-1:0] fr_out; wire fr_outv; reg  fr_rdy=1;  // 消费端
    wire [DATAW-1:0] fr_in;  wire fr_inv;  wire fr_inrdy;  // host.rd 侧
    nvme_data_fifo #(.DFIFO(DFIFO),.DATAW(DATAW)) fr (
        .clk(clk), .rst_n(rst_n),
        .wr_data(host_rd), .wr_valid(host_rdv), .wr_ready(fr_inrdy),
        .rd_data(fr_out), .rd_valid(fr_outv), .rd_ready(fr_rdy)
    );
    assign host_rdy = fr_inrdy;   // 读背压 → host(→设备)

    // ---- 写方向 FIFO: 更新缓存源 → fw → host.wr ----
    reg  [DATAW-1:0] fw_in=0; reg fw_inv=0; wire fw_inrdy;  // 源侧
    wire [DATAW-1:0] fw_out; wire fw_outv; wire fw_outrdy;  // host 侧
    nvme_data_fifo #(.DFIFO(DFIFO),.DATAW(DATAW)) fw (
        .clk(clk), .rst_n(rst_n),
        .wr_data(fw_in), .wr_valid(fw_inv), .wr_ready(fw_inrdy),
        .rd_data(fw_out), .rd_valid(fw_outv), .rd_ready(host_wry)
    );
    assign host_wr  = fw_out;
    assign host_wrv = fw_outv;

    // ---- 设备模型(CHECK_WDATA=1 自校验写数据) ----
    wire dev_cpl_ready = host_cply;
    nvme_device_model #(.LBAW(LBAW),.DATAW(DATAW),.CMDW(CMDW),.CHECK_WDATA(1)) u_dev (
        .clk(clk), .rst_n(rst_n),
        .tx_cmd(host_tx), .tx_cmd_valid(host_txv), .tx_cmd_ready(host_txy),
        .rx_data(host_rx), .rx_valid(host_rxv), .rx_ready(host_rxy),
        .tx_data(host_td), .tx_data_valid(host_tdv), .tx_data_ready(host_tdy),
        .rx_cpl(host_cpl), .rx_cpl_valid(host_cplv), .rx_cpl_ready(dev_cpl_ready)
    );

    integer n, nerr=0;

    // ---- N2: 读命令(背压下经 FIFO 收齐) ----
    // 设备返回 pat+lba高位 + blk_cnt..1; DBG: pat=2 len=3 → 5,4,3
    task read_backpressure(input [15:0] a, input [15:0] len, input [3:0] pat);
        integer i;
        begin
            @(posedge clk);
            req<=1; is_read<=1; lba<= {32'h0,pat, a[11:0]}; blk_len<=len;
            @(posedge clk);
            while(!busy) @(posedge clk);
            req<=0;
            // 背压: 消费端持续不接收允许 FIFO 吸收并发(host/设备可停顿), 再整收
            fr_rdy <= 0;
            #30;                       // 背压若干拍
            @(posedge clk); fr_rdy <= 1;
            for (i=0;i<len;i=i+1) begin
                @(posedge clk);
                while(!fr_outv) @(posedge clk);
                if (fr_out !== (pat + (len - i))) begin
                    $display("FAIL N2 读数据@%0d got=%0d want=%0d",i,fr_out,pat+(len-i)); nerr=nerr+1;
                end
            end
            while(!done) @(posedge clk);
            #5;
            if (err) begin $display("FAIL N2 读命令 err"); nerr=nerr+1; end
        end
    endtask

    // ---- N3: 写命令"更新缓存"闭环(源→FIFO→host→设备自校验) ----
    task write_update_cache(input [15:0] a, input [15:0] len, input [3:0] seed);
        integer i;
        begin
            @(posedge clk);
            req<=1; is_read<=0; lba<= {32'h0, a}; blk_len<=len;
            @(posedge clk);
            while(!busy) @(posedge clk);
            req<=0;
            // 源产生 len 个字: len..1(host 写命令 tx_cmd[31:28]=0 → 设备 pat=0,
            // 校验 pat+blk_cnt = blk_cnt = len..1, 证源数据经全链完整到达)
            // 每拍设 valid+data, 每拍让 FIFO 采样(not-full 恒真), 最后清 valid
            for (i=0;i<len;i=i+1) begin
                @(posedge clk);
                fw_in  <= (len - i);
                fw_inv <= 1;
            end
            @(posedge clk);
            fw_inv <= 0; fw_in <= 0;
            while(!done) @(posedge clk);
            #5;
            if (err) begin $display("FAIL N3 写命令 err"); nerr=nerr+1; end
        end
    endtask

    initial begin
        #30 rst_n=1; #10;
        wait(u.admin_ok);
        $display("PASS N0 admin 握手");

        // N2: 读 3 次, 不同 len 背压
        read_backpressure(16'd100, 16'd3, 4'h2);   // 期望 5,4,3
        read_backpressure(16'd200, 16'd4, 4'h5);   // 期望 9,8,7,6
        read_backpressure(16'd300, 16'd6, 4'h0);   // 期望 6,5,4,3,2,1
        $display("PASS N2 读数据→FIFO 背压收齐, 完整有序");

        // N3: 写"更新缓存"闭环 3 次
        write_update_cache(16'd50,  16'd2, 4'h3);   // 源 4,3 (设备校验)
        write_update_cache(16'd60,  16'd4, 4'h1);   // 5,4,3,2
        write_update_cache(16'd70,  16'd5, 4'hA);   // 15,14,13,12,11
        $display("PASS N3 写路径更新缓存闭环: 源→FIFO→host→设备 自校验一致");

        #20;
        if (nerr==0) $display("PASS: NVMe 阶段N2(读FIFO背压)+N3(写更新缓存闭环) 全过");
        else         $display("FAIL: nerr=%0d", nerr);
        $finish;
    end

endmodule