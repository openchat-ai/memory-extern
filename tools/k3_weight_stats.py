#!/usr/bin/env python3
"""K3 专家权重统计规律探查 —— 找"生成公式", 检验能否用规则/分布刻画全部数值。

方向(逐项验证, 不空谈):
  1. 指数分布: 是否遵循幂律/特定形状? 低熵的来源?
  2. 尾数分布: 是否均匀随机(=无结构可挖)?
  3. 权值直方图: 是否高斯/拉普拉斯? 能否用参数拟合?
  4. 奇异值谱: 是否符合随机矩阵理论(Marcenko-Pastur)或幂律?
  5. 系数相关性: 行列间是否相关(结构性冗余)?
"""
import struct
from collections import Counter
import numpy as np
def _skew(x):
    m = x.mean(); s = x.std()+1e-12
    return ((x-m)**3).mean()/s**3

def _kurt(x):
    m = x.mean(); s = x.std()+1e-12
    return ((x-m)**4).mean()/s**4

def load_full():
    with open("pim/fixture_mxfp4.bin", "rb") as f:
        hdr = struct.unpack("<iiiii", f.read(20))
        rows, pc, sc, width, group = hdr
        f.read(rows * pc); f.read(rows * sc)
        return np.frombuffer(f.read(rows * width * 4), dtype=np.float32).reshape(rows, width).copy()

def main():
    W = load_full()
    flat = W.flatten()
    n = flat.size
    print(f"=== K3 真实专家权重: {W.shape}, 元素={n:,} ===")
    print(f"非零密度: {(W!=0).mean()*100:.1f}%, 数值范围: [{flat.min():.4f}, {flat.max():.4f}]")

    # ---- 1. 权值整体分布----
    print("\n[1] 权值直方图(分布形状)")
    mu, std = flat.mean(), flat.std()
    sk = _skew(flat); ku = _kurt(flat)
    print(f"  mean={mu:.4f} std={std:.4f} skew={sk:.3f} kurt={ku:.3f} (高斯kurt=0,拉普拉斯kurt=3)")
    _mean, _std = flat.mean(), flat.std()

    # ---- 2. 指数分布 ----
    print("\n[2] 指数位分布(挑出符号位不干扰的绝对值)")
    absv = np.abs(flat[flat!=0])
    flat32 = W.flatten().view(np.int32)
    exp_all = (flat32 >> 23) & 0xFF
    cnt_exp = Counter(exp_all.tolist())
    print(f"  唯一指数值: {len(cnt_exp)} 种, 常用区间 [{min(cnt_exp)}, {max(cnt_exp)}]")
    top = cnt_exp.most_common(8)
    print(f"  最常见指数: {[(f'{e:>3}', round(c/n*100,1)) for e,c in top]}%")
    # 是否集中在少量值
    domin = sum(c for _,c in top)/n
    print(f"  前8种指数占比: {domin*100:.1f}%  (越高越可压缩)")

    # ---- 3. 尾数分布 ----
    print("\n[3] 尾数位分布(低位是否均匀随机=高熵)")
    mant = flat32 & 0x7FFFFF
    # 采样一部分测低12位均匀性
    prof = (mant & 0xFFF)   # low 12 bits manifest
    p, pcounts = np.unique(mant&0xFFF, return_counts=True)
    freqs = pcounts/pcounts.sum()
    h_lo = -np.sum(freqs*np.log2(freqs+1e-30))
    print(f"  低12位唯一值={len(p):,} 熵={h_lo:.2f} bits (均匀=12b)")

    # ---- 4. 奇异值谱 ----
    print("\n[4] 奇异值谱(随机矩阵 vs 幂律)")
    S = np.linalg.svd(W, compute_uv=False)
    print(f"  S(min,max)={S.min():.3f},{S.max():.3f} span={S.max()/S.min():.2f}")
    print(f"  平价度(max/min)={S.max()/S.min():.2f}  (≈1 满秩随机; >100 幂律低秩)")
    # 有限维 Marcenko-Pastur 参考: 对 M=64,N=3584, SNR=22.9 -> 相对离散小
    q = n_embd/n_ff
    print(f"  纵横比 N/M={n_ff/n_embd:.1f}, q=1/NM关系  → MP 谱临界 λ_max={1+ (n_ff/n_embd)**0.5:.2f} (归一化后)")
    # 谱能量累积(对数)
    e = np.cumsum(S**2)/(S**2).sum()
    print(f"  前50%能量需: {int(np.searchsorted(e,0.5))} 个奇异值")

    # ---- 5. 行列相关性(结构性冗余) ----
    print("\n[5] 行列相关性(结构性冗余)")
    colmean = W.std(axis=0); rowmean = W.std(axis=1)
    print(f"  列std范围: [{colmean.min():.3f}, {colmean.max():.3f}] (差异大=列非均匀)")
    print(f"  行std范围: [{rowmean.min():.3f}, {rowmean.max():.3f}]")
    # 行内/列内连续元素相关(结构性)
    diff_r = np.diff(W, axis=1); diff_c = np.diff(W, axis=0)
    print(f"  相邻元素差std: 行向={diff_r.std():.4f}, 列向={diff_c.std():.4f} (≈权重std=结构性平滑)" if abs(diff_r.std()-std)<0.5*std else f"  相邻元素差std: {diff_r.std():.4f}")

    # ---- 汇总 ----
    print("\n=== 汇总 ===")
    low_entropy_src = []
    print(f"能否用通用公式?")
    print(f"  指数分布: {'高度集中(可公式化)' if domin>0.9 else '较分散'}")
    print(f"  尾数:     {'均匀随机(无公式)' if h_lo>11 else f'有小结构(熵{h_lo:.1f})'}")
    print(f"  谱:       {'满秩随机(MP)' if S.max()/S.min()<10 else '幂律(低秩)'}")