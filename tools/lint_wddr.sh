#!/data/data/com.termux/files/usr/bin/bash
# Verilator lint for Wavious WDDR PHY top (ddr_phy) with Ibex MCU
# Usage: tools/lint_wddr.sh [extra verilator args]
set -e
cd "$(dirname "$0")/.."

FL=.filelist.txt

# --- Build file list: packages first, then stubs, then everything else ---
PKG="rtl/10_phy_final/wddr/ddr_global_pkg.sv
rtl/10_phy_final/ahb/wav_ahb_pkg.sv
rtl/10_phy_final/mcu_ibex/wav_mcu_pkg.sv
rtl/10_phy_final/ibex/ibex_pkg.sv"

STUBS="rtl/10_phy_final/wphy_stubs/wphy_all_stubs.v
rtl/10_phy_final/wphy_stubs/wav_jtag_lib.sv"

# Note: wddr/ddr_custom_lib.sv excluded (duplicate of tech/, GPL header)
# Note: wddr/ddr_phy.sv excluded (passed as top-level arg below)
SRCS=$(find rtl/10_phy_final/wddr rtl/10_phy_final/ahb rtl/10_phy_final/mcu_ibex \
         rtl/10_phy_final/component rtl/10_phy_final/tech rtl/10_phy_final/ibex \
         -name "*.sv" ! -name "*pkg*" ! -path "*wddr/ddr_custom_lib.sv" ! -name "ddr_phy.sv" | sort)

{ echo "$PKG"; echo "$STUBS"; echo "$SRCS"; } > $FL

verilator --lint-only +1364-2005ext+v --top-module ddr_phy -f $FL \
  -Wno-ENUMVALUE \
  -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
  -Wno-LATCH -Wno-IMPLICIT \
  -Wno-CASEINCOMPLETE -Wno-ASCRANGE \
  -Wno-UNOPTFLAT -Wno-COMBDLY \
  -Wno-UNSIGNED \
  -Irtl/10_phy_final/wddr \
  -Irtl/10_phy_final/wphy_stubs \
  -Irtl/10_phy_final/ahb \
  -Irtl/10_phy_final/component \
  -Irtl/10_phy_final/ibex \
  -Irtl/10_phy_final/mcu_ibex \
  -Irtl/10_phy_final/tech \
  -Irtl/07_phy_wavious/rtl/ahb \
  -Irtl/07_phy_wavious/rtl/jtag \
  "$@" \
  rtl/10_phy_final/wddr/ddr_phy.sv
