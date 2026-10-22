"""qxt_repack.py — 把外积写入后的权重持久化进 packslim (交付产物).

流程:
  1. 读 packslim, 定位目标层 ffn_down 的字节区间
  2. 反量化 (用 SlimMat._matmul_np 的布局)
  3. 加外积 ΔB
  4. 用 q4f8 重新编码成 Q4T 块
  5. 原地覆盖 packslim 对应字节 -> 产出新文件

判据: 新文件加载后单条事实 rank 0 (与运行时覆盖一致)
"""
import os
import sys
import json
import shutil
import ctypes
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import q4f8_codebook as Q4
from q1t_stream import read_packslim, StreamEngine, SRC, rmsnorm, apply_rope, SC_TAB

QK = 32

# ---- C 块编码器 (q4t_encode.so), 失败退回 Python ----
_CENC = None
try:
    _so = os.path.join(os.path.dirname(os.path.abspath(__file__)), "q4t_encode.so")
    if os.path.exists(_so):
        _CENC = ctypes.CDLL(_so)
        _FP = np.ctypeslib.ndpointer(np.float32, flags="C")
        _UP = np.ctypeslib.ndpointer(np.uint8, flags="C")
        _CENC.q4t_encode_blocks.argtypes = [
            _FP, ctypes.c_long, _UP, _UP, _FP,
            ctypes.c_float, ctypes.c_float, ctypes.c_int]
except Exception:
    _CENC = None


def _enc_blocks_c(blocks, cb):
    """(N,32) float -> (scales (N) uint8, codes (N,16) uint8). 走 C, 否则 Python."""
    n = blocks.shape[0]
    if _CENC is not None:
        scales = np.zeros(n, np.uint8)
        codes = np.zeros((n, 16), np.uint8)
        _CENC.q4t_encode_blocks(
            np.ascontiguousarray(blocks, np.float32), n,
            scales, codes, np.ascontiguousarray(cb, np.float32),
            float(Q4.LOG_LO), float(Q4.SC_STEP), 17)
        return scales, codes
    return Q4.encode(blocks, codebook=cb.astype(np.float64))



def dequant_tensor(slim_path, entry, cb):
    """反量化 — 逐字复刻引擎 SlimMat._matmul_np 的读取顺序 (已验证正确)."""
    n_in, n_out = entry["dims"]
    bit = int(entry.get("bit", 4))
    bb = 1 + 4 * bit
    ibp = n_in // QK
    W = np.empty((n_in, n_out), np.float32)
    with open(slim_path, "rb") as f:
        f.seek(entry["offset"])
        for j0 in range(0, n_out, 64):
            nbc = min(64, n_out - j0)
            raw = f.read(nbc * ibp * bb)
            buf = np.frombuffer(raw, np.uint8).reshape(-1, bb)
            d = SC_TAB[buf[:, 0].astype(np.int64)]
            bits = np.unpackbits(np.ascontiguousarray(buf[:, 1:]), axis=1,
                                 bitorder="little")[:, :32 * bit]
            code = np.zeros((len(buf), QK), np.int64)
            for k in range(bit):
                code |= bits[:, np.arange(QK) * bit + k].astype(np.int64) << k
            val = d[:, None] * cb[code]                   # (nbc*ibp, 32)
            W[:, j0:j0 + nbc] = val.reshape(nbc, n_in).T
    return W


def quant_tensor(W, cb):
    """(n_in,n_out) -> Q4T 块字节 — 逐 64 列分块, 与引擎读取顺序互逆."""
    n_in, n_out = W.shape
    ibp = n_in // QK
    chunks = []
    for j0 in range(0, n_out, 64):
        nbc = min(64, n_out - j0)
        sub = W[:, j0:j0 + nbc].T                          # (nbc, n_in)
        blocks = sub.reshape(-1, QK)                       # [j][ib*32+e]
        sc, codes = _enc_blocks_c(np.ascontiguousarray(blocks, np.float32), cb)
        out = np.empty((len(blocks), 17), np.uint8)
        out[:, 0] = sc
        out[:, 1:] = codes
        chunks.append(out)
    return np.concatenate(chunks).tobytes()


def repack(slim_in, slim_out, layer_deltas, cb=None):
    """layer_deltas: {layer: np.ndarray(n_in,n_out)} 要加的 ΔB.

    产出 slim_out (复制 slim_in 后原地改 down 张量字节).
    """
    meta, by = read_packslim(slim_in)
    if cb is None:
        cb = np.asarray(meta["codebook"], np.float32)
    shutil.copyfile(slim_in, slim_out)
    with open(slim_out, "r+b") as f:
        for layer, dB in layer_deltas.items():
            name = f"blk.{layer}.ffn_down.weight"
            e = by[name]
            W = dequant_tensor(slim_in, e, cb)
            newbytes = quant_tensor(W + dB.astype(np.float32), cb)
            assert len(newbytes) == e["bytes"], (len(newbytes), e["bytes"])
            f.seek(e["offset"])
            f.write(newbytes)
    return meta, by


if __name__ == "__main__":
    print("自检: 反量化->重编码往返误差")
    H = StreamEngine(slim="/data/data/com.termux/files/home/models/qxt/rStar-Coder-Qwen3-0.6B.Q8_0-Q4T_packslim.gguf",
                     src=SRC, n_ctx=256)
    meta, by = read_packslim(H.slim)
    cb = np.asarray(meta["codebook"], np.float32)
    e = by["blk.2.ffn_down.weight"]
    W = dequant_tensor(H.slim, e, cb)
    rb = quant_tensor(W, cb)
    print(f"  张量 {e['dims']} bytes {e['bytes']} 重编码 {len(rb)} 一致 {len(rb)==e['bytes']}")
    # 往返误差: 直接反量化回来看
    print(f"  W |.|={np.linalg.norm(W):.2f}  (无写入, 仅验证布局自洽)")
