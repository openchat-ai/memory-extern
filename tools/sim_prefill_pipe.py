#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""prefill 层管道模拟器: A-tile 复用 × 双缓冲微流水 (2026-09-09)

验证 §5 三件事:
  1. DDR3 层读: 有 A-tile 复用 2.27GB→0.93GB(v1) —— DDR3 层时 < NVMe 层时 → NVMe 稳坐墙
                 无复用 则 DDR3 反成 2.4× 新墙 → 是否复用是"墙 vs 更慢"的分水岭
  2. SRAM 池合规: GEMM 段 A-tile 2×224KB, attn 段 S头窗 8头×32KB×2=512KB 先后错开,
                  + 转载FIFO 128 + scratch 96 = 736KB ≤ 765KB, 全程不超
  3. prefill 总墙: NVMe(切片+专家) vs DDR3(含激活流), 逐层比, 永不翻墙

纯结构级(无权重): 只数字节与时间, 不建模 MAC 实算(算力 14× 余量, 传输主导).
用法: python3 tools/sim_prefill_pipe.py [--no-reuse] [--sweep]
"""
import argparse
import math

NVME, DDR3 = 3.5e9, 5.3e9          # B/s: M.2 读(纸面) / 板上 DDR3(模型)
N_BATCH = 1024                      # 预填批量
HIDDEN = N_BATCH * 7168 * 2         # 14.0MiB 隐藏态(整批)
SLICE = {1: 632e6, 2: 419e6}        # v1/v2 层切片(MXFP8 字节)
EXPERTS = 281e6                     # 本层顶 top-16 专家实体 17.55MiB×16
S_LAYER = 3.0e6                     # 每 v1 层 KDA 状态(走 PCIe, 非 DDR3)
X_READ = HIDDEN                     # 激活读: 无复用 = ×96(扫 96 输出块);
X_REPEAT = 96                       # 12288 输出通道 / 128 块
ACT_RW = 2 * HIDDEN                 # 激活流写回 + 残差回读(≈28MiB, Y 与 residual)
V1 = {0,1,2,4,5,6,8,9,10,12,13,14,16,17,18,20,21,22,24,25,26,28,29,30,
      32,33,34,36,37,38,40,41,42,44,45,46,48,49,50,52,53,54,56,57,58,
      60,61,62,64,65,66,68,69,70,72,73,74,76,77,78,80,81,82,84,85,86,
      88,89,90}

# ---- SRAM 域预算(§5 定数) ----
A_TILE = 16 * 7168 * 2              # 16token A-tile = 224KiB
A_DB = 2 * A_TILE                   # GEMM 段双缓冲 448KiB
S_HEAD_WIN = 2 * 8 * 128 * 128 * 2  # attn 段 S头窗 8头×2 双缓冲 = 512KiB
FIFO, SCRATCH = 128, 96                 # KiB 转载 + scratch
POOL = max(A_DB, S_HEAD_WIN)            # 时分取大者
BSRAM = 765


def fmt(b):
    for u in ("B", "KiB", "MiB", "GiB"):
        if b < 1024 or u == "GiB":
            return f"{b:,.0f}{u}"
        b /= 1024


def per_layer(L, reuse):
    ty = 1 if L in V1 else 2
    xread = X_READ if reuse else X_READ * X_REPEAT
    ddr3 = SLICE[ty] + EXPERTS + xread + ACT_RW
    nvme = SLICE[ty] + EXPERTS
    s_pcie = S_LAYER if ty == 1 else 0.0
    return ty, nvme / NVME, ddr3 / DDR3, ddr3, nvme, s_pcie


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--no-reuse", action="store_true",
                    help="关闭 A-tile 复用(激活按 96 遍重读), 看 DDR3 反成墙")
    ap.add_argument("--sweep", action="store_true",
                    help="扫 batch 数: 何时激活流让 DDR3 追上 NVMe")
    a = ap.parse_args()
    reuse = not a.no_reuse
    total_kib = POOL / 1024 + FIFO + SCRATCH
    print(f"SRAM 审计: GEMM段 {A_DB//1024}KiB | attn段 {S_HEAD_WIN//1024}KiB | 池取大 {POOL//1024}KiB"
          f" +FIFO {FIFO}KiB +scratch {SCRATCH}KiB = {total_kib:.0f}KiB"
          f" ≤ B-SRAM {BSRAM}KiB"
          f"   -> {'PASS' if total_kib <= BSRAM else 'FAIL'}")
    print(f"阶段串行: GEMM({A_DB//1024}KiB) 与 attn({S_HEAD_WIN//1024}KiB) 先后错开, 不同时持池"
          f"   -> {'PASS' if A_DB + S_HEAD_WIN > BSRAM*1024 else 'HOLD'}  (若并行持池需"
          f" {(A_DB+S_HEAD_WIN)//1024}KiB > {BSRAM}KiB 装不下)\n")

    print(f"{'层型':<4}{'#层':<5}{'DDR3读':>9}{'层时 DDR3':>11}{'层时 NVMe':>11}{'墙判定':>12}")
    tv = [0.0, 0.0]; td = [0.0, 0.0]; tb = [0, 0]; tt = [0.0, 0.0]
    for L in range(93):
        ty, tn, td3, db, nb, sp = per_layer(L, reuse)
        tv[ty-1] += tn; td[ty-1] += td3; tb[ty-1] += 1; tt[ty-1] += nb + sp
        wall = "NVMe" if td3 <= tn else "DDR3!! 反成墙"
        if L in (0, 3, 92):
            print(f"  v{ty}  L{L:<3}{fmt(db):>9}{td3:>10.3f}s{tn:>10.3f}s{wall:>14}")
    tot_nvme = sum(tv); tot_ddr3 = sum(td)
    ok = tot_ddr3 <= tot_nvme
    print(f"\n全预填(93层): NVMe 墙 = {tot_nvme:.1f}s"
          f"  DDR3 = {tot_ddr3:.1f}s  -> "
          f"{'NVMe 稳坐唯一墙 PASS' if ok else 'DDR3 反成新墙 FAIL'}")
    print(f"  (无复用版: DDR3 = {(sum(per_layer(L, False)[3] for L in range(93))/DDR3):.1f}s"
          f" vs NVMe {tot_nvme:.1f}s —— 这就是反成墙的代价)")

    if a.sweep:
        print(f"\n--sweep batch: 激活流 14M×96/N_BATCH 摊薄后, DDR3 何时追平 NVMe?")
        for n in (1024, 4096, 16384, 65536):
            X = n * 7168 * 2
            xr = X if reuse else X * X_REPEAT
            act = xr + 2 * X
            dn = (632e6 + 281e6) / NVME
            dd = (632e6 + 281e6 + act) / DDR3
            print(f"    batch {n:>6}: DDR3 层时 {dd:.3f}s vs NVMe {dn:.3f}s -> "
                  f"{'追上成为墙' if dd > dn else 'NVMe 仍墙'}")


if __name__ == "__main__":
    main()