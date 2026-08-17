#!/data/data/com.termux/files/usr/bin/bash
# check.sh — 05_gemv 全套回归（含 fixture 完整性自愈 + 可综合性检查）
# ① C 语料 20022  ② fixture 64 行  ③ edge 48 行  ④ 独立 Python ~1M  ⑤ yosys synth
set -e
cd "$(dirname "$0")"

# ---------- 行数自检/重建：真实 fixture 被误写（如赋给 q.hex 的生成器）自动重建 ----------
lines() { wc -l < "$1" 2>/dev/null || true; }
ensure() {                            # <file> <expect> <regen_cmd...>
    local f=$1 e=$2 n; shift 2
    n=$(lines "$f")
    if [ -z "$n" ] || [ "$n" != "$e" ]; then
        echo "!! $f 行数异常(应为 $e，实为 ${n:-缺失}) → 重建"
        "$@" >/dev/null || { echo "!! $f 重建失败"; exit 1; }
        n=$(lines "$f")
    fi
    [ "$n" = "$e" ] || { echo "!! $f 重建后仍不对"; exit 1; }
}

# ---------- 仿真务必跑出 ALL PASS，否则打印全文并失败 ----------
check_tb() {                          # <label> <vvp_target>
    local label=$1 tgt=$2 out
    out=$(vvp "$tgt")
    echo "$out" | grep -E "用例|行,|ALL|ERROR|FAIL" || true
    if ! printf '%s' "$out" | grep -q "ALL PASS"; then
        echo "!! [$label] 失败（未出现 ALL PASS）"
        printf '%s\n' "$out"
        exit 1
    fi
}

FIXTURE=../../pim/fixture_mxfp4.bin
[ -x gen_fixture ]   || cc -O2 -o gen_fixture gen_fixture.c
[ -x gen_add_cases ] || cc -O2 -o gen_add_cases gen_add_cases.c
[ -x gen_mac_edge ]  || cc -O2 -ffp-contract=off -o gen_mac_edge gen_mac_edge.c ../../pim/mxfp4_gemv.c -lm

ensure q.hex 7168        ./gen_fixture "$FIXTURE"
ensure scale.hex 7168    ./gen_fixture "$FIXTURE"
ensure expected.hex 64   ./gen_fixture "$FIXTURE"
ensure add_pairs_a.hex 20022 ./gen_add_cases
ensure add_pairs_b.hex 20022 ./gen_add_cases
ensure add_expected.hex 20022 ./gen_add_cases

echo "== [0/7] dequant vs C 参考含边界 (16384) =="
[ -x gen_dequant_tb ] || cc -O2 -I../../pim -o gen_dequant_tb gen_dequant_tb.c ../../pim/mxfp4_gemv.c -ffp-contract=off -lm
./gen_dequant_tb
iverilog -g2012 -Wall -o tb_dq dequant.v dequant_tb.v
check_tb "dequant" tb_dq

echo "== [1/7] f32_add vs C 语料 (20022) =="
iverilog -g2012 -Wall -o tb_add f32_add.v f32_add_tb.v
check_tb "C 语料" tb_add

echo "== [2/7] periph_mac vs fixture (64 行) =="
iverilog -g2012 -Wall -o tb_mac periph_mac.v periph_scale.v f32_add.v periph_mac_tb.v
check_tb "fixture" tb_mac

# edge 生成只写 edge_*；万一将来某版又写 q.hex，下面 ensure 立刻重建+报错
echo "== [3/7] periph_mac edge (48 行) =="
./gen_mac_edge >/dev/null
ensure q.hex 7168      ./gen_fixture "$FIXTURE"
ensure expected.hex 64 ./gen_fixture "$FIXTURE"
iverilog -g2012 -Wall -o tb_mac_edge periph_mac.v periph_scale.v f32_add.v periph_mac_edge_tb.v
check_tb "edge" tb_mac_edge

echo "== [4/7] f32_add vs 独立 Python 参考 ~1M =="
x=$(python3 indep_add.py --check-c)
printf '%s\n' "$x"
printf '%s' "$x" | grep -q "不一致 0 处" || { echo "!! C 交叉核对失败"; exit 1; }
python3 indep_add.py
iverilog -g2012 -Wall -o tb_py f32_add.v py_run.v
check_tb "独立参考" tb_py

echo "== [5/7] 可综合性检查 (yosys synth) =="
yosys -q -p "read_verilog -sv f32_add.v periph_scale.v periph_mac.v; synth -top periph_mac; write_verilog -noattr synth_05.v"
[ "$(grep -c 'module' synth_05.v)" -ge 1 ] || { echo "!! synth 无输出模块"; exit 1; }
echo "synth OK ($(grep -c 'module' synth_05.v) 模块)"
rm -f synth_05.v

echo "== [6/7] 06_sched 三级调度器 K3 trace 重放 =="
( cd ../06_sched
  iverilog -g2012 -Wall -o tb_sched sched3.v selfsched_tb.v
  check_tb "06_sched" tb_sched
  rm -f tb_sched )

echo "== 全部通过 =="