// board_smoke_top.v — 上板冒烟核 (Tang Mega 138K)
// 烧录判活: led[0] = 时钟分频眨眼 (逻辑活着); led[1] = 乘加自检校验通过
// (8 拍流水 16b×16b→32b 累加, LFSR 权重/激活, 黄金值由 board_smoke_self_tb 数值标定);
// led[3:2] = 运行计数 (在位证明 FF/加树/进位链运转)。无外部访存/IO 依赖。
module board_smoke_top (
    input  wire clk,
    input  wire rst_n,
    output wire [3:0] led,
    output wire [31:0] acc_o,      // 观测: 自检累加 (tb 标定黄金值)
    output wire        done_o      // 观测: 自检完成
);
    reg [23:0] div;
    reg [31:0] lfsr;
    reg [31:0] acc_r;
    reg [2:0]  cyc;
    reg [31:0] prod_r;
    reg        done;
    wire [15:0] w = lfsr[31:16];
    wire [15:0] a = lfsr[15:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div <= 0; lfsr <= 32'hCAFE_BEEF; acc_r <= 0; cyc <= 0; done <= 0;
        end else begin
            div <= div + 1'b1;
            lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
            if (!done) begin
                prod_r <= w * a;
                if (cyc > 0) acc_r <= acc_r + prod_r;
                if (cyc == 3'd7) done <= 1'b1;
                cyc <= cyc + 1'b1;
            end
        end
    end
    // 黄金值标定: 见 board_smoke_self_tb 输出 GOLD (此处由 ACCESS 无关宏用于板级校验)
    localparam GOLD = 32'he552b3e0;   // board_smoke_self_tb 标定 (LFSR初值 CAFE_BEEF, 8拍流水)
    assign led[0] = div[22];
    assign led[1] = done && (acc_r == GOLD);
    assign led[2] = lfsr[27];
    assign led[3] = lfsr[28];
    assign acc_o = acc_r;
    assign done_o = done;
endmodule