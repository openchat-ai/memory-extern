// SIPO (Serial-In Parallel-Out) — RX 通路核心
// 功能：将串行数据转换为并行数据
// 应用：LPDDR5X RX，每周期采样 1 bit

module sipo #(
    parameter WIDTH = 8         // 并行输出宽度
)(
    input  wire             clk,
    input  wire             rst_n,
    input  wire             din,        // 串行输入
    input  wire             bit_clk,    // 比特时钟（恢复的时钟）
    output reg [WIDTH-1:0]  dout,       // 并行输出
    output reg              valid       // 输出有效
);

    reg [WIDTH-1:0] shift_reg;
    reg [$clog2(WIDTH)-1:0] cnt;

    // 移位寄存器
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            shift_reg <= 0;
            cnt <= 0;
            valid <= 1'b0;
        end else if (bit_clk) begin
            if (WIDTH > 1) begin
                shift_reg <= {shift_reg[WIDTH-2:0], din};
            end else begin
                shift_reg <= din;
            end
            cnt <= cnt + 1;
            if (cnt == WIDTH - 1) begin
                if (WIDTH > 1) begin
                    dout <= {shift_reg[WIDTH-2:0], din};
                end else begin
                    dout <= din;
                end
                valid <= 1'b1;
                cnt <= 0;
            end else begin
                valid <= 1'b0;
            end
        end
    end

endmodule
