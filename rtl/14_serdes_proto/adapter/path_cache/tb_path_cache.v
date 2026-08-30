// ============================================================================
// tb_path_cache.v — cachectl_top 骨架: 路径自动识别 + 统一权重流 + 命令来源可切
//
// 三场景:
//   S1 仅 SerDes 对齐 -> 锁路径1(本地), A 路权重流经 GEMV 口流出, B 路被刹停
//   S2 软复位后仅 PCIe link-up -> 锁路径2(主机), B 路流出
//   S3 权重流贯穿两路径(验证选通后数据正确流出)
//   S4 CMD_UPDATE_EXPERT 分别从本地(A)与主机(B)命令通道发入,
//       expert_updates 均+1, 且 last_src 记录真实来源
//       => 证明"动态更新"动作出处可切, 两路收敛到同一命令处理点
// ============================================================================

`timescale 1ns/1ps

module tb_path_cache;
    parameter DW = 32;
    parameter CW = 32;

    reg clk=0, rst_n=0;
    reg serdes_aligned=0, pcie_link_up=0;

    // 两条路径的权重字流桩 + 命令通道桩
    reg [DW-1:0]  sa_data=0; reg sa_valid=0; wire sa_ready;
    reg [DW-1:0]  sb_data=0; reg sb_valid=0; wire sb_ready;
    reg [CW-1:0]  ca_data=0; reg ca_valid=0; wire ca_ready;
    reg [CW-1:0]  cb_data=0; reg cb_valid=0; wire cb_ready;

    wire [DW-1:0] wt_data; wire wt_valid; reg wt_ready=1;

    wire  path_locked, path_sel;
    wire [31:0] expert_updates;
    wire [7:0]  last_expert_id;
    wire [31:0] last_src;

    integer err=0;

    always #5 clk = ~clk;

    cachectl_top #(.DW(DW), .CW(CW)) u (
        .clk(clk), .rst_n(rst_n),
        .serdes_aligned(serdes_aligned), .pcie_link_up(pcie_link_up),
        .st_in_a_data(sa_data), .st_in_a_valid(sa_valid), .st_in_a_ready(sa_ready),
        .st_in_b_data(sb_data), .st_in_b_valid(sb_valid), .st_in_b_ready(sb_ready),
        .cmd_a_data(ca_data), .cmd_a_valid(ca_valid), .cmd_a_ready(ca_ready), .cmd_a_last(1'b0),
        .cmd_b_data(cb_data), .cmd_b_valid(cb_valid), .cmd_b_ready(cb_ready), .cmd_b_last(1'b0),
        .wt_data(wt_data), .wt_valid(wt_valid), .wt_ready(wt_ready),
        .path_locked(path_locked), .path_sel(path_sel),
        .expert_updates(expert_updates), .last_expert_id(last_expert_id), .last_src(last_src)
    );

    integer got_a=0, got_b=0;      // GEMV 出口计数(按路径)

    always @(posedge clk) begin
        if (wt_valid && wt_ready) begin
            if (path_sel==0) got_a <= got_a+1;
            else             got_b <= got_b+1;
        end
    end

    // ---- 单拍桩发送 ----
    task st_a(input [DW-1:0] d); begin @(posedge clk); sa_data<=d; sa_valid<=1; end
        wait(sa_ready); @(posedge clk); sa_valid<=0; sa_data<=0; endtask
    task st_b(input [DW-1:0] d); begin @(posedge clk); sb_data<=d; sb_valid<=1; end
        wait(sb_ready); @(posedge clk); sb_valid<=0; sb_data<=0; endtask

    // ---- 命令帧: 连续两拍 (帧头 + 载荷), 末拍 valid 拉回 ----
    task cmd_frame(input [CW-1:0] hdr, input [CW-1:0] pay); begin
        @(posedge clk); ca_data<=hdr; ca_valid<=1;
        @(posedge clk); ca_data<=pay;                 // 第二拍载荷,仍保持 valid
        if (hdr[7:0]==8'h40) $display("t=%0t CMD-A frame head=40 pay=%h", $time, pay);
        @(posedge clk); ca_valid<=0; ca_data<=0;
    end endtask

    task cmd_frame_b(input [CW-1:0] hdr, input [CW-1:0] pay); begin
        @(posedge clk); cb_data<=hdr; cb_valid<=1;
        @(posedge clk); cb_data<=pay;
        if (hdr[7:0]==8'h40) $display("t=%0t CMD-B frame head=40 pay=%h", $time, pay);
        @(posedge clk); cb_valid<=0; cb_data<=0;
    end endtask

    initial begin
        // ===== reset =====
        rst_n=0; #30 rst_n=1; #10;

        // ---- S1: 仅 SerDes 对齐 -> 锁本地 ----
        serdes_aligned=1;
        #30;
        if (!path_locked || path_sel!==0) begin
            $display("FAIL S1: 未锁本地 locked=%b sel=%b", path_locked, path_sel); err=err+1;
        end else $display("S1 PASS: 锁本地 sel=0");

        // A 路发 2 个普通权重字 -> 应流出(GEMV 口 got_a 计数)
        st_a(32'h11111111);
        st_a(32'h22222222);
        #20;
        if (got_a !== 2) begin
            $display("FAIL S1: A 路权重应流出 2 字, 实得 %0d (B=%0d)", got_a, got_b); err=err+1;
        end else $display("S1 PASS: 本地权重流经统一出口(GEMV) 2 字");

        // S4a: 本地命令通道发 CMD_UPDATE_EXPERT(id=7), id 在 [7:0]
        cmd_frame(32'h00000040, 32'h00000007);   // cmd=0x40 帧头 + payload id=7
        #20;
        if (expert_updates !== 1 || last_expert_id !== 7 || last_src !== 0) begin
            $display("FAIL S4a: 本地CMD专家更新 upd=%0d id=%0d src=%0d(期望 1/7/0)", expert_updates, last_expert_id, last_src); err=err+1;
        end else $display("S4a PASS: 本地 CMD_UPDATE_EXPERT 生效 (upd=%0d src=本地)", expert_updates);

        // ---- 软复位 -> S2: 仅 PCIe link-up -> 锁主机 ----
        #20; rst_n=0; #20; rst_n=1; serdes_aligned=0; pcie_link_up=1; #30;
        if (!path_locked || path_sel!==1) begin
            $display("FAIL S2: 未锁主机 locked=%b sel=%b", path_locked, path_sel); err=err+1;
        end else $display("S2 PASS: 锁主机 sel=1");

        // B 路发 2 个普通权重字 -> 应流出
        st_b(32'h33333333);
        st_b(32'h44444444);
        #20;
        if (got_b !== 2) begin
            $display("FAIL S2: B 路权重应流出 2 字, 实得 %0d (A=%0d)", got_b, got_a); err=err+1;
        end else $display("S2 PASS: 主机权重流经统一出口(GEMV) 2 字");

        // S4b: 主机命令通道发 CMD_UPDATE_EXPERT(id=9)。
        // 注意: 软复位已清空 expert_updates, 故此时应=1(本帧), src=主机。
        cmd_frame_b(32'h00000040, 32'h00000009);
        #20;
        if (expert_updates !== 1 || last_expert_id !== 9 || last_src !== 1) begin
            $display("FAIL S4b: 主机CMD专家更新 upd=%0d id=%0d src=%0d(期望 1/9/1)", expert_updates, last_expert_id, last_src); err=err+1;
        end else $display("S4b PASS: 主机 CMD_UPDATE_EXPERT 生效 (upd=%0d src=主机)", expert_updates);

        #20;
        if (err==0) $display("PASS: path_cache 双路径自动识别+统一权重流+命令来源可切 全过");
        else        $display("FAIL: path_cache err=%0d", err);
        $finish;
    end

endmodule
