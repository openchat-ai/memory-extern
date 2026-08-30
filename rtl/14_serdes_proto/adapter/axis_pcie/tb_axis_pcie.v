// ============================================================================
// tb_axis_pcie.v — 实例 B 集成自测: PCIe风格适配器 + proto_core 端到端
//
// 模拟 PCIe IP 发帧(header+payload), 经 axis_pcie_adapter 透传进 proto_core,
// 验证 core 正确解析 payload 拍(计 core 的 o_payload_tvalid)。
// ============================================================================

`timescale 1ns/1ps

module tb_axis_pcie;

    parameter DATAW = 128;
    parameter BEATS = 4;

    reg clk, rst_n;
    reg s_tvalid, s_tlast;
    reg [DATAW-1:0] s_tdata;
    reg [DATAW/8-1:0] s_tkeep;
    wire s_tready;

    // adapter <-> core 之间
    wire a_tvalid, a_tlast;
    wire [DATAW-1:0] a_tdata;
    wire [DATAW/8-1:0] a_tkeep;
    reg  a_tready;

    wire o_tvalid;
    wire o_tlast, o_done;
    wire [7:0] o_cmd, o_seq;
    wire link_up;

    integer err_cnt;
    integer send_state;

    initial begin clk = 0; forever #5 clk = ~clk; end

    axis_pcie_adapter #(.DATAW(DATAW)) u_ad (
        .clk(clk), .rst_n(rst_n),
        .pcie_tvalid(s_tvalid), .pcie_tready(s_tready),
        .pcie_tdata(s_tdata), .pcie_tkeep(s_tkeep), .pcie_tlast(s_tlast),
        .core_tvalid(a_tvalid), .core_tready(a_tready),
        .core_tdata(a_tdata), .core_tkeep(a_tkeep), .core_tlast(a_tlast),
        .link_up(link_up));

    proto_core #(.DATAW(DATAW), .SETTLE_CYCLES(2))
        u_core (.clk(clk), .rst_n(rst_n),
                .s_axis_tvalid(a_tvalid), .s_axis_tready(a_tready),
                .s_axis_tdata(a_tdata), .s_axis_tkeep(a_tkeep), .s_axis_tlast(a_tlast),
                .o_payload_tvalid(o_tvalid), .o_payload_tready(1'b1),
                .o_payload_tdata(), .o_payload_tkeep(), .o_payload_tlast(),
                .o_cmd(o_cmd), .o_seq(o_seq),
                .o_frame_in_progress(), .o_frame_done(o_done));

    // ---- PCIe 风格 producer: 发一帧 ----
    always @(posedge clk) begin
        if (!rst_n) begin
            send_state <= 0;
            s_tvalid   <= 1'b0;
            s_tlast    <= 1'b0;
            s_tdata    <= 0;
            s_tkeep    <= 0;
        end else begin
            s_tvalid <= 1'b0;
            case (send_state)
                0: begin
                    if (s_tready) begin
                        s_tvalid <= 1'b1;
                        s_tdata  <= {8'h00, 8'd64, 8'h4B, 8'h02}; // cmd=0x02 seq=0x4B len=64
                        s_tkeep  <= {DATAW/8{1'b1}};
                        s_tlast  <= 1'b0;
                        send_state <= 1;
                    end
                end
                default: begin
                    if (s_tready) begin
                        if (send_state <= BEATS) begin
                            s_tvalid <= 1'b1;
                            s_tdata  <= send_state * (32'h0A0A0A0A);
                            s_tkeep  <= {DATAW/8{1'b1}};
                            s_tlast  <= (send_state == BEATS);
                        end
                        send_state <= send_state + 1;
                    end
                end
            endcase
        end
    end

    reg [15:0] got_beats;
    always @(posedge clk)
        if (o_tvalid) got_beats <= got_beats + 1;

    initial begin
        clk = 0; rst_n = 0;
        got_beats = 0; err_cnt = 0;
        #20 rst_n = 1;
        wait (link_up === 1'b1);
        wait (got_beats == BEATS || send_state > BEATS+4);
        #20;
        if (o_cmd !== 8'h02 || o_seq !== 8'h4B) begin
            $display("FAIL: cmd/seq decode via PCIe adapter"); err_cnt = err_cnt + 1;
        end
        if (got_beats !== BEATS) begin
            $display("FAIL: expected %0d beats, got %0d", BEATS, got_beats); err_cnt = err_cnt + 1;
        end else
            $display("OK: %0d beats delivered through PCIe adapter", got_beats);
        if (err_cnt == 0) $display("PASS: axis_pcie adapter + proto_core end-to-end");
        else              $display("FAIL: %0d errors", err_cnt);
        $finish;
    end

endmodule
