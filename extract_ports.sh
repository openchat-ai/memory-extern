#!/bin/bash
# 提取每个 wphy_* 顶层模块的端口列表

WAVDIR="rtl/07_phy_wavious/rtl"

extract_top_ports() {
    local file="$1"
    local modname="$2"
    
    # 找到顶层 module 行，提取端口列表直到 );
    awk '
    /^module '"$modname"'[ \t(]/ || /^module '"$modname"'[ \t]*$/ {
        found=1
    }
    found {
        buf = buf $0 "\n"
        # 计算括号匹配
        for(i=1;i<=length($0);i++) {
            c = substr($0,i,1)
            if(c=="(") depth++
            if(c==")") depth--
        }
        if(depth<=0 && found) {
            print buf
            exit
        }
    }
    ' "$file"
}

for f in \
    "$WAVDIR/custom_ip/wphy_2to1_14g_rvt.sv" \
    "$WAVDIR/custom_ip/wphy_cgc_diff_lvt.sv" \
    "$WAVDIR/custom_ip/wphy_cgc_diff_rh_lvt.sv" \
    "$WAVDIR/custom_ip/wphy_cgc_diff_rh_svt.sv" \
    "$WAVDIR/custom_ip/wphy_cgc_diff_svt.sv" \
    "$WAVDIR/custom_ip/wphy_clk_div_2ph_4g_dlymatch_lvt.sv" \
    "$WAVDIR/custom_ip/wphy_clk_div_2ph_4g_dlymatch_svt.sv" \
    "$WAVDIR/custom_ip/wphy_clk_div_2ph_4g_lvt.sv" \
    "$WAVDIR/custom_ip/wphy_clk_div_2ph_4g_svt.sv" \
    "$WAVDIR/custom_ip/wphy_clk_div_4ph_10g_dlymatch_svt.sv" \
    "$WAVDIR/custom_ip/wphy_clk_div_4ph_10g_svt.sv" \
    "$WAVDIR/custom_ip/wphy_clkmux_3to1_diff.sv" \
    "$WAVDIR/custom_ip/wphy_clkmux_3to1_diff_slvt.sv" \
    "$WAVDIR/custom_ip/wphy_clkmux_diff.sv" \
    "$WAVDIR/custom_ip/wphy_gfcm_lvt.sv" \
    "$WAVDIR/custom_ip/wphy_gfcm_svt.sv" \
    "$WAVDIR/custom_ip/wphy_pi_4g.sv" \
    "$WAVDIR/custom_ip/wphy_pi_dly_match_4g.sv" \
    "$WAVDIR/custom_ip/wphy_prog_dly_se_4g.sv" \
    "$WAVDIR/custom_ip/wphy_prog_dly_se_4g_small.sv" \
    "$WAVDIR/custom_ip/wphy_sa_4g_2ph_pdly_no_esd.sv" \
    "$WAVDIR/ddr_ip/wphy_lp4x5_cke_drvr_w_lpbk.sv" \
    "$WAVDIR/ddr_ip/wphy_lp4x5_cmn.sv" \
    "$WAVDIR/ddr_ip/wphy_lp4x5_cmn_clks_svt.sv" \
    "$WAVDIR/ddr_ip/wphy_lp4x5_dq_drvr_w_lpbk.sv" \
    "$WAVDIR/ddr_ip/wphy_lp4x5_dqs_drvr_w_lpbk.sv" \
    "$WAVDIR/ddr_ip/wphy_lp4x5_dqs_rcvr_no_esd.sv" \
    "$WAVDIR/mvppll_ip/wphy_rpll_mvp_4g.sv"
do
    modname=$(basename "$f" .sv)
    echo "============================================"
    echo "FILE: $f"
    extract_top_ports "$f" "$modname"
    echo ""
done
