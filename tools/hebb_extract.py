"""赫布反向提取 (hebb-extract): 从已交付 GGUF 里把写入的事实读回来.

原理 (docs §10.17):
  ΔB = B_edited - B_base 是 rank-k (k = 事实条数)
  -> SVD 给出 k 维子空间; 右奇异向量 (d=1024) 过 norm+unembedding 读出值 token
  -> 若提供键 (原句), 最小二乘解混, 每条事实单独还原

用法:
  python tools/hebb_extract.py --edited models/qxt/rStar-Coder-hebbit-1L18.gguf
  python tools/hebb_extract.py --edited ... --keys "The largest planet is|The color of the sky is"
"""
import argparse
import sys

import numpy as np

sys.path.insert(0, "/data/data/com.termux/files/home/sram/tools")
from q1t_stream import read_packslim, rmsnorm, q8_gemm_proj  # noqa: E402
from qxt_repack import dequant_tensor  # noqa: E402
from hebb_write import DEFAULT_SLIM, HebbWriter  # noqa: E402


def changed_layers(base, edited):
    """按张量字节比对, 返回 (layer, 改动字节数)."""
    _, by_b = read_packslim(base)
    _, by_e = read_packslim(edited)
    out = []
    with open(base, "rb") as fb, open(edited, "rb") as fe:
        for name, eb in by_b.items():
            if "ffn_down" not in name or not eb.get("bytes"):
                continue
            ee = by_e.get(name)
            if ee is None or ee["bytes"] != eb["bytes"]:
                continue
            fb.seek(eb["offset"])
            fe.seek(ee["offset"])
            a = np.frombuffer(fb.read(eb["bytes"]), np.uint8)
            b = np.frombuffer(fe.read(ee["bytes"]), np.uint8)
            n = int((a != b).sum())
            if n:
                out.append((int(name.split(".")[1]), n, eb["bytes"]))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default=DEFAULT_SLIM)
    ap.add_argument("--edited", required=True)
    ap.add_argument("--keys", default="", help="用 | 分隔的原句, 提供后做解混")
    ap.add_argument("--top", type=int, default=5)
    a = ap.parse_args()

    hits = changed_layers(a.base, a.edited)
    print(f"[scan] 改动层 {[l for l, _, _ in hits]}  "
          f"{sum(n for _, n, _ in hits):,} B")
    meta, by = read_packslim(a.base)
    cb = np.asarray(meta["codebook"], np.float32)
    H = HebbWriter(n_ctx=512)
    E = H.eng

    def readout(vec, k):
        x = rmsnorm(np.ascontiguousarray(vec, np.float32)[None, :],
                    E.norm["output_norm.weight"], E.eps)
        lg = np.empty((1, E.n_vocab), np.float32)
        q8_gemm_proj(E._embd_raw.ctypes.data, E.n_embd, E.n_vocab,
                     x.ctypes.data, 1, lg.ctypes.data, 2)
        idx = np.argsort(lg[0])[::-1][:k]
        return [(E.tok_list[i], round(float(lg[0][i]), 1)) for i in idx]

    keys = [s for s in a.keys.split("|") if s.strip()] if a.keys else []
    for li, nbytes, total in hits:
        name = f"blk.{li}.ffn_down.weight"
        e = by[name]
        B = dequant_tensor(a.base, e, cb).astype(np.float64)
        dB = dequant_tensor(a.edited, e, cb).astype(np.float64) - B
        U, S, Vt = np.linalg.svd(dB, full_matrices=False)
        # rank 估计: 累积能量到 50% 所需的维数 (量化噪声是长尾, 不能用阈值)
        ce = np.cumsum(S**2) / (S**2).sum()
        k = int(min(8, np.searchsorted(ce, 0.50) + 1))
        # 与"最大奇异值比"交叉验证
        rat = S[:8] / np.maximum(S[1:9], 1e-12)
        k_ratio = int(np.argmax(rat) + 1)
        print(f"\n--- {name}  改动 {nbytes:,} B ({100*nbytes/total:.2f}% 张量) ---")
        print(f"  sigma top6 {[round(float(x), 3) for x in S[:6]]}"
              f"  | 相邻比 {[round(float(x), 2) for x in rat[:5]]}")
        print(f"  累计能量50% -> k={k}  (最大比拐点 k={k_ratio})  "
              f"top2 能量 {100*float(ce[1]):.1f}%")
        for r in range(min(k, 4)):
            print(f"  分量{r}: {readout(Vt[r], a.top)}")
        if keys:
            Phi = np.stack([H.capture_phi(E.encode(p))[li] for p in keys], 1)
            V = np.linalg.lstsq(Phi, dB, rcond=None)[0]
            res = np.linalg.norm(dB - Phi @ V) / np.linalg.norm(dB)
            print(f"  [解混] 残差 {res:.3f}；每条事实:")
            for r, p in enumerate(keys):
                print(f"    {p!r:28s} -> {readout(V[r], a.top)[:3]}")


if __name__ == "__main__":
    main()
