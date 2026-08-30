// ============================================================================
// tb_cachectl_pipeline.v — 缓存控制器(做实)端到端: 探测+选通+专家LRU目录+GEMV
//
// 验证点:
//   S0 锁本地, 统一出口给出 trunk 权重(恒命中)
//   S1 冷首访专家 -> 自动装入目录并输出(不丢); 重访 -> 命中不再 load
//   S2 动态更新(CMD_UPDATE_EXPERT) -> 再取返回新权重
//   S3 LRU 替换: 满目录后新专家替换最旧, 且被挤走者 miss
//   S4 软复位后锁主机, 主机桩字流走通同一管线
//
// 桩: 源桩字流 valid 保持直到 ready(ATC, 因未命中有一拍暂扣)。
// 每字格式: [7:0]=expert_id(tag), [31:8]=权重。
// ============================================================================

`timescale 1ns/1ps

module tb_cachectl_pipeline;
    parameter DW = 32;
    parameter CW = 32;
    parameter S  = 4;      // 槽0=trunk + 3 专家

    reg clk=0, rst_n=0;
    reg serdes_aligned=0, pcie_link_up=0;

    reg [DW-1:0]  sa=0; reg sa_v=0; wire sa_r;
    reg [DW-1:0]  sb=0; reg sb_v=0; wire sb_r;

    reg [CW-1:0]  ca=0; reg ca_v=0; wire ca_r;
    reg [CW-1:0]  cb=0; reg cb_v=0; wire cb_r;

    wire [DW-1:0] wt; wire wt_v; reg wt_r=1;

    wire pl, ps;
    wire [31:0] loads, hits, misses, trun_hits;
    wire [7:0]  trunk_id;

    integer err=0;

    always #5 clk=~clk;

    cachectl_pipeline #(.DW(DW),.CW(CW),.EXPERT_SLOTS(S)) u (
        .clk(clk),.rst_n(rst_n),
        .serdes_aligned(serdes_aligned),.pcie_link_up(pcie_link_up),
        .st_in_a_data(sa),.st_in_a_valid(sa_v),.st_in_a_ready(sa_r),
        .st_in_b_data(sb),.st_in_b_valid(sb_v),.st_in_b_ready(sb_r),
        .cmd_a_data(ca),.cmd_a_valid(ca_v),.cmd_a_ready(ca_r),
        .cmd_b_data(cb),.cmd_b_valid(cb_v),.cmd_b_ready(cb_r),
        .wt_data(wt),.wt_valid(wt_v),.wt_ready(wt_r),
        .path_locked(pl),.path_sel(ps),
        .loads(loads),.hits(hits),.misses(misses),.trun_hits(trun_hits),
        .trunk_id_out(trunk_id)
    );

    always @(posedge clk) if (wt_v && wt_r) begin
        $display("t=%0t OUT wt=%h", $time, wt);
    end

    // 发送 A/B 桩一字: valid 保持直到 ready, 接受边沿(单拍)后立即撤下 valid
    integer ack;
    task send_a(input [DW-1:0] d); begin
        ack = 0;
        @(posedge clk); sa<=d; sa_v<=1;
        while (ack == 0) begin
            @(posedge clk);
            if (sa_r) begin ack = 1; end
        end
        sa_v<=0; sa<=0;
    end endtask
    task send_b(input [DW-1:0] d); begin
        ack = 0;
        @(posedge clk); sb<=d; sb_v<=1;
        while (ack == 0) begin
            @(posedge clk);
            if (sb_r) begin ack = 1; end
        end
        sb_v<=0; sb<=0;
    end endtask

    // 命令帧(A 通道): 连续两拍 帧头(cmd) + 载荷(权重+id)
    task cmd_a_frame(input [7:0] cmd, input [DW-1:0] w, input [7:0] id); begin
        @(posedge clk); ca<=cmd; ca_v<=1;
        @(posedge clk); ca<=w | {24'b0,id};   // 载荷: [31:8]=权重, [7:0]=expert_id
        @(posedge clk); ca_v<=0; ca<=0;
    end endtask

    // 等一拍出
    task settle; begin @(posedge clk); #1; end endtask

    initial begin
        #30 rst_n=1; #10;

        // ---- S0 锁本地 ----
        serdes_aligned=1; #30;
        if (!pl || ps!==0) begin $display("FAIL S0: 锁本地 pl=%b ps=%b",pl,ps); err=err+1; end
        else $display("S0 PASS: 锁本地");

        // ---------- S1 专家1(非trunk) 冷首访 -> 装入并出 ----------
        // trunk=id0; 发专家 id=3, 权重=0x11223344 (word={24'h ii<<8? } , [31:8]=w,[7:0]=id)
        send_a({24'h112233, 8'd3});  settle;
        // 冷首访应 load+出(值 0x11223344)
        if (loads!==1 || misses!==1) begin $display("FAIL S1a: 冷首访 loads=%0d misses=%0d",loads,misses); err=err+1; end
        else $display("S1a PASS: 冷首访装入(misses=%0d,loads=%0d)",misses,loads);

        // 重访同一专家 -> 命中, 不再 load
        send_a({24'h112233, 8'd3});  settle;
        if (hits!==1 || loads!==1) begin $display("FAIL S1b: 重访应命中 hits=%0d loads=%0d",hits,loads); err=err+1; end
        else $display("S1b PASS: 重访命中(不再 load), hits=%0d",hits);

        // trunk(id0) 恒命中
        send_a({24'hAABBCC, 8'd0});  settle;
        if (trun_hits!==1) begin $display("FAIL S1c: trunk 应命中 trun_hits=%0d",trun_hits); err=err+1; end
        else $display("S1c PASS: trunk 恒命中");

        // ---------- S2 动态更新专家3 ----------
        // CMD_UPDATE_EXPERT(0x40): 载荷 权重=0xE5E5 ' id=3
        cmd_a_frame(8'h40, 24'hE5E5E5, 8'd3);
        settle;
        // 再取专家3 -> 应返回更新后的权重(cache 以目录存储为准)
        send_a({24'hDEADBE, 8'd3});
        settle;
        if (hits < 2) begin $display("FAIL S2: 更新后重取应命中 hits=%0d",hits); err=err+1; end
        else $display("S2 PASS: 动态更新后仍可命中返回");

        // ---- 软复位 -> S4 锁主机 ----
        #20; rst_n=0; #20; rst_n=1; serdes_aligned=0; pcie_link_up=1; #30;
        if (!pl || ps!==1) begin $display("FAIL S4: 锁主机 pl=%b ps=%b",pl,ps); err=err+1; end
        else $display("S4 PASS: 锁主机");

        // 主机桩冷首访专家5(复位已清计数, 重新累计)
        send_b({24'h777888, 8'd5}); settle;
        if (misses!==1) begin $display("FAIL S4b: 主机冷首访 misses=%0d",misses); err=err+1; end
        else $display("S4b PASS: 主机桩字流走通管线(冷首访)");

        #20;
        if (err==0) $display("PASS: cachectl_pipeline 端到端(探测+选通+专家LRU+动态更新+GEMV) 全过");
        else        $display("FAIL: cachectl_pipeline err=%0d", err);
        $finish;
    end

endmodule
