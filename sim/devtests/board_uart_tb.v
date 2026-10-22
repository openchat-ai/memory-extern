`timescale 1ps/1ps
// board_uart_tb — board_decode_top 的 UART 通道验证 (2026-10-21)
// 覆盖三件事:
//   1) uart_tx 位时序正确 (起始位/8 数据位/停止位, LSB first)
//   2) 行输出格式: "F=%08x W=%08x H=%08x A=%08x L=%08x R=%08x C=%08x\n"
//   3) 命令通路: TB 发 1 字节 → 板子 xext 覆盖 + C 字段回显 + 手动触发一帧
// 仿真用高速档 BAUD=6250000 (DIV=8) → 一行只需 ~6K 拍, 不用跑 30 万拍
module board_uart_tb;
    localparam BAUD = 6250000;
    localparam DIV  = 8;               // 50000000/6250000
    localparam HALF = DIV/2;

    reg clk = 0, rst_n = 0;
    wire uart_tx;
    wire [5:0] led;
    reg  uart_rx = 1;                  // 空闲高
    integer cyc = 0;
    integer lines = 0;
    integer i;
    reg [8*80-1:0] line_buf;
    integer errors = 0;

    board_decode_top #(.BAUD(BAUD)) DUT (
        .sys_clk(clk), .rst_n(rst_n), .uart_rx(uart_rx), .uart_tx(uart_tx), .led(led)
    );

    always #5 clk = ~clk;             // 100MHz 仿真时钟 (与被测的 50MHz 逻辑无关, 只为跑得快)
    always @(posedge clk) cyc = cyc + 1;

    // 预清 slice LUT: 板级上它是空的 (上电全 0, 顶层 wr_en=0), 仿真里不预灌就是 X
    // → 帧哈希 hsh 整条 X → 串口行不可打印。对齐板级真实状态。
    integer zi;
    initial begin
        for (zi = 0; zi < 512; zi = zi + 1) DUT.U.u_ras.A.slice_mem[zi] = 32'h0000_0000;
    end

    // ---- TB 侧 UART 接收器 (采样中点) ----
    reg [2:0] rst;
    reg [7:0] rsh;
    reg [3:0] rcnt;
    reg [2:0] rbit;
    reg [8*12-1:0] tail;      // 行尾 12 字符 (左移进)
    integer nchars;

    initial begin
        rst = 0; rsh = 0; rcnt = 0; rbit = 0; tail = 0; nchars = 0;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            rst <= 0; rcnt <= 0; rbit <= 0;
        end else begin
            case (rst)
                3'd0: if (uart_tx == 1'b0) begin rst <= 1; rcnt <= 0; end
                3'd1: begin
                    rcnt <= rcnt + 1'b1;
                    if (rcnt == HALF-1) begin
                        rst <= 2; rcnt <= 0; rbit <= 0;
                    end
                end
                3'd2: begin
                    rcnt <= rcnt + 1'b1;
                    if (rcnt == DIV-1) begin
                        rcnt <= 0;
                        rsh <= {uart_tx, rsh[7:1]};   // LSB first: 右移, 新位进最高位
                        if (rbit == 3'd7) rst <= 3;
                        else rbit <= rbit + 1'b1;
                    end
                end
                3'd3: begin
                    rcnt <= rcnt + 1'b1;
                    if (rcnt == DIV-1) begin
                        rcnt <= 0; rst <= 0;
                        // 收到一个字节 (rsh 为 LSB-first 装配好的字节)
                        if (rsh == 8'h0A) begin
                            // 行尾检查用**不含换行**的 tail; 只查第 2 行 (带命令回显的那行)
                            if (lines == 1 && tail[79:0] !== "C=00000012") begin
                                $display("FAIL: 行尾 C 字段不对: %0s", tail);
                                errors = errors + 1;
                            end
                            $write("%02x ", rsh);
                            if (nrcv < 64) begin rcv[nrcv] = rsh; nrcv = nrcv + 1; end
                            lines = lines + 1;
                            nchars = 0;
                            $write("   <-- 行结束, 行尾12字符=%0s\n", tail);
                            lbuf = 0;
                        end else begin
                            $write("%c", rsh);
                            if (nrcv < 64) begin rcv[nrcv] = rsh; nrcv = nrcv + 1; end
                            tail = {tail[8*11-1:0], rsh};
                            lbuf = {lbuf[8*79-1:0], rsh};
                            nchars = nchars + 1;
                        end
                    end
                end
                default: rst <= 0;
            endcase
        end
    end

    // ---- 命令注入: 第 1 行之后发 0x12 (xext=2, bit4=1 手动触发) ----
    task send_byte(input [7:0] b);
        integer k;
        begin
            uart_rx = 0;                       // 起始位
            repeat (DIV) @(posedge clk);
            for (k = 0; k < 8; k = k + 1) begin
                uart_rx = b[k];                // LSB first
                repeat (DIV) @(posedge clk);
            end
            uart_rx = 1;                       // 停止位
            repeat (DIV) @(posedge clk);
        end
    endtask

    // 报告器内部状态跟踪 + 记录发出的字节 (供与收到的流并排比对)
    integer dbgw;
    reg [7:0] sent [0:63];
    integer nsent;
    initial begin dbgw = 0; nsent = 0; end
    always @(posedge clk) if (rst_n) begin
        if (DUT.uart_tx_wr && nsent < 64) begin
            sent[nsent] = DUT.uart_tx_byte;
            nsent = nsent + 1;
        end
        if (DUT.uart_tx_wr && dbgw < 12) begin
            $display("  TX#%0d byte=%02x rep_st=%0d fld=%0d chr=%0d val_sh=%08x",
                     dbgw, DUT.uart_tx_byte, DUT.rep_st, DUT.fld, DUT.chr, DUT.val_sh);
            dbgw = dbgw + 1;
        end
    end

    // 收到侧: 记下收到的字节 + 拼成行字符串
    reg [7:0] rcv [0:63];
    integer nrcv;
    reg [8*80-1:0] lbuf;
    initial begin nrcv = 0; lbuf = 0; end

    // token_done 时刻的实际值 (查字段锁存)
    integer ntd;
    initial ntd = 0;
    always @(posedge clk) if (rst_n && DUT.token_done && ntd < 6) begin
        $display("  TD#%0d cyc=%0d a_words=%0d hsh=%08x rep_f=%0d eng_layers=%0d eng_rail=%0d",
                 ntd, cyc, DUT.a_words, DUT.hsh, DUT.rep_f, DUT.eng_layers_done, DUT.eng_rail_frames);
        ntd = ntd + 1;
    end

    integer guard;
    initial begin
        repeat (10) @(posedge clk);
        rst_n = 1;
        // 等第一行出来 (仿真里行周期 = 71 字节 * 10 位 * 8 拍 ≈ 5680 拍)
        wait (lines >= 1);
        send_byte(8'h12);
        // 命令应体现在下一行的 C 字段 (=00000012) 且 xext 覆盖为 2
        wait (lines >= 2);
        repeat (200) @(posedge clk);
        $display("DUT: xext_reg=%0d  last_cmd=%02x  led=%b", DUT.xext_reg, DUT.last_cmd, led);
        $display("--- 发出 vs 收到 (前 40 字节) ---");
        for (i = 0; i < 40; i = i + 1) begin
            if (i < nsent) $write("S:%02x ", sent[i]);
            if (i < nrcv) $write("R:%02x ", rcv[i]);
            $write("\n");
        end
        for (i = 0; i < 40; i = i + 1) begin
            if (i < nsent && i < nrcv && sent[i] !== rcv[i]) begin
                $display("首个分歧在第 %0d 字节: 发出 %02x 收到 %02x", i, sent[i], rcv[i]);
                i = 99;
            end
        end
        if (DUT.xext_reg !== 4'd2) begin
            $display("FAIL: xext 未被命令覆盖 (=%0d)", DUT.xext_reg); errors = errors + 1;
        end
        if (DUT.last_cmd !== 8'h12) begin
            $display("FAIL: last_cmd 未回显 (=%02x)", DUT.last_cmd); errors = errors + 1;
        end
        if (errors == 0) $display("board_uart PASS (行格式 + 命令通路 OK)");
        else $display("board_uart FAIL errors=%0d", errors);
        $finish;
    end
endmodule
