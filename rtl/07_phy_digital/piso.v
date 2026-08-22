// PISO (Parallel-In Serial-Out) — TX 通路核心
// 功能：将并行数据转换为串行数据输出
// 应用：LPDDR5X TX，每周期移出 1 bit

module piso #(
    parameter WIDTH = 8,        // 并行数据宽度
    parameter DEPTH = 4         // 流水级数（预加重用）
)(
    input  wire             clk,
    input  wire             rst_n,
    input  wire             load,       // 加载并行数据
    input  wire [WIDTH-1:0] din,        // 并行输入
    output wire             dout,       // 串行输出
    output wire             ready       // 就绪信号
);

    reg [WIDTH-1:0] shift_reg;
    reg [$clog2(WIDTH)-1:0] cnt;
    reg running;

    // 状态控制
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            shift_reg <= 0;
            cnt <= 0;
            running <= 1'b0;
        end else if (load && !running) begin
            shift_reg <= din;
            cnt <= WIDTH - 1;
            running <= 1'b1;
        end else if (running) begin
            if (WIDTH > 1) begin
                shift_reg <= {shift_reg[WIDTH-2:0], 1'b0};
            end else begin
                shift_reg <= 1'b0;
            end
            cnt <= cnt - 1;
            if (cnt == 0) begin
                running <= 1'b0;
            end
        end
    end

    // 输出
    assign dout = shift_reg[WIDTH-1];
    assign ready = !running;

endmodule
