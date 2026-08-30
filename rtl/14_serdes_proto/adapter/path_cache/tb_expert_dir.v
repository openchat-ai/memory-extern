// ============================================================================
// tb_expert_dir.v — 专家 LRU 目录行为验证
//
// 验证点:
//   T1 trunk 恒命中(永久驻留, 不占专家 LRU)
//   T2 专家加载+命中返回权重; 未命中给出 LRU 待替换槽
//   T3 LRU 替换: 装满后访问新专家, 替换最久未访问槽
//   T4 动态更新: upd 改专家权重, 再取返回新值
//
// 时序约定: req_* 为组合输出。驱动(阻塞)后在同一时刻立即重算, 故在
//   负沿(半周期稳定窗口)阻塞设 valid, 组合稳定后采样到模块级 g_*。
// ============================================================================

`timescale 1ns/1ps

module tb_expert_dir;
    parameter DW = 32;
    parameter S  = 4;      // 槽0=trunk + 3 专家

    reg clk=0, rst_n=0;
    reg [7:0]    trunk_id=8'd99; reg [DW-1:0] trunk_data='hABCD_1234;
    reg req_valid=0; reg [7:0] req_tag=0;
    wire req_hit; wire [7:0] req_way; wire [DW-1:0] req_data; wire req_is_trunk;
    reg load_valid=0; reg [7:0] load_way=0, load_tag=0; reg [DW-1:0] load_data=0;
    reg upd_valid=0; reg [7:0] upd_id=0; reg [DW-1:0] upd_data=0;

    reg g_hit; reg [7:0] g_way; reg [DW-1:0] g_data; reg g_trunk;

    integer err=0;

    always #5 clk=~clk;

    expert_dir #(.DW(DW), .EXPERT_SLOTS(S)) u (
        .clk(clk), .rst_n(rst_n),
        .trunk_id(trunk_id), .trunk_data(trunk_data),
        .req_valid(req_valid), .req_tag(req_tag),
        .req_hit(req_hit), .req_way(req_way), .req_data(req_data), .req_is_trunk(req_is_trunk),
        .load_valid(load_valid), .load_way(load_way), .load_tag(load_tag), .load_data(load_data),
        .upd_valid(upd_valid), .upd_id(upd_id), .upd_data(upd_data)
    );

    // 请求: NB 驱动 valid 一拍; 在 valid 仍高的次一拍(posedge P1) 组合采样 g_*
    task do_req(input [7:0] t); begin
        @(posedge clk); req_tag<=t; req_valid<=1;   // P0 驱动
        @(posedge clk);                              // P1: req_valid=1, req_* 即结果
        g_hit = req_hit; g_way = req_way; g_data = req_data; g_trunk = req_is_trunk;
        req_valid<=0; req_tag<=0;                    // 撤(生效 P1 后)
    end endtask

    // 加载/更新: NB 驱动; 在下一 posedge(P1) 落盘到目录
    task do_load(input [7:0] w, input [7:0] tg, input [DW-1:0] d); begin
        @(posedge clk); load_way<=w; load_tag<=tg; load_data<=d; load_valid<=1;
        @(posedge clk); load_valid<=0; load_way<=0; load_data<=0;
    end endtask

    task do_upd(input [7:0] id, input [DW-1:0] d); begin
        @(posedge clk); upd_id<=id; upd_data<=d; upd_valid<=1;
        @(posedge clk); upd_valid<=0; upd_data<=0;
    end endtask

    initial begin
        #30 rst_n=1; #10;

        // ---- T1 trunk 恒命中 ----
        do_req(8'd99);
        if (!g_hit || g_data !== 'hABCD_1234 || !g_trunk) begin
            $display("FAIL T1: trunk h=%b d=%h is_t=%b", g_hit, g_data, g_trunk); err=err+1;
        end else $display("T1 PASS: trunk 恒命中");

        // ---- T2a 加载专家1,2 ----
        do_load(1, 8'd1, 32'h0000_0001);
        do_load(2, 8'd2, 32'h0000_0002);
        do_req(8'd2);
        if (!g_hit || g_data !== 32'h0000_0002 || g_trunk) begin
            $display("FAIL T2a: 专家2命中 h=%b d=%h", g_hit, g_data); err=err+1;
        end else $display("T2a PASS: 专家2命中返回权重");

        // ---- T2b 未命中专家3 ---- 
        do_req(8'd3);
        if (g_hit) begin
            $display("FAIL T2b: 未命中却报 hit"); err=err+1;
        end else $display("T2b PASS: 未命中(待替换槽=%0d)", g_way);

        // ---- T3 LRU 替换: 装3个专家, 访问1/2使其新, 3最旧; 访问4->替换3 ----
        do_load(3, 8'd3, 32'h0000_0003);
        do_req(8'd1);   // 1 变最新
        do_req(8'd2);   // 2 变较新 => 3 最旧
        do_req(8'd4);   // 4 未命中 -> 期望替换 3(槽3)
        if (g_hit) begin
            $display("FAIL T3: 4 应未命中"); err=err+1;
        end else begin
            $display("T3a: 4未命中, 待替换槽=%0d", g_way);
        end
        // 加载到 g_way 槽
        do_load(g_way, 8'd4, 32'h0000_0004);
        do_req(8'd4);
        if (!g_hit || g_data !== 32'h0000_0004) begin
            $display("FAIL T3: 替换后 4 应命中 d=%h", g_data); err=err+1;
        end else $display("T3 PASS: LRU 替换后 4 命中");

        // ---- T3b 替换正确性: 挤掉的应是 LRU(3), 1/2 仍在 ----
        do_req(8'd1);
        if (!g_hit) begin $display("FAIL T3b: 1 应仍命中"); err=err+1; end
        do_req(8'd2);
        if (!g_hit) begin $display("FAIL T3b: 2 应仍命中"); err=err+1; end
        do_req(8'd3);
        if (g_hit)  begin $display("FAIL T3b: 3 应被挤出(未命中)"); err=err+1; end
        else $display("T3b PASS: 正确挤掉最久未访问的3, 1/2保留");

        // ---- T4 动态更新 ----
        do_upd(8'd4, 32'hDEAD_BEEF);
        do_req(8'd4);
        if (!g_hit || g_data !== 32'hDEAD_BEEF) begin
            $display("FAIL T4: 更新后 4 应返回新权重 d=%h", g_data); err=err+1;
        end else $display("T4 PASS: 动态更新生效");

        #20;
        if (err==0) $display("PASS: expert_dir 全过");
        else        $display("FAIL: expert_dir err=%0d", err);
        $finish;
    end

endmodule
