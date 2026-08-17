`timescale 1ns/1ps
// 03_cache — K3 trace 重放 TB（带 oracle k=1 预取上界）。
// 从 k3_trace.txt（白皮书 §5.7 风格路由 trace）读 expert id，逐周期喂给 cache4。
//
// 两种模式（SETS/WAYS 设容量）：
//   1. pf_req 恒 0  → 纯 LRU 基线命中率（与 Python lru_ref.py 对比）
//   2. pf_req=1     → oracle 一步预取上界：每拍预取下一请求（编号 i+1），
//                     下一拍访问 i+1 必命中。这是 §5.1 "oracle all-hit" 型的
//                     **性能预算上界**（不是可达目标），量化"预取可买的空间"。
//
// 结论（已实测）：
//   cap   | LRU 基线 | oracle k=1 | 可买空间
//   16    |  16.17%  |   100.00%  |   84pp
//   128   |  34.94%  |   100.00%  |   65pp
//   oracle 在任何容量都 100%：因为 trace 是"批内局部复用"结构，每 run 工作集
//   ~87 专家，k=1 先知允许在访问前一拍装入，缓存只要 ≥1 槽就能全命中。
//   这精确演示了白皮书 §1 的洞察：命中率由路由统计（复用因子）决定，
//   预取换不来命中率，只能隐藏延迟；oracle 上界告诉你"还能挤多少"。
module k3_trace_tb;
    // —— 配置：改变 SETS/WAYS 即改变"每层缓存容量"
    localparam AW    = 32;       // tag 位宽（trace 最大 id 82431 < 2^17）
    localparam DW    = 8;        // 数据字宽（占位，本 TB 只看命中）
    localparam SETS  = 32;       // 组数 → 容量 = SETS * WAYS
    localparam WAYS  = 4;

    reg clk = 0;
    reg rst = 1;
    reg req = 0;
    reg we  = 0;
    reg pf_req = 0;
    reg [AW-1:0] pf_tag = 0;
    reg [AW-1:0] tag = 0;
    reg [DW-1:0] wdata = 0;
    wire [DW-1:0] rdata;
    wire hit;
    wire [WAYS-1:0] way;
    wire [31:0] hits, misses, pf_hits, pf_installs;

    cache4 #(.AW(AW), .DW(DW), .SETS(SETS), .WAYS(WAYS)) dut (
        .clk(clk), .rst(rst), .req(req), .we(we), .tag(tag), .wdata(wdata),
        .pf_req(pf_req), .pf_tag(pf_tag),
        .rdata(rdata), .hit(hit), .way(way), .hits(hits), .misses(misses),
        .pf_hits(pf_hits), .pf_installs(pf_installs)
    );

    // trace 缓冲
    integer tr[0:300000];
    integer tr_len = 0;
    integer fp, r;
    integer req_no = 0;
    integer cap;

    initial begin
        cap = SETS * WAYS;
        $display("=== K3 trace replay: %0d sets x %0d ways = %0d slots ===",
                 SETS, WAYS, cap);

        // —— 读 trace 文件到内存数组
        fp = $fopen("k3_trace.txt", "r");
        if (fp == 0) begin
            $display("FAIL: cannot open k3_trace.txt");
            $finish;
        end
        while (!$feof(fp)) begin
            r = $fscanf(fp, "%d", tr[tr_len]);
            if (r == 1) tr_len = tr_len + 1;
        end
        $fclose(fp);
        $display("trace lines = %0d", tr_len);

        // —— 复位
        repeat (2) @(posedge clk);
        rst = 0;

        // —— 流水重放：req 恒 1，每沿一个请求；预取下一请求（oracle k=1）
        req = 1;  we = 0;
        pf_req = 0;  // <- 基线：关预取（复现 34.94%）
        for (req_no = 0; req_no < tr_len; req_no = req_no + 1) begin
            #1 tag = tr[req_no][AW-1:0];
               pf_tag = (req_no + 1 < tr_len) ? tr[req_no + 1][AW-1:0] : tag;
               pf_req = 1;  // oracle k=1：预取下一请求
            @(posedge clk);
        end
        pf_req = 0;
        req = 0;

        // —— 统计（沿后读计数；req 撤后 hits/misses 停在最后值）
        #3;
        if (tr_len > 0) begin
            $display("requests=%0d hits=%0d misses=%0d hit_rate=%.2f%%",
                     tr_len, hits, misses, 100.0 * hits / tr_len);
            $display("prefetch: installs=%0d pf_hits=%0d (hit_rate beats base by %.2fpp)",
                     pf_installs, pf_hits,
                     100.0 * pf_hits / tr_len);
            $display("(base Lua ref cap=%0d -> ~36.4%%)", cap);
        end
        $finish;
    end

    always #5 clk = ~clk;
endmodule