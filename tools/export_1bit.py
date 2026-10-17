#!/data/data/com.termux/files/usr/bin/python3
"""export_1bit.py — 把 QAT checkpoint 导出成真正的 1-bit 模型.

动机(§33.18): checkpoint 里存的是 fp32 主权重, 1-bit 只在 forward 生效,
所以两个 checkpoint 一样大(2.19 MB). 用户问"为什么一样大"才暴露了
**导出这一步一直没做**.

量化方案必须与 qxn_train.binarize_w 完全一致:
    W_fwd = mean(|W|, axis=0) * sign(W)          # α 是逐输出通道
即三值 {-α, 0, +α}, 不是二值 —— sign 的零点会留下 0.

打包:
    三值 {-1,0,+1} -> 2 bit/元素 (00 / 01 / 10)
    α 逐输出通道, fp16
    非二值化张量 (embd/out/norm/an...) fp16

用法:
  python3 tools/export_1bit.py --ckpt F3_bitnet.npz --out F3_bitnet_1bit.npz
  python3 tools/export_1bit.py --ckpt F3_bitnet.npz --out x.npz --verify
"""
import argparse
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

QSUF = ("wq", "wk", "wv", "wo", "w1", "w3", "w2")
# 三值编码: -1 -> 00, 0 -> 01, +1 -> 10
TRI = {-1.0: 0, 0.0: 1, 1.0: 2}


def binarize_w(w):
    """与 qxn_train.binarize_w(scale=True) 逐位一致."""
    return (np.sign(w) * np.abs(w).mean(axis=0, keepdims=True)).astype(w.dtype)


def pack_trit(s):
    """三值数组 -> 2bit 打包 uint8 (每字节 4 个元素)."""
    flat = np.sign(s).ravel().astype(np.int8) + 1          # -1,0,+1 -> 0,1,2
    assert flat.min() >= 0 and flat.max() <= 2
    pad = (-flat.size) % 4
    if pad:
        flat = np.concatenate([flat, np.ones(pad, np.int8)])
    b = flat.reshape(-1, 4)
    out = (b[:, 0] | (b[:, 1] << 2) | (b[:, 2] << 4) | (b[:, 3] << 6)).astype(np.uint8)
    return out


