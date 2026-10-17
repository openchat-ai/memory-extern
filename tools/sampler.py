#!/data/data/com.termux/files/usr/bin/python3
"""sampler.py — 生成时的采样器(唯一实现, gen_bytes / gen_qxn 共用).

为什么单独抽出来: §41 修了 `lg/lg.max()` 的采样 bug, 但当时只改了字节级的
gen_bytes.py, token 级的 gen_qxn.py 没动 —— 与 §33.21(compress_vocab 的
off-by-one 只修了一份)和 §38.1(block_size 硬编码)是同一类错误:
**两份拷贝, 只修一份**。凡是会被两个脚本用到的逻辑, 只留一份.

关键点(§41.2): logit 可能全为负, 必须用 `lg - lg.max()` 平移.
**不能**用 `lg / lg.max()` —— 后者在 max<0 时翻转大小关系,
把最不可能的 token 变成概率 1.

环境变量:
  TEMP 温度, 0 = 贪心
  TOPK 保留 top-k 个候选, 0 = 不截断
  TOPP nucleus 阈值, 0 = 不截断
  REP  重复惩罚强度, 1.0 = 关闭
  SEED 随机种子
"""
import os

import numpy as np

TEMP = float(os.environ.get("TEMP", "0.0"))
TOPK = int(os.environ.get("TOPK", "0"))
TOPP = float(os.environ.get("TOPP", "0.0"))
REP = float(os.environ.get("REP", "1.0"))
SEED = int(os.environ.get("SEED", "0"))

ACTIVE = bool(TEMP or TOPK or TOPP or REP != 1.0)


def describe():
    return ("T=%.2f topk=%d topp=%.2f rep=%.2f seed=%d%s"
            % (TEMP, TOPK, TOPP, REP, SEED, "" if ACTIVE else "  (贪心)"))


def pick(lg, ctx, rng=None):
    """给定下一步的 logit 行, 返回选中的 token id."""
    if not ACTIVE:
        return int(lg.argmax())
    rng = rng or np.random.default_rng(SEED)
    z = np.asarray(lg, np.float64)
    if REP != 1.0 and ctx is not None and len(ctx):
        uniq, cnt = np.unique(np.asarray(ctx[-96:], np.int64), return_counts=True)
        z[uniq] = z[uniq] - REP * np.log1p(cnt)
    z = z - z.max()                       # 平移, 不是除法 —— 见模块 docstring
    if TEMP > 0:
        z = z / TEMP
    p = np.exp(z)
    s = p.sum()
    if not np.isfinite(s) or s <= 0:
        return int(lg.argmax())
    p /= s
    if 0 < TOPK < len(p):
        cut = np.argpartition(-p, TOPK)[:TOPK]
        m = np.zeros_like(p, bool)
        m[cut] = True
        p = np.where(m, p, 0.0)
    if 0 < TOPP < 1.0:
        o = np.argsort(-p)
        m = np.zeros_like(p, bool)
        m[o[np.cumsum(p[o]) - p[o] <= TOPP]] = True
        m[o[0]] = True
        p = np.where(m, p, 0.0)
    t = p.sum()
    return int(rng.choice(len(p), p=p / t)) if t > 0 else int(lg.argmax())
