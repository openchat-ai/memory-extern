`default_nettype none
//────────────────────────────────────────────────────────────────────────────
// wb_channel.v — 层流写回通道 (v0 协议本体, §5)
//
// 引擎写侧推三类字:
//   tag 1: header { layer[7:0], type[1:0], len[21:0] }   (len = payload 字节数, 4 对齐)
//   tag 0: data   (payload 正文, 49,152B=12,288 字 / 1,152B=288 字)
//   tag 2: barrier (本 token 层 92 结束, host 据此回 ACK 放下一个 token)
// credit: wr_ready = cnt <= THRESH —— 阈值 50%, 主机常闲预期不触发(sim 已验)。
// 读侧 host 顺巡 DDR 区; 本模块单时钟, 双时钟(M.2/PCIe)在真实 SDMA 里加。
//────────────────────────────────────────────────────────────────────────────

module wb_channel #(
    parameter DW     = 32,
    parameter DEPTH  = 4096,   // 字深; 实机 128KB = 32768
    parameter THRESH = 2048    // 阈值(字); 实机 DEPTH/2
)(
    input  wire         clk,
    input  wire         rst_n,

    input  wire         wr_valid,
    input  wire [DW-1:0] wr_data,
    input  wire [1:0]   wr_tag,      // 0=data 1=header 2=barrier
    output wire         wr_ready,    // credit: cnt <= THRESH

    output wire         rd_valid,
    output wire [DW-1:0] rd_data,
    output wire [1:0]   rd_tag,
    input  wire         rd_ready,    // host 背压

    output wire         full,
    output wire [31:0]  occupancy,
    output reg          ord_err        // 协议守卫: 同 token 内层号须严格递增
);

    function integer clog2(input integer n);
        integer k;
        begin
            k = 0;
            while ((1 << k) < n) k = k + 1;
            clog2 = k;
        end
    endfunction

    localparam W   = DW + 2;                 // {tag, data}
    localparam IDX = clog2(DEPTH);

    reg [W-1:0]  mem    [0:DEPTH-1];
    reg [IDX-1:0] head, tail;
    reg [IDX:0]  cnt;
    reg [7:0]    last_layer;
    reg          tok_active;

    assign full      = (cnt == DEPTH[IDX:0]);
    assign wr_ready  = (cnt <= THRESH[IDX:0]);
    assign rd_valid  = (cnt != 0);
    assign rd_tag    = mem[head][W-1:DW];
    assign rd_data   = mem[head][DW-1:0];
    assign occupancy = {32'h0} | {1'b0, cnt};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            head <= {IDX{1'b0}};
            tail <= {IDX{1'b0}};
            cnt  <= 0;
        end else begin
            if (wr_valid && wr_ready) begin
                mem[tail] <= {wr_tag, wr_data};
                tail <= tail + 1'b1;
                cnt  <= cnt + 1'b1;
                case (wr_tag)
                    2'd1: begin                                   // header
                        if (tok_active && wr_data[31:24] <= last_layer)
                            ord_err <= 1'b1;
                        last_layer <= wr_data[31:24];
                        tok_active <= 1'b1;
                    end
                    2'd2: begin                                   // barrier: 本轮完结
                        tok_active   <= 1'b0;
                        last_layer   <= 8'h00;
                    end
                    default: ;
                endcase
            end
            if (rd_valid && rd_ready) begin
                head <= head + 1'b1;
                cnt  <= cnt - 1'b1;
            end
        end
    end

endmodule
`default_nettype wire