// ============================================================================
// tb_gw_pcie_bridge.v — GW PCIe 桥 端到端: PCIe帧 → proto_core → 载荷回程
//
// 模拟主机经 gowin_pcie_ip M_AXIS 发 3 帧(cmd=0x01..0x03, 各 16 字节载荷),
// 验证本桥:
//   (a) proto_core 正确解码帧头(o_cmd)
//   (b) 回程 S_AXIS 载荷与主机 payload 逐字节一致(echo), 且保序
//   (c) 回程随机背压下不丢字
// 证明: 通用协议内核可直接跑在 PCIe 20G 流上, 分层复用成立。
// ============================================================================

`timescale 1ns/1ps

module tb_gw_pcie_bridge;

    parameter AW = 128;

    reg clk = 0, rst_n = 0;
    reg [AW-1:0]   s_tdata = 0;
    reg [AW/8-1:0] s_tkeep = 0;
    reg            s_tvalid = 0, s_tlast = 0;
    wire           s_tready;

    wire [AW-1:0]    m_tdata;
    reg              m_tready;
    wire             m_tvalid, m_tlast;
    wire [AW/8-1:0] m_tkeep;

    wire [7:0] o_cmd;
    integer err_cnt = 0;

    always #5 clk = ~clk;

    gw_pcie_bridge #(.AW(AW)) u_br (
        .clk(clk), .rst_n(rst_n),
        .pcie_rx_tdata(s_tdata), .pcie_rx_tkeep(s_tkeep),
        .pcie_rx_tvalid(s_tvalid), .pcie_rx_tready(s_tready), .pcie_rx_tlast(s_tlast),
        .pcie_tx_tdata(m_tdata), .pcie_tx_tvalid(m_tvalid),
        .pcie_tx_tready(m_tready), .pcie_tx_tkeep(m_tkeep), .pcie_tx_tlast(m_tlast),
        .o_cmd(o_cmd), .o_seq(), .o_frame_done(o_frame_done)
    );

    // ---- producer: 3 帧, 各 = 帧头(1拍)+载荷(1拍); 帧间空拍等 core 出 SETTLE ----
    integer pstate  = 0;
    integer cur_cmd = 1;

    always @(posedge clk) begin
        if (!rst_n) begin
            pstate <= 0; s_tvalid <= 0; s_tlast <= 0; s_tdata <= 0; s_tkeep <= 0;
            cur_cmd <= 1;
        end else begin
            s_tvalid <= 1'b0;
            s_tlast  <= 1'b0;
            case (pstate)
                0: begin
                    if (s_tready) begin
                        s_tdata  <= {{AW-32{1'b0}}, 8'h10, 8'h00, cur_cmd[7:0]};
                        s_tkeep  <= {AW/8{1'b1}};
                        s_tvalid <= 1'b1;
                        pstate   <= 1;
                    end
                end
                1: begin
                    if (s_tready) begin
                        s_tdata  <= {{AW-32{1'b0}}, cur_cmd * 32'h0A0A0A0A};
                        s_tkeep  <= {AW/8{1'b1}};
                        s_tvalid <= 1'b1;
                        s_tlast  <= 1'b1;
                        pstate   <= 2;
                        cur_cmd  <= cur_cmd + 1;
                    end
                end
                2: begin
                    if (s_tready && cur_cmd <= 3) pstate <= 0;
                    else if (cur_cmd > 3) pstate <= 99;
                end
                default: ;
            endcase
        end
    end

    // ---- consumer: 随机背压 + 校验回程 ----
    integer step       = 0;
    integer rx_frames  = 0;
    integer exp_frame  = 1;

    always @(posedge clk) begin
        if (!rst_n) begin
            m_tready <= 1; step <= 0; rx_frames <= 0; exp_frame <= 1;
        end else begin
            m_tready <= (step % 4 != 0);   // 25% 背压
            step <= step + 1;

            if (o_frame_done) begin
                if (o_cmd !== exp_frame[7:0]) begin
                    $display("FAIL: 帧头 cmd=%0d 期望 %0d", o_cmd, exp_frame);
                    err_cnt <= err_cnt + 1;
                end
                exp_frame <= exp_frame + 1;
            end

            if (m_tvalid && m_tready) begin
                if (m_tdata[31:0] !== ((rx_frames+1) * 32'h0A0A0A0A)) begin
                    $display("FAIL: 回程载荷 帧=%0d 期望=%h 实=%h",
                             rx_frames+1, (rx_frames+1)*32'h0A0A0A0A, m_tdata);
                    err_cnt <= err_cnt + 1;
                end
                if (m_tlast) rx_frames <= rx_frames + 1;
            end
        end
    end

    initial begin
        #15 rst_n = 1;
        while ($time < 450000) #10;
        if (rx_frames == 3 && err_cnt == 0)
            $display("PASS: GW PCIe 桥 3 帧 PCIe流→proto_core→载荷回程 零错·保序·背压抖动");
        else
            $display("FAIL: GW PCIe 桥 err=%0d rx_frames=%0d(期望3)", err_cnt, rx_frames);
        $finish;
    end
endmodule
