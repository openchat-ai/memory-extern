`default_nettype none
//────────────────────────────────────────────────────────────────────────────
// sram_pool_arb.v — MAC 热存储池 512KB 时分仲裁 (§6)
//
// 两口请求 (GEMM 段 g_* / attn 段 a_*), 每口一组 ready/valid 单字握手,
// 指向同一物理 SRAM 池。sel 选当前所有权:
//   - 持权口被转发到池 (rdy=1), 非持权口一律 rdy=0 (时分的互斥性来自此);
//   - 权限切换为"静默切换": 仅当无在途操作 (inflight=0) 时提交 sel,
//     否则挂起 (pend) 等到在途完成——保证 A 段在途写不会跨进 B 段的读。
// 池为单周期 SRAM 模型: 读=1 周期维护 (登记地址, 次沿 rdata)。
// 簿记: g_ops/a_ops 分口接受计数, switches 切换计数。
//────────────────────────────────────────────────────────────────────────────
module sram_pool_arb #(
    parameter AW = 8,
    parameter DW = 32
)(
    input  wire         clk,
    input  wire         rst_n,
    input  wire         sel,               // 0=GEMM 持权, 1=attn 持权

    input  wire         g_valid, g_we,
    input  wire [AW-1:0] g_addr,
    input  wire [DW-1:0] g_wdata,
    output wire         g_rdy,
    output wire [DW-1:0] g_rdata,

    input  wire         a_valid, a_we,
    input  wire [AW-1:0] a_addr,
    input  wire [DW-1:0] a_wdata,
    output wire         a_rdy,
    output wire [DW-1:0] a_rdata,

    output reg  [31:0]  g_ops,
    output reg  [31:0]  a_ops,
    output reg  [31:0]  switches
);

    reg [DW-1:0] mem [0:(1<<AW)-1];

    reg       act;                         // 实际持权 (已提交)
    reg       pend;                        // 待切换目标
    reg       inflight;
    reg [AW-1:0] raddr;

    wire gemm_own = (act == 1'b0);
    wire attn_own = !gemm_own;

    // 组合: 持权口见到 rdy, 数据直通
    assign g_rdy   = gemm_own;
    assign g_rdata = mem[raddr];
    assign a_rdy   = attn_own;
    assign a_rdata = mem[raddr];

    // 接受沿 (仅当持权口 rdy && valid)
    wire g_accept = gemm_own & g_valid;
    wire a_accept = attn_own & a_valid;

    // 静默切换: sel 变化时, 等 inflight 清空再提交
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            act <= 0; pend <= 0; inflight <= 0;
            raddr <= 0;
            g_ops <= 0; a_ops <= 0; switches <= 0;
        end else begin
            //---- 切换请求/提交 ----
            if (sel != act)                // 有人要求换权
                pend <= sel;
            if (pend != act && !inflight) begin   // 静默完成 -> 提交
                act <= pend;
                switches <= switches + 1;
            end

            //---- 池操作 (仅持权口) ----
            if (g_accept) begin
                if (g_we) mem[g_addr] <= g_wdata;
                else      raddr <= g_addr;
                g_ops <= g_ops + 1;
                inflight <= 1;
            end else if (a_accept) begin
                if (a_we) mem[a_addr] <= a_wdata;
                else      raddr <= a_addr;
                a_ops <= a_ops + 1;
                inflight <= 1;
            end else begin
                inflight <= 0;
            end
        end
    end

endmodule
`default_nettype wire