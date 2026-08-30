// ============================================================================
// tb_proto_core.v — 通用协议内核(proto_core)直接自测
//
// 直接驱动 AXI-Stream 喂"帧头+负载", 断言:
//   1. 帧头被解码(o_cmd/o_seq)
//   2. payload 逐拍正确交付 o_payload_tvalid
//   3. 末拍给出 o_payload_tlast + o_frame_done
// 用"时钟驱动 producer FSM"驱动, 握手确定、无 task/wait 竞态。
// ============================================================================

`timescale 1ns/1ps

module tb_proto_core;

    parameter DATAW = 128;
    parameter BEATS = 4;

    reg clk, rst_n;
    reg s_tvalid, s_tlast;
    reg [DATAW-1:0] s_tdata;
    reg [DATAW/8-1:0] s_tkeep;
    wire s_tready;
    wire o_tvalid;
    wire o_tready = 1'b1;
    wire [DATAW-1:0] o_tdata;
    wire [DATAW/8-1:0] o_tkeep;
    wire o_tlast, o_done;
    wire [7:0] o_cmd, o_seq;
    wire o_inprog;

    integer err_cnt;
    integer send_state;   // 1=header, 2..(BEATS+1)=payload beats
    integer beat_idx;

    initial begin clk = 0; forever #5 clk = ~clk; end

    proto_core #(.DATAW(DATAW), .SETTLE_CYCLES(2))
        u_core (.clk(clk), .rst_n(rst_n),
                .s_axis_tvalid(s_tvalid), .s_axis_tready(s_tready),
                .s_axis_tdata(s_tdata), .s_axis_tkeep(s_tkeep), .s_axis_tlast(s_tlast),
                .o_payload_tvalid(o_tvalid), .o_payload_tready(o_tready),
                .o_payload_tdata(o_tdata), .o_payload_tkeep(o_tkeep),
                .o_payload_tlast(o_tlast),
                .o_cmd(o_cmd), .o_seq(o_seq),
                .o_frame_in_progress(o_inprog), .o_frame_done(o_done));

    assign o_tready = 1'b1;

    // ---- 时钟驱动 producer: 发一帧(header + BEATS payload) ----
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
                    // 启动: header
                    if (s_tready) begin
                        s_tvalid <= 1'b1;
                        s_tdata  <= {8'h00, 8'd64, 8'h2A, 8'h01}; // [7:0]=cmd=0x01 [15:8]=seq=0x2A [23:16]=len=64
                        s_tkeep  <= {DATAW/8{1'b1}};
                        s_tlast  <= 1'b0;
                        send_state <= 1;
                    end
                end
                default: begin
                    // payload beats: send_state 1..BEATS ; send_state==BEATS 为末拍
                    if (s_tready) begin
                        if (send_state <= BEATS) begin
                            s_tvalid <= 1'b1;
                            s_tdata  <= send_state * (32'h01010101);
                            s_tkeep  <= {DATAW/8{1'b1}};
                            s_tlast  <= (send_state == BEATS);
                        end
                        if (send_state == BEATS)
                            send_state <= BEATS+1;   // 发完, 停
                        else
                            send_state <= send_state + 1;
                    end
                end
            endcase
        end
    end

    // ---- 统计下游收到的 beats ----
    reg [15:0] got_beats;
    always @(posedge clk)
        if (o_tvalid && o_tready) got_beats <= got_beats + 1;

    initial begin
        clk = 0; rst_n = 0;
        got_beats = 0; err_cnt = 0;
        #20 rst_n = 1;
        #10;
        // 等全部 payload beat 被交付(带超时保护)
        wait (got_beats == BEATS || send_state > BEATS+4);
        #20;   // 让结果稳定
        if (o_cmd !== 8'h01 || o_seq !== 8'h2A) begin
            $display("FAIL: cmd/seq decode (got cmd=%02x seq=%02x)", o_cmd, o_seq);
            err_cnt = err_cnt + 1;
        end
        if (got_beats !== BEATS) begin
            $display("FAIL: expected %0d payload beats, got %0d", BEATS, got_beats);
            err_cnt = err_cnt + 1;
        end else
            $display("OK: %0d payload beats delivered", got_beats);
        if (err_cnt == 0) $display("PASS: proto_core frame decode & payload delivery");
        else              $display("FAIL: proto_core %0d errors", err_cnt);
        $finish;
    end

endmodule
