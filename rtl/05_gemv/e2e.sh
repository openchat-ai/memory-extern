#!/data/data/com.termux/files/usr/bin/bash
# e2e.sh — 端到端全链：04 dequant → sim_cim 模拟阵列 → 05 RTL 数字外围 → CPU 对拍
# 真实 checkpoint 权重（fixture_mxfp4.bin）走完整设备路径，RTL 真正吐出 GEMV 结果。
#   [1] 04 去量化（C）逐位 vs fixture expected —— 链条根
#   [2] DAC→模拟阵列→ADC 生成 q[r][g]（真实权重 × 真实尺度激活）
#   [3] RTL periph_mac 逐行累加，逐位 vs 设备 golden（pim_mxfp4_periph_acc）
#   [4] RTL 输出 vs CPU double 参考（pim_mxfp4_gemv）按容限对拍
set -e
cd "$(dirname "$0")"

[ -x gen_e2e ] || cc -O2 -I../../pim -o gen_e2e gen_e2e.c ../../pim/mxfp4_gemv.c -ffp-contract=off -lm
[ -x e2e_cmp ] || cc -O2 -o e2e_cmp e2e_cmp.c -lm

echo "== [1/4] 04 dequant 链条根（真实权重字节 → fp32）=="
./gen_e2e ../../pim/fixture_mxfp4.bin

echo
echo "== [2/4] sim_cim 设备路径（q/scale 已生成: q.hex scale.hex）=="
echo "  DAC 8bit → 模拟阵列组段累加（double，无逐元素舍入）→ ADC 12bit"

echo
echo "== [3/4] RTL 数字外围（periph_mac 真跑）=="
iverilog -g2012 -Wall -o tb_e2e periph_mac.v periph_scale.v f32_add.v periph_mac_tb.v
out=$(vvp tb_e2e)
printf '%s\n' "$out" | grep -E "用例|行,|ALL|ERROR|FAIL" || true
printf '%s' "$out" | grep -q "ALL PASS" || { echo "!! RTL 数字外围未逐位匹配设备 golden"; exit 1; }

echo
echo "== [4/4] 对拍: RTL 输出 vs CPU double 参考 =="
./e2e_cmp expected.hex expected_cpu.hex

echo
echo "== 端到端全链通过：真实权重 → 模拟阵列 → RTL 外围 == "真算"成功 =="