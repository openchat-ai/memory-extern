`timescale 1ns/1ps
//────────────────────────────────────────────────────────────────────────────
// tb_sram_pool_arb.v — 512KB 池时分仲裁测试
//
//   1) GEMM 持权 (sel=0): 写 8 读 6, 期间 attn 请求被拒 rdy=0 且不计数
//   2) 静默切换: 在 g 读在途的沿上翻 sel -> 在途完成才提交, 再转入 attn
//   3) attn 持权 (sel=1): 写 4 读 4 (高区), 此时 g_rdy=0 且 g 请求被拒
//   4) 回 GEMM (sel=0): 双段数据各自落位且共存 (gemm 区 + attn 区)。
//
// 验收: rdata 逐字对账 / g_ops=23(8写+6读+1切换在途读+8终读) a_ops=8 / switches=2 / 持权互斥无漏。
//
// 握手纪律 (踩坑沉淀): 请求在沿前置位 (沿前有效), 沿后撤/reset 一律用
// 非阻塞 (<=); 同 delta 的阻塞撤赋值会先于模块采样落入, 被模块当成
// "we 已撤" 而走读路径 (g_ops 照加但写不进 mem) —— 本文件全部规避。
//────────────────────────────────────────────────────────────────────────────

module tb;
    localparam AW = 8, DW = 32;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg sel, g_valid, g_we, a_valid, a_we;
    reg [AW-1:0] g_addr, a_addr;
    reg [DW-1:0] g_wdata, a_wdata;
    wire g_rdy, a_rdy;
    wire [DW-1:0] g_rdata, a_rdata;
    wire [31:0] g_ops, a_ops, switches;

    sram_pool_arb #(.AW(AW), .DW(DW)) u (
        .clk(clk), .rst_n(rst_n), .sel(sel),
        .g_valid(g_valid), .g_we(g_we), .g_addr(g_addr), .g_wdata(g_wdata),
        .g_rdy(g_rdy), .g_rdata(g_rdata),
        .a_valid(a_valid), .a_we(a_we), .a_addr(a_addr), .a_wdata(a_wdata),
        .a_rdy(a_rdy), .a_rdata(a_rdata),
        .g_ops(g_ops), .a_ops(a_ops), .switches(switches));

    integer fail, i, k;

    task gwr(input integer a, input integer d);   // GEMM 写: 一拍沿握手
        begin
            g_valid = 1; g_we = 1; g_addr = a; g_wdata = d;
            @(posedge clk);
            g_valid <= 0; g_we <= 0;
        end
    endtask

    task grd(input integer a, input integer exp); // GEMM 读比对
        begin
            g_valid = 1; g_we = 0; g_addr = a;
            @(posedge clk);                 // 接受沿: raddr 登记
            g_valid <= 0;
            @(posedge clk);                 // 数据沿: rdata = mem[raddr]
            if (g_rdata !== exp) begin
                $display("  *** GEMM 读 addr%0d -> %0d, 期望 %0d", a, g_rdata, exp);
                fail = 1;
            end
        end
    endtask

    task awr(input integer a, input integer d);   // attn 写
        begin
            a_valid = 1; a_we = 1; a_addr = a; a_wdata = d;
            @(posedge clk);
            a_valid <= 0; a_we <= 0;
        end
    endtask

    task ard(input integer a, input integer exp); // attn 读比对
        begin
            a_valid = 1; a_we = 0; a_addr = a;
            @(posedge clk);
            a_valid <= 0;
            @(posedge clk);
            if (a_rdata !== exp) begin
                $display("  *** attn 读 addr%0d -> %0d, 期望 %0d", a, a_rdata, exp);
                fail = 1;
            end
        end
    endtask

    initial begin
        sel <= 0; g_valid <= 0; g_we <= 0; g_addr <= 0; g_wdata <= 0;
        a_valid <= 0; a_we <= 0; a_addr <= 0; a_wdata <= 0;
        fail = 0;
        #20 rst_n = 1; @(posedge clk); @(posedge clk);

        //---------------- 1) GEMM 持权: 写8读6, attn 被拒 ----------------
        $display("== 1) GEMM 持权 (sel=0): 写8读6, attn 被拒 ==");
        for (i = 0; i < 8; i = i + 1) begin
            gwr(i, 1000 + i);
            @(posedge clk);               // 两沿间隔, 规避同沿撤值
        end
        // attn 请求此刻被拒 (rdy=0), 不计数
        a_valid = 1; a_we = 1; a_addr = 31; a_wdata = 777;
        @(posedge clk);
        a_valid <= 0; a_we <= 0;
        @(posedge clk);
        if (a_rdy !== 1'b0) begin $display("  *** attn 应被拒但 rdy=1"); fail = 1; end
        if (a_ops !== 0)    begin $display("  *** attn 被拒却计数 a_ops=%0d", a_ops); fail = 1; end
        for (i = 0; i < 6; i = i + 1) begin
            grd(i, 1000 + i);
        end

        //---------------- 2) 静默切换: 在途读完才交权 --------------------
        $display("== 2) 静默切换: 在途读那沿翻 sel ==");
        g_valid = 1; g_we = 0; g_addr = 0;  // 起一写在途读
        @(posedge clk);                      // 接受沿 -> inflight=1
        g_valid <= 0;
        sel = 1;                             // 立即要求换权 (在途未清, 阻塞置位)
        @(posedge clk);                      // pend=1, inflight 仍 1 -> 不提交
        @(posedge clk);                      // 在途清空
        k = 0;
        while (u.act !== 1'b1 && k < 8) begin  // 静默完成: act<=pending (下沿)
            @(posedge clk);
            k = k + 1;
        end
        if (u.act !== 1'b1) begin $display("  *** 切换未提交 act=%0b", u.act); fail = 1; end
        if (switches !== 1) begin $display("  *** switches=%0d 期望 1", switches); fail = 1; end
        if (g_rdata !== 1000) begin $display("  *** 在途/读回 %0d 期望 1000", g_rdata); fail = 1; end
        if (g_rdy !== 1'b0 || a_rdy !== 1'b1)
            begin $display("  *** 权权移交后 rdy 错 g=%0b a=%0b", g_rdy, a_rdy); fail = 1; end

        //---------------- 3) attn 持权: 写4读4 (高区), g 被拒 ----------------
        $display("== 3) attn 持权: 写4读4 (高区), g_rdy=0 ==");
        for (i = 0; i < 4; i = i + 1) begin
            awr(8 + i, 2000 + i);
            @(posedge clk);
        end
        // g 请求此刻被拒
        g_valid = 1; g_we = 1; g_addr = 3; g_wdata = 555;
        @(posedge clk);
        g_valid <= 0; g_we <= 0;
        @(posedge clk);
        if (g_rdy !== 1'b0) begin $display("  *** g 应被拒但 rdy=1"); fail = 1; end
        if (g_ops !== 15)   begin $display("  *** g 被拒却计数 g_ops=%0d", g_ops); fail = 1; end
        for (i = 0; i < 4; i = i + 1) begin
            ard(8 + i, 2000 + i);
        end

        //---------------- 4) 回 GEMM: 双段数据共存 -----------------------
        $display("== 4) 回 GEMM: 池中双段数据各自共存 ==");
        sel = 0;
        repeat (4) @(posedge clk);           // 静默提交再入 GEMM (switches=2)
        if (switches !== 2) begin $display("  *** switches=%0d 期望 2", switches); fail = 1; end
        for (i = 0; i < 4; i = i + 1) begin  // GEMM 区内数据原封
            grd(i, 1000 + i);
        end
        for (i = 0; i < 4; i = i + 1) begin  // attn 区数据原封
            grd(8 + i, 2000 + i);
        end

        //---------------- 终态 -----------------------
        $display("== 终态 ==");
        $display("  g_ops=%0d (期望23) a_ops=%0d (期望8) switches=%0d (期望2)", g_ops, a_ops, switches);
        if (g_ops !== 23 || a_ops !== 8 || switches !== 2) fail = 1;

        if (fail) begin
            $display("##################  FAIL ##################");
        end else begin
            $display("##### ALL PASS: 高分闸时分池收工 #####");
        end
        $finish;
    end

    initial begin
        #3000000 $display("[timeout] 仿真超时未结束"); $finish;
    end
endmodule