def unpack_trit(p, n):
    b = np.empty((p.size, 4), np.int8)
    b[:, 0] = p & 3
    b[:, 1] = (p >> 2) & 3
    b[:, 2] = (p >> 4) & 3
    b[:, 3] = (p >> 6) & 3
    return (b.ravel()[:n].astype(np.float32) - 1.0)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ckpt", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--rest-dtype", choices=["fp16", "fp32"], default="fp32",
                    help="非量化参数(embd/out/norm/posembd)的精度. 实测 fp16 会让 "
                         "logits 相对误差达 11%%(RMSNorm 除以 embd 的 RMS 把相对误差放大), "
                         "fp32 降到 0.03%%.")
    ap.add_argument("--vocab", type=int, default=0,
                    help="验证时重建词表映射用的 top-V(0=沿用 checkpoint 的 out 通道数)")
    ap.add_argument("--verify", action="store_true",
                    help="重建后逐位比对 binarize_w, 并跑一次前向比对 logits")
    a = ap.parse_args()

    z = np.load(a.ckpt)
    mode = str(z["mode"]) if "mode" in z.files else None
    if mode is not None and mode != "bitnet":
        raise SystemExit(f"[export] {a.ckpt} 的 mode={mode!r}, 只有 bitnet 需要导出")
    P = {k: z[k] for k in z.files if k != "mode"}

    RD = np.float32 if a.rest_dtype == "fp32" else np.float16
    out, meta = {}, {}
    nq = nkeep = nq_bits = 0
    print(f"[export] {a.ckpt}  mode={mode or '(旧 ckpt, 按文件名未校验)'}")
    for k in sorted(P):
        w = P[k]
        if k.split(".")[-1] in QSUF:
            s = np.sign(w)
            alpha = np.abs(w).mean(axis=0).astype(np.float32)      # (n_out,)
            out[k + ":pk"] = pack_trit(s)
            out[k + ":al"] = alpha.astype(np.float16)
            out[k + ":sh"] = np.array(w.shape, np.int32)
            nq += w.size
            nq_bits += w.size * 2 + alpha.size * 16
        else:
            out[k] = w.astype(RD)
            nkeep += w.size
        meta[k] = np.array(1 if k.split(".")[-1] in QSUF else 0, np.int8)

    np.savez(a.out, **out)

    fp32_bytes = sum(v.size * 4 for v in P.values())
    got = os.path.getsize(a.out)
    print(f"  二值化张量   {nq:>9,} 参数  -> 2bit + fp16 α")
    print(f"  其余张量     {nkeep:>9,} 参数  -> {a.rest_dtype}")
    print(f"  合计         {nq+nkeep:>9,} 参数")
    print(f"  fp32 原文件  {fp32_bytes/1024:>9.1f} KB")
    print(f"  1-bit 导出   {got/1024:>9.1f} KB   压缩 {fp32_bytes/got:.2f}×")
    print(f"  理论下限(权重位) {nq_bits/8/1024:>6.1f} KB")

    if a.verify:
        zz = np.load(a.out)
        bad = 0
        for k in sorted(P):
            if k.split(".")[-1] not in QSUF:
                continue
            w = P[k]
            tri = unpack_trit(zz[k + ":pk"], w.size).reshape(w.shape)
            al = zz[k + ":al"].astype(np.float32)
            rec = (tri * al[None, :]).astype(np.float32)
            ref = binarize_w(w.astype(np.float32))
            err = np.abs(rec - ref).max()
            if err > 1e-3:          # fp16 α 的相对误差上限
                bad += 1
                print(f"  [FAIL] {k} 重建误差 {err:.4g}")
        print(f"  [verify] 二值化重建: {len(QSUF)}类张量, 失败 {bad} 个 "
              f"({'全部通过' if bad == 0 else '见上'})")
        if bad == 0:
            import qxn_train as T
            from qxn_train import QxN
            ids = np.load(os.environ["TOKNPZ"])["ids"]
            from gen_qxn import rebuild_vocab
            topv = a.vocab or int(P["out"].shape[1])
            _, lut, _ = rebuild_vocab(os.environ["TOKNPZ"], topv)
            BLK = int(P["posembd"].shape[0])              # 硬上下文上限=训练 seq_len
            x = lut[ids[0:BLK].astype(np.int64)][None]   # 全词表 id -> 压缩槽
            lg_a = _fwd(P, x, "bitnet", T)
            lg_b = _fwd(_recon(P, zz), x, "bitnet", T)
            d = float(np.abs(lg_a - lg_b).max())
            sd = float(lg_a.std())
            # 残差来自 α 与非二值化张量的 fp16 存储(二值化打包本身已逐位通过);
            # 实测 α/其余都改 fp32 时差异降到 1.5e-3, 两者是叠加的.
            rel = d / sd
            print(f"  [verify] 前向 logits 最大差异 {d:.3e} "
                  f"(logits 标准差 {sd:.3f}, 相对 {100*rel:.2f}%)")
            ok = bad == 0 and rel < 0.02
            print(f"  [verify] 判定 {'通过' if ok else '不通过'}")
            bad = 0 if ok else 1
        raise SystemExit(1 if bad else 0)


def _recon(P, zz):
    """从导出文件重建 fp32 主权重(供前向比对)."""
    out = {}
    for k in P:
        if k.split(".")[-1] in QSUF:
            sh = tuple(zz[k + ":sh"])
            tri = unpack_trit(zz[k + ":pk"], int(np.prod(sh))).reshape(sh)
            out[k] = (tri * zz[k + ":al"].astype(np.float32)[None, :]).astype(np.float32)
        else:
            out[k] = zz[k].astype(np.float32)
    return out


def _fwd(P, x, mode, T):
    m, _ = T.build_from_ckpt(P, mode=mode)
    return np.asarray(m.forward(x, collect=False)[0], np.float64)


if __name__ == "__main__":
    main()