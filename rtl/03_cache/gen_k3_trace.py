#!/usr/bin/env python3
"""
gen_k3_trace.py — 按白皮书 §5.7 结构生成 kimi-k3 风格路由 trace。

真实结构（来自 kimi-k3-in-c `--dump-cache-trace`，白皮书 §5.7）：
- 92 路由层 × 896 专家/层（专家为每层独立权重）
- 10 万请求覆盖 68 批次的 736 个 layer-run
- 批结构：每个 run = (super-iter, layer) 组，5~12 个批 token 共享该层专家
- 批内复用：88.3% 请求为 intra-run 重复；跨 run 净复用仅 ~1.7%
- 批复用因子 86.7 不同专家 / 136 请求 = 1.57x  →  命中率上限 = 1 - 1/1.57 = 36.3%

输出格式（每行一条访问）：
    EXPERT_ID  R/W   (十进制)
                     EXPERT_ID ∈ [0, 92*896)，独立权重（每层 id 独立）
                     R=读专家权重的访问
                     W=写（在本模型里专家访问都是读，保留 W 字段给未来 trace 复用）
每行实际写：  `<expert_id>\n`  （纯十进制，行数 = 请求数）

用法：
    python3 gen_k3_trace.py [runs] [out] [--seed S]
默认：736 runs，输出到 stdout 的 trace.txt（每 run 里先铺该层工作集，随后按
"批 token 命中该层专家子集"重复访问，复用因子 ≈ 1.57，与真机一致）。
"""
import os
import random
import sys

def main():
    runs = 736
    out = "k3_trace.txt"
    seed = 42
    if len(sys.argv) > 1:
        runs = int(sys.argv[1])
    if len(sys.argv) > 2:
        out = sys.argv[2]
    if "--seed" in sys.argv:
        seed = int(sys.argv[sys.argv.index("--seed") + 1])

    rng = random.Random(seed)

    NLAY = 92          # 路由层
    NEXP = 896         # 专家/层
    MAXID = NLAY * NEXP   # 全局 id 空间（每层独立权重，等价独立 id）

    # 白皮书统计：每 run 平均 86.7 个不同专家 / 136 请求 = 1.57x
    # 取离散化：每 run 工作集 W ∈ [80, 95]，请求数 R = round(W * 1.57)
    # 访问序列 = 先铺 W 个不同专家，再在 W 内重复 R-W 次（intra-run 复用），
    #           重复时权重偏向"最近铺的"（模拟批 token 共享层专家的时间局部性）
    lines = []
    runs_meta = []   # (start_idx, length) 供周期保留策略重放
    for _ in range(runs):
        lay = rng.randrange(NLAY)
        base = lay * NEXP
        # 每 run 工作集：从该层 896 个专家中随机抽 W 个（批 token 会用到的层专家）
        W = rng.randint(80, 95)
        ws = rng.sample(range(NEXP), W)          # 该层内专家 id
        R = round(W * 1.57)
        start = len(lines)
        # 前 W 个：铺工作集（首访）
        for e in ws:
            lines.append(base + e)
        # 后 R-W 个：批内复用——44.4% 概率选中"近铺的 8 个"（token 局部性）
        for _ in range(R - W):
            if rng.random() < 0.44 and len(ws) >= 8:
                e = rng.choice(ws[-8:])
            else:
                e = rng.choice(ws)
            lines.append(base + e)
        runs_meta.append((start, R))

    with open(out, "w") as f:
        for lid in lines:
            f.write(f"{lid}\n")

    # run 边界文件：每行 `start length`（行号从 0 起）——周期保留策略的输入
    meta_out = os.path.splitext(out)[0] + "_runs.txt"
    with open(meta_out, "w") as f:
        for s, L in runs_meta:
            f.write(f"{s} {L}\n")

    # 统计回报（与白皮书口径一致）
    n = len(lines)
    uniq = len(set(lines))
    print(f"runs={runs}  requests={n}  unique={uniq}  reuse={n/uniq:.2f}x  "
          f"hit_upper={100*(1-uniq/n):.2f}%", file=sys.stderr)
    print(f"wrote {out}", file=sys.stderr)

if __name__ == "__main__":
    main()