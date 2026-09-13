// board_decode_top.v — SF9: 整包板上顶层 (burn 输入件)
// sys_clk 50MHz 直连 (无 PLL), rst_n K16, led[3:0] M25/L20/R26/J14 (cst 复用 mega138k_engine)。
// 内容: decode_auto_core 全链 + led 心跳/lbd[1]=busy/[2]=done/led[3]=起动复位翻转。
// 数据面轻量 ROM 占位 (weights=0, q_vec=固定, acc/xext 固定) → 板上 smoke run 打可观测心跳;
// PC 侧填真数据面 (ROM/主机流表) 后给 P&R。
module board_decode_top (
    input  wire clk,
    input  wire rst_n,
    output wire [3:0] led
);
    reg [22:0] div;
    reg run = 0;
    reg [21:0] tick;
    wire busy, done, token_done, r_token_done;
    wire [15:0] out_data, out_score;
    wire [3:0] out_expert;
    wire [8:0] out_token;
    wire [31:0] r_round, h_round, r_stalls, a_stalls, a_words;

    decode_auto_core U(
        .clk(clk), .rst_n(rst_n), .run(run), .busy(busy), .done(done),
        .credit(1'b1), .s_valid(1'b0), .out_take(1'b1), .s_score(16'h0000),
        .q_vec_p(64'h0), .head_acc(16'h0000), .xext(4'h6),
        .wr_en(1'b0), .wr_addr(9'h0), .wr_data(16'h0),
        .out_valid(), .out_data(out_data), .out_expert(out_expert),
        .token_done(token_done), .r_token_done(r_token_done),
        .out_token(out_token), .out_score(out_score), .h_go(),
        .r_round(r_round), .h_round(h_round), .r_stalls(r_stalls), .a_stalls(a_stalls), .a_words(a_words)
    );

    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            div <= 0; tick <= 0; run <= 0;
        end else begin
            div <= div + 1'b1;
            tick <= tick + 1'b1;
            if (tick[18:0] == 19'd1000) run <= 1'b1;
            else if (tick[18:0] == 19'd1016) run <= 1'b0;
            
        end

    assign led[0] = div[22];         // 心跳 = 时钟/寄存器链判活
    assign led[1] = busy;            // 核运行
    assign led[2] = done;            // 轮完成
    assign led[3] = out_token[0];    // 词输出 LSB 观察
endmodule