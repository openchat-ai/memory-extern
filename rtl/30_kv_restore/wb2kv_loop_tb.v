`timescale 1ps/1ps
//────────────────────────────────────────────────────────────────────────────
// wb2kv_loop_tb.v — M14×M15 loopback: wb_unified(写) → kv_restore(读) 字节闭环
//
// 验证目标: 93 层混排写者吐出的 v2 KV 帧字节流, 读回件原封吸入、头/序/值一致
// 结构: wb_unified f_b → kv_restore s_kv; 仅 v2 帧 (is_v2(u.pl_lay)) 喂读回件;
//       credit 共享 (reader occ_q < 阈值); 排空熄火 → 双方齐挂 (stalls>0)
// 默认 FAST(D=8, 约 225KB/token, ~2M 周期); -DFULL 真尺寸(3.4MB/token)
//────────────────────────────────────────────────────────────────────────────
module wb2kv_loop_tb;
    `ifdef FULL
    localparam NL = 93, NL2 = 24, HEADS = 96, D = 128;
    `else
    localparam NL = 93, NL2 = 24, HEADS = 96, D = 8;
    `endif
    localparam LATENT = 512, ROPE = 64;
    localparam DIFF_B = HEADS * (D + D) * 2;
    localparam V2_FB  = 8 + LATENT + ROPE/2;
    localparam FIFO_CAP = 4096, TCUT = FIFO_CAP/2;

    reg clk = 0, rst_n = 0; always #5 clk = ~clk;
    reg [7:0] s_lay, s_lat, s_rope; reg [15:0] s_elem;
    reg go, drain_en;
    wire credit;
    wire [7:0] f_b, round_w, round_r;
    wire f_valid, f_we, busy_w, busy_r, token_done_w, token_done_r, order_bad, head_bad;
    wire [31:0] bw, fw, stallsw, bcr, fcr, stallsr;

    //------------- 读回件帧源: 仅 v2 帧喂给 (push_pl_lay 对齐 NBA 延迟) -------------
    // 写者每次 push 时 (f_valid<=1) 同拍锁存 pl_lay → push_pl_lay,
    // 与 f_b 同拍 NBA 出, 消除 pl_lay 提前跳层导致的 v2 误判.
    wire writer_push = (u.ws==0 && u.pend && credit) ||
                       (u.ws==1 && (v2(u.pl_lay) || diff_valid)) ||
                       (u.ws==2);
    reg [7:0] push_pl_lay;
    always @(posedge clk) if (writer_push) push_pl_lay <= u.pl_lay;

    wire kv_valid = f_valid && f_we && v2(push_pl_lay);
    wire [7:0] s_kv = f_b;

    wb_unified #(.NL(NL), .NL2(NL2), .LATENT(LATENT), .ROPE(ROPE),
                 .HEADS(HEADS), .D(D)) u (
        .clk(clk), .rst_n(rst_n), .go(go), .credit(credit), .busy(busy_w),
        .diff_valid(diff_valid), .s_elem(s_elem),
        .lat_valid(lat_valid), .s_lat(s_lat), .rope_valid(rope_valid), .s_rope(s_rope),
        .s_lay(s_lay),
        .f_valid(f_valid), .f_we(f_we), .f_b(f_b),
        .bytes_written(bw), .frames(fw), .stalls(stallsw),
        .order_bad(order_bad), .token_done(token_done_w), .round(round_w));

    kv_restore #(.NL(NL), .NL2(NL2), .LATENT(LATENT), .ROPE(ROPE)) v (
        .clk(clk), .rst_n(rst_n), .go(go), .credit(credit), .busy(busy_r),
        .kv_valid(kv_valid), .s_kv(s_kv),
        .token_done(token_done_r), .head_bad(head_bad), .round(round_r),
        .bytes_consumed(bcr), .frames(fcr), .stalls(stallsr));

    //------------- 值函数 (同 M14 tb) -------------
    function integer v2(input integer l); begin v2 = (l % 4 == 3) || (l == NL - 1); end endfunction
    function integer v2lay(input integer n); begin v2lay = (n == NL2 - 1) ? (NL - 1) : (4*n+3); end endfunction
    function integer fszb(input integer l); begin fszb = v2(l) ? V2_FB : 8+DIFF_B; end endfunction
    function [7:0] lat_src(input integer r, lay, k);
        begin lat_src = ((lay*131 + k*7 + r*5 + 5) % 255) + 1; end
    endfunction
    function [7:0] rope_src(input integer r, lay, k);
        begin rope_src = ((lay*37 + k*3 + r*7 + 13) % 255) + 1; end
    endfunction
    function [7:0] qlat8(input [7:0] v, input [15:0] s);
        reg [23:0] t; begin t = $unsigned(v)*s; qlat8=(t+64)>>7; if(qlat8>127) qlat8=127; end
    endfunction
    function [3:0] qr4(input [7:0] v, input [15:0] s);
        reg [23:0] t; begin t=$unsigned(v)*s; qr4=(t+64)>>7; if(qr4>15) qr4=15; end
    endfunction
    function [15:0] elem_src(input integer r, lay, head, kv, i);
        reg [31:0] t; begin t=(r*131+lay*257+head*131+kv*37+i*11+17)%65536; elem_src=(t+1)&16'hFFFF; end
    endfunction
    function [15:0] lscale_g(input integer r);
        reg [7:0] mx; integer a,b; begin mx=0; for(a=0;a<NL2;a=a+1) for(b=0;b<LATENT;b=b+1)
            if(lat_src(r,v2lay(a),b)>mx) mx=lat_src(r,v2lay(a),b);
            lscale_g=(16'd16256)/{8'd0,mx}; end
    endfunction
    function [15:0] rscale_g(input integer r);
        reg [7:0] mx; integer a,b; begin mx=0; for(a=0;a<NL2;a=a+1) for(b=0;b<ROPE;b=b+1)
            if(rope_src(r,v2lay(a),b)>mx) mx=rope_src(r,v2lay(a),b);
            rscale_g=(16'd1920)/{8'd0,mx}; end
    endfunction

    //------------- 写者组合源 -------------
    localparam P0_LAT_T = NL2*LATENT, P0_ROPE_T = NL2*ROPE, ELEM_T = HEADS*(D+D);
    assign lat_valid  = (u.st==2'd1)?(u.p0_lat<P0_LAT_T)
                       :(u.st==2'd2)?(u.ws==2'd1&&v2(u.pl_lay)&&u.pl_kvlat<LATENT):0;
    assign rope_valid = (u.st==2'd1)?(u.p0_rope<P0_ROPE_T)
                       :(u.st==2'd2)?((u.ws==2'd2||u.ws==2'd3)&&v2(u.pl_lay)&&u.pl_kvrope<ROPE):0;
    assign diff_valid = (u.st==2'd2)&&!v2(u.pl_lay)&&(u.ws==2'd1)&&(u.pl_elem<ELEM_T);
    assign s_lat  = (u.st==2'd1)?lat_src(u.round,v2lay(u.p0_lat/LATENT),u.p0_lat%LATENT)
                                   :lat_src(u.round,u.pl_lay,u.pl_kvlat);
    assign s_rope = (u.st==2'd1)?rope_src(u.round,v2lay(u.p0_rope/ROPE),u.p0_rope%ROPE)
                                   :(u.ws==2'd3)?rope_src(u.round,u.pl_lay,u.pl_kvrope+1)
                                                :rope_src(u.round,u.pl_lay,u.pl_kvrope);
    assign s_elem = elem_src(u.round,u.pl_lay,(u.pl_elem/(D+D)),((u.pl_elem%(D+D))/D),(u.pl_elem%D));
    assign s_lay  = u.pl_lay[7:0];

    //------------- 写者黄金镜像 -------------
    integer curLG, curRG;
    integer w_err=0, w_idx=0, w_occ_max=0, w_crime=0;
    integer w_cl=0, w_co=0, w_cr=0;
    reg [15:0] w_occ=0;
    assign credit = (w_occ<TCUT);

    function [7:0] wexpb(input integer lay, off, r);
        integer e,ei,b,head,win,kv,i,rp; reg[31:0] len; reg[15:0] el; reg[7:0] o;
        begin o=0;
            if(off<8) begin len=v2(lay)?V2_FB-8:DIFF_B;
                case(off) 0:o=lay[7:0]; 1:o=v2(lay)?8'h01:8'h11; 2:o=0;3:o=0;
                           4:o=len[7:0];5:o=len[15:8];6:o=len[23:16];7:o=len[31:24]; endcase
            end else if(!v2(lay)) begin
                e=off-8;ei=e/2;b=e%2;head=ei/(D+D);win=ei%(D+D);kv=win/D;i=win%D;
                el=elem_src(r,lay,head,kv,i); o=b?el[15:8]:el[7:0];
            end else begin
                if(off-8<LATENT) o=qlat8(lat_src(r,lay,off-8),curLG);
                else begin rp=off-8-LATENT;
                    o={qr4(rope_src(r,lay,2*rp),curRG),qr4(rope_src(r,lay,2*rp+1),curRG)}; end
            end
            wexpb=o; end
    endfunction

    //------------- 读回件镜像 (仅 v2 帧) -------------
    integer r_err=0, r_idx=0, r_occ_max=0;
    integer r_cl=0, r_co=0, r_cr=0;
    reg [15:0] r_occ=0;

    function [7:0] rexpb(input integer lay_idx, off, r);
        integer rp, LL; reg[31:0] len; reg[7:0] o;
        begin LL=v2lay(lay_idx); o=0;
            if(off<8) begin len=V2_FB-8;
                case(off) 0:o=LL[7:0];1:o=8'h01;2:o=0;3:o=0;
                           4:o=len[7:0];5:o=len[15:8];6:o=0;7:o=0; endcase
            end else if(off-8<LATENT) o=qlat8(lat_src(r,LL,off-8),curLG);
            else begin rp=off-8-LATENT;
                o={qr4(rope_src(r,LL,2*rp),curRG),qr4(rope_src(r,LL,2*rp+1),curRG)}; end
            rexpb=o; end
    endfunction

    always @(posedge clk) begin
        if(rst_n) begin
            if(w_occ>w_occ_max) w_occ_max=w_occ;
            if(r_occ>r_occ_max) r_occ_max=r_occ;
            // 写者镜像
            if(f_valid&&f_we) begin
                if(wexpb(w_cl,w_co,w_cr)!==f_b) begin
                    w_err=w_err+1;
                    if(w_err<6) $display("%0t WFAIL lay=%0d off=%0d got=%0h exp=%0h",$time,
                        w_cl,w_co,f_b,wexpb(w_cl,w_co,w_cr)); end
                w_idx=w_idx+1; w_co=w_co+1;
                if(w_co==fszb(w_cl)) begin w_cl=w_cl+1; w_co=0; end
            end
            // 读回者镜像
            if(kv_valid&&credit) begin
                if(rexpb(r_cl,r_co,r_cr)!==s_kv) begin
                    r_err=r_err+1;
                    if(r_err<6) $display("%0t RFAIL idx=%0d v2L=%0d lay=%0d off=%0d got=%0h exp=%0h",$time,
                        r_idx,v2lay(r_cl),r_cl,r_co,s_kv,rexpb(r_cl,r_co,r_cr)); end
                r_idx=r_idx+1; r_co=r_co+1;
                if(r_co==V2_FB) begin r_cl=r_cl+1; r_co=0; end
            end
            // occ
            if(f_valid&&f_we&&credit)
                w_occ<=w_occ+1-(drain_en&&w_occ>0?1:0);
            else if(drain_en&&w_occ>0)
                w_occ<=w_occ-1;
            if(kv_valid&&credit)
                r_occ<=r_occ+1-(drain_en&&r_occ>0?1:0);
            else if(drain_en&&r_occ>0)
                r_occ<=r_occ-1;
        end else begin w_occ<=0; r_occ<=0; end
    end

    //------------- 主流程 -------------
    integer TOK_W, TOK_R, b0w, f0w, b0r, f0r, err=0;
    integer wdc=0;
    initial begin
        TOK_W=0; for(integer L=0;L<NL;L=L+1) TOK_W=TOK_W+fszb(L);
        TOK_R=NL2*V2_FB;
        repeat(3) @(posedge clk); #1; rst_n=1;

        // T0 全信用
        curLG=lscale_g(0); curRG=rscale_g(0);
        w_cr=0; r_cr=0; w_cl=0; w_co=0; r_cl=0; r_co=0;
        drain_en=1; w_idx=0; r_idx=0; w_err=0; r_err=0;
        @(posedge clk); go=1; @(posedge clk); go=0;
        while(!token_done_w) @(posedge clk); repeat(2) @(posedge clk);
        if(bw!=TOK_W) err=err+1;
        if(bcr!=TOK_R) err=err+1;
        if(w_err!=0) err=err+1;
        if(r_err!=0) err=err+1;
        if(fw!=NL) err=err+1;
        if(fcr!=NL2) err=err+1;
        $display("== T0 W byte=%0d hdr=%0d R byte=%0d hdr=%0d wstall=%0d rstall=%0d w_occ=%0d r_occ=%0d ==",
                 bw, fw, bcr, fcr, stallsw, stallsr, w_occ_max, r_occ_max);

        // T1 排空熄火
        curLG=lscale_g(1); curRG=rscale_g(1);
        w_cr=1; r_cr=1; w_cl=0; w_co=0; r_cl=0; r_co=0;
        drain_en=0; w_err=0; r_err=0;
        @(posedge clk); go=1; @(posedge clk); go=0;
        while(!token_done_w) begin @(posedge clk); if(stallsw>0) drain_en=1; end
        repeat(2) @(posedge clk);
        if(bw-TOK_W!=TOK_W) err=err+1;  // 总字节=2*TOK_W(两轮)
        if(bcr-TOK_R!=TOK_R) err=err+1;
        if(w_err!=0||r_err!=0) err=err+1;
        if(w_idx!=2*TOK_W) err=err+1;
        if(r_idx!=2*TOK_R) err=err+1;
        $display("== T1 W byte=%0d hdr=%0d R byte=%0d hdr=%0d wstall=%0d rstall=%0d w_occ=%0d r_occ=%0d ==",
                 bw-TOK_W, fw-NL, bcr-TOK_R, fcr-NL2, stallsw, stallsr, w_occ_max, r_occ_max);

        if(err==0 && !head_bad && !order_bad && stallsw>0)
            $display("##### ALL PASS: M14×M15 loopback wb_unified→kv_restore 93层混排 2token 字节闭环全绿 #####");
        else
            $display("##### FAIL err=%0d head=%0b order=%0b #####", err, head_bad, order_bad);
        $finish;
    end

    always @(posedge clk) begin
        if(busy_w) begin if(wdc>20000000) begin $display("%0t FAIL watchdog",$time); $finish; end wdc=wdc+1; end
        else wdc=0;
    end
endmodule