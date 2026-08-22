#!/data/data/com.termux/files/usr/bin/bash
# Build + run Wavious WDDR PHY smoke sim (Verilator binary, MCU boot test)
# Usage: tools/sim_wddr.sh [--trace]
set -e
cd "$(dirname "$0")/.."

TRACE=""; BUILD_ONLY=0
for a in "$@"; do
  [ "$a" = "--trace" ] && TRACE="--trace"
  [ "$a" = "--build-only" ] && BUILD_ONLY=1
done

# filelist must include ddr_phy.sv for simulation (lint passes it as top arg)
PKG="rtl/10_phy_final/wddr/ddr_global_pkg.sv
rtl/10_phy_final/ahb/wav_ahb_pkg.sv
rtl/10_phy_final/mcu_ibex/wav_mcu_pkg.sv
rtl/10_phy_final/ibex/ibex_pkg.sv"
STUBS="rtl/10_phy_final/wphy_stubs/wphy_all_stubs.v
rtl/10_phy_final/wphy_stubs/wav_jtag_lib.sv"
SRCS=$(find rtl/10_phy_final/wddr rtl/10_phy_final/ahb rtl/10_phy_final/mcu_ibex \
         rtl/10_phy_final/component rtl/10_phy_final/tech rtl/10_phy_final/ibex \
         -name "*.sv" ! -name "*pkg*" ! -path "*wddr/ddr_custom_lib.sv" | sort)

FL=.filelist_sim.txt
{ echo "$PKG"; echo "$STUBS"; echo "$SRCS"; } > $FL

verilator_bin --binary --timing -j 4 $TRACE \
  --top-module wddr_smoke_tb \
  -f $FL \
  rtl/10_phy_final/wddr/ddr_phy.sv \
  rtl/10_phy_final/tb/wddr_smoke_tb.sv \
  -o sim_wddr_smoke -Mdir obj_dir_smoke \
  -Wno-ENUMVALUE -Wno-fatal \
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
  -Irtl/07_phy_wavious/rtl/jtag

[ $BUILD_ONLY = 1 ] && exit 0
./obj_dir_smoke/sim_wddr_smoke +RAMDIR=rtl/10_phy_final/sw/tests/wddr_boot/ramfiles
