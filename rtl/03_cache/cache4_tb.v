`timescale 1ns/1ps
// 03_cache — 最终 TB：仅用端口断言。请求沿前摆好，沿后 #3 读结果。
module cache4_tb;
    reg clk = 0;
    reg rst = 1;
    reg req = 0;
    reg we  = 0;
    reg [9:0] tag = 0;
    reg [31:0] wdata = 0;
    wire [31:0] rdata;
    wire hit;
    wire [1:0] way;
    wire [31:0] hits, misses, pf_hits, pf_installs;

    cache4 #(.AW(10), .DW(32)) dut (
        .clk(clk), .rst(rst), .req(req), .we(we), .tag(tag), .wdata(wdata),
        .rdata(rdata), .hit(hit), .way(way), .hits(hits), .misses(misses),
        .pf_hits(pf_hits), .pf_installs(pf_installs)
    );

    integer errors = 0;
    integer req_no = 0;

    task do_req(input [9:0] t, input iswe, input [31:0] d,
                input eh, input [1:0] ew);
        begin
            #3 req = 1; tag = t; we = iswe; wdata = d;   // 沿前摆好
            @(posedge clk);                              // 沿采样结算
            req_no = req_no + 1;
            #2;                                          // 沿后读
            if (hit !== eh) begin
                $display("FAIL req#%0d tag=%h: hit=%b want=%b", req_no, t, hit, eh);
                errors = errors + 1;
            end
            if (way !== ew) begin
                $display("FAIL req#%0d tag=%h: way=%d want=%d", req_no, t, way, ew);
                errors = errors + 1;
            end
            #3;
            req = 0; we = 0;                             // 撤（两沿间）
        end
    endtask

    initial begin
        $display("=== 03_cache: 4-way x 4-set LRU ===");
        repeat (2) @(posedge clk);
        rst = 0;
        #1;

        // 期望值由 Python rank 模型推得（tag 用合法 10bit hex，0x400/0x500 会截断成 0）
        do_req(10'h000, 1, 32'hAAAA_BEEF, 0, 2'd3);
        do_req(10'h100, 1, 32'h1111_2222, 0, 2'd2);
        do_req(10'h200, 1, 32'h3333_4444, 0, 2'd1);
        do_req(10'h300, 1, 32'h5555_6666, 0, 2'd0);
        do_req(10'h000, 0, 0, 1, 2'd3);
        if (rdata !== 32'hAAAA_BEEF) begin
            $display("FAIL rdata T0 = %08h", rdata); errors = errors + 1;
        end
        do_req(10'h100, 0, 0, 1, 2'd2);
        if (rdata !== 32'h1111_2222) begin
            $display("FAIL rdata T1 = %08h", rdata); errors = errors + 1;
        end
        do_req(10'h040, 1, 32'h7777_8888, 0, 2'd1);   // evict way1(T2)
        do_req(10'h200, 0, 0, 0, 2'd0);               // T2 miss, evict way0(T3)
        do_req(10'h000, 0, 0, 1, 2'd3);               // T0 hit
        do_req(10'h040, 1, 32'h7777_8888, 1, 2'd1);   // T4 hit (rewrite)
        do_req(10'h300, 0, 0, 0, 2'd2);               // T3 miss, evict way1? no -> way2(T1)
        do_req(10'h080, 1, 32'h9999_AAAA, 0, 2'd0);
        do_req(10'h300, 0, 0, 1, 2'd2);
        

        $display("counts: hits=%0d misses=%0d", hits, misses);
        $display("03_cache: %0d errors", errors);
        if (errors == 0) $display("=== ALL PASS ===");
        else $display("=== %0d ERROR(S) ===", errors);
        $finish;
    end

    always #5 clk = ~clk;
endmodule