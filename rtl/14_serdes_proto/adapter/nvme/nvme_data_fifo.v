// ============================================================================
// nvme_data_fifo.v — 数据状态 FIFO(阶段 N2 数据搬运)
//
// 在 nvme_host 与上层(权重组/GEMV 消费端 或 缓存更新源)之间做数据搬运,
// 缓冲 nvme_host 的读数据(rd)或待写缓存块(wr), 并支持背压:
//   - 写口(wr_data/wr_valid/wr_ready): 生产者入队
//   - 读口(rd_data/rd_valid/rd_ready):   消费者出队
// 满时 wr_ready 拉低, 空时 rd_valid 拉低, 天然携带背压。
//
// 标准同步 FIFO: 指针满/空判定(FF 深度用 2N 比特指针), 逐拍有效。
// 参数 DFIFO = 深度(2 的幂), DATAW = 位宽。
// ============================================================================

`timescale 1ns/1ps

module nvme_data_fifo #(
    parameter DFIFO = 8,
    parameter DATAW = 32
)(
    input  wire clk, input wire rst_n,
    // 写口(生产者)
    input  wire [DATAW-1:0] wr_data, input wire wr_valid, output wr_ready,
    // 读口(消费者)
    output reg  [DATAW-1:0] rd_data, output reg rd_valid, input wire rd_ready
);

    localparam AW = $clog2(DFIFO);   // 地址位宽
    localparam PW = AW + 1;          // 指针位宽(含满位)

    reg [DATAW-1:0] mem [0:DFIFO-1];
    reg [PW-1:0]    wptr, rptr;
    wire [AW-1:0]   waddr = wptr[AW-1:0];
    wire [AW-1:0]   raddr = rptr[AW-1:0];
    wire            full  = (wptr[AW] != rptr[AW]) && (waddr == raddr);
    wire            empty = (wptr == rptr);

    assign wr_ready = ~full;

    always @(posedge clk) begin
        if (!rst_n) begin
            wptr <= 0; rptr <= 0;
            rd_data <= 0; rd_valid <= 0;
        end else begin
            rd_valid <= 0;
            // 读口: 非空且消费者就绪则出队(数据寄存器化到下一拍)
            if (~empty && rd_ready) begin
                rd_data  <= mem[raddr];
                rd_valid <= 1;
                rptr <= rptr + 1;
            end
            // 写口: 非满且生产者有效则入队
            if (~full && wr_valid) begin
                mem[waddr] <= wr_data;
                wptr <= wptr + 1;
            end
        end
    end

endmodule
