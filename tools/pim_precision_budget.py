# pim_precision_budget.py — PIM 侧精度预算（真实权重 + 模拟路径）
#
# 数据：dequant_tensor 从 GGUF 抽出的真实权重行（IQ3_XXS gate / IQ3_S down / Q8_0 ssm_out）。
# 模拟：权重 cell 表示（有限电平 or fp）→ DAC 激活量化 → 模拟组内累加 → ADC 组和量化
#       → 数字 scale → fp32 跨组累加。参考 = double 累加（dequant 权重）。
# 误差口径：normrms = max|err| / RMS(ref)，与 sim_cim.c 一致。
#
# 用途：细算 PIM 精度预算——逐误差源分解 + 器件噪声裕量 + 对比 llama.cpp 已接受的量化基线。
import numpy as np

DATA = "F:/sram/sram/data/pim"
RNG = np.random.default_rng(7)

# (label, tensor, W行数, d0)  —— 真实 dequant 权重
TENSORS = {
    "gate_exps IQ3_XXS":  ("blk0_gate_exps.f32", 512, 2048),
    "down_exps IQ3_S":    ("blk0_down_exps.f32", 64, 512),
    "ssm_out Q8_0":       ("blk0_ssm_out.f32",  64, 4096),
}

def load_w(name, rows, d0):
    raw = np.fromfile(f"{DATA}/{name}", dtype=np.float32)
    assert raw.size == rows * d0, f"{name}: expected {rows*d0} got {raw.size}"
    return raw.reshape(rows, d0)

def ref_gemv(W, x):
    """double 参考（同 llama.cpp 语义：dequant 权重 × fp32 激活，高精度累加）"""
    return W.astype(np.float64) @ x.astype(np.float64)

def quant_levels(v, bits, rmax=None):
    """均匀 N 电平量化到 [-rmax, rmax]"""
    if rmax is None:
        rmax = np.max(np.abs(v))
    if np.all(rmax == 0):
        return v
    n = 1 << (bits - 1)
    step = rmax / n
    q = np.clip(np.round(v / step) * step, -rmax, rmax)
    return q

def mxfp4_repr(w, block=32):
    """MXFP4（E2M1 + 8bit 块级 scale）权重表示，与 sim_cim.c 口径一致。
    档位 = 1,1.5,2,3,4,6,8,12（E2M1：mant 1.0/1.5 × 2^e, e=0..3），块 scale 为 2 的幂。"""
    rows, d0 = w.shape
    if d0 < block:
        return quant_levels(w, 4)  # fallback uniform for tiny d0
    Wb = w.reshape(rows, d0 // block, block)
    s = np.sign(Wb)
    a = np.abs(Wb)
    amax = np.max(a, axis=2, keepdims=True)
    amax[amax == 0] = 1.0
    scale = np.power(2.0, np.floor(np.log2(amax / 12.0)))  # 使 12*scale >= amax
    r = a / scale
    levels = np.array([1, 1.5, 2, 3, 4, 6, 8, 12])
    idx = np.abs(r[:, :, :, None] - levels.reshape(1, 1, 1, -1)).argmin(axis=-1)
    q = levels[idx] * scale * s
    return q.reshape(rows, d0)

def cell_repr(w, bits, block=None, mxfp4=False):
    """权重 cell 表示（模拟存储分辨率的权重重表示误差）。
    mxfp4=True 时用 MXFP4（E2M1 块级指数，对齐 sim_cim.c）；
    否则 block=None 时 per-row 均匀归一，block>0 时按 block 长度块级 scale。
    bits=None 表示数字 cell（fp，无表示误差）。"""
    if bits is None:
        return w.copy()
    if mxfp4:
        if w.shape[1] < (block if block else 32):
            return quant_levels(w, bits)
        return mxfp4_repr(w, block if block else 32)
    if block is None:
        block = w.shape[1]
    if block > w.shape[1]:
        block = w.shape[1]
    rows, d0 = w.shape
    if d0 % block != 0:
        raise ValueError(f"d0={d0} not divisible by block={block}")
    Wb = w.reshape(rows, d0 // block, block)
    amax = np.max(np.abs(Wb), axis=2, keepdims=True)
    amax[amax == 0] = 1.0
    n = 1 << (bits - 1)
    step = amax / n
    q = np.clip(np.round(Wb / step) * step, -amax, amax)
    return q.reshape(rows, d0)

def adc_quant(s, bits, amax=None):
    if bits is None:
        return s
    if amax is None:
        amax = np.max(np.abs(s))
    if np.all(amax == 0):
        return s
    n = 1 << (bits - 1)
    step = amax / n
    return np.clip(np.round(s / step) * step, -amax, amax)

def dac_quant(x, bits, rmax=None):
    if bits is None:
        return x
    if rmax is None:
        rmax = np.max(np.abs(x))
    if np.all(rmax == 0):
        return x
    n = 1 << (bits - 1)
    step = rmax / n
    return np.clip(np.round(x / step) * step, -rmax, rmax)

def pim_gemv(W, x, w_bits, dac_bits, adc_bits, grp, cell_var, col_noise, w_block=None, w_mxfp4=False):
    """PIM 路径 GEMV（一行一行处理，参考 sim_cim.c 语义）。
    w_bits=None 数字 cell；dac/adc_bits=None 表示不量化（理想外围）。
    grp = 模拟组段大小（按列分组）；w_block = cell 块级 scale 块长（None=per-row）。
    w_mxfp4=True 时权重用 MXFP4（E2M1 块级指数）表示。"""
    Wq = cell_repr(W, w_bits, w_block, w_mxfp4)
    xq = dac_quant(x, dac_bits)
    rows, d0 = W.shape
    y = np.zeros(rows, dtype=np.float64)
    if w_bits is not None and cell_var > 0:
        Wq = Wq * (1.0 + cell_var * RNG.standard_normal(W.shape))
    for g0 in range(0, d0, grp):
        g1 = min(g0 + grp, d0)
        seg = Wq[:, g0:g1] * xq[g0:g1]          # 模拟组内累加（电荷相加，无舍入）
        s = seg.sum(axis=1)                      # 组段部分和
        amax = np.max(np.abs(s)) if adc_bits is not None else None
        s = adc_quant(s, adc_bits, amax)
        if col_noise > 0 and adc_bits is not None:
            s = s + col_noise * amax * RNG.standard_normal(s.shape)
        y += s                                   # 数字侧 fp32 跨组累加（此处 double 但等量 fp32 舍入，~1e-7 级）
    return y

def normrms(dev, ref):
    rms = np.sqrt(np.mean(ref ** 2))
    return np.max(np.abs(dev - ref)) / rms if rms > 0 else np.nan

def normrms_stat(dev, ref):
    """返回 (max, p95, p50) 行级 |err|/RMS —— 区分最坏单行与典型误差。"""
    rms = np.sqrt(np.mean(ref ** 2))
    e = np.abs(dev - ref)
    return (e.max() / rms, np.percentile(e, 95) / rms, np.percentile(e, 50) / rms) if rms > 0 else (np.nan,) * 3

def make_x(d0, n=128, scale=1.0):
    """模拟激活：RMSNorm 后的类高维随机（零均值、近单位方差）"""
    x = RNG.standard_normal((n, d0)).astype(np.float32) * scale
    return x

def scan(w, x, name):
    print(f"\n### {name}   W={w.shape[0]}x{w.shape[1]}  激活 n={x.shape[0]}")
    print("  W范围 min=%.3f max=%.3f rms=%.4f 零占比=%.1f%%"
          % (w.min(), w.max(), np.sqrt(np.mean(w**2)), 100*np.mean(w == 0)))
    refs = np.array([ref_gemv(w, xi) for xi in x])

    print("  1) 权重重表示误差（cell 电平，DAC/ADC 理想；对齐 sim_cim 口径）：")
    for bits in (4, 6, 8):
        stats = [normrms_stat(pim_gemv(w, xi, bits, None, None, 256, 0, 0, w_block=32), refs[i]) for i, xi in enumerate(x)]
        m = max(s[0] for s in stats); p = np.percentile([s[1] for s in stats], 95); p50 = np.percentile([s[2] for s in stats], 50)
        print(f"     {bits}bit blk32: max={m:.2e}  p95={p:.2e}  p50={p50:.2e}")
    res = [normrms(pim_gemv(w, xi, 4, None, None, 256, 0, 0, w_block=32, w_mxfp4=True), refs[i]) for i, xi in enumerate(x)]
    print(f"     MXFP4 E2M1: max|err|/RMS = {max(res):.2e}")

    print("  1c) 模型原块结构（block=256）均匀 cell：")
    for bits in (4, 6, 8):
        res = [normrms(pim_gemv(w, xi, bits, None, None, 256, 0, 0, w_block=256), refs[i]) for i, xi in enumerate(x)]
        print(f"     {bits}bit blk256: max|err|/RMS = {max(res):.2e}")

    print("  1b) per-row 均匀 cell 对比（旧口径，block=整行）：")
    for bits in (6, 8):
        res = [normrms(pim_gemv(w, xi, bits, None, None, 256, 0, 0, w_block=None), refs[i]) for i, xi in enumerate(x)]
        print(f"     {bits}bit per-row: max|err|/RMS = {max(res):.2e}")

    print("  2) DAC 激活量化（权重 fp，ADC 理想）：")
    for bits in (6, 8, 10, 12):
        res = [normrms(pim_gemv(w, xi, None, bits, None, 256, 0, 0), refs[i]) for i, xi in enumerate(x)]
        print(f"     DAC{bits:>2}: max|err|/RMS = {max(res):.2e}")

    print("  3) ADC 组段量化（权重 fp，DAC 理想，组段=256）：")
    for bits in (8, 10, 12, 14):
        res = [normrms(pim_gemv(w, xi, None, None, bits, 256, 0, 0), refs[i]) for i, xi in enumerate(x)]
        print(f"     ADC{bits:>2}: max|err|/RMS = {max(res):.2e}")

    print("  4) 组合预算（cell 8bit 块级/32 + DAC/ADC 扫描 + cell 变异 0.5% + 列噪声 0.1%FS）：")
    for dac in (8, 10, 12):
        for adc in (10, 12, 14):
            res = [normrms(pim_gemv(w, xi, 8, dac, adc, 256, 0.005, 0.001, w_block=32), refs[i]) for i, xi in enumerate(x)]
            print(f"     8bit blk32 + DAC{dac} + ADC{adc}: max|err|/RMS = {max(res):.2e}")
    print("  4b) MXFP4 权重 + DAC/ADC 扫描 + cell 变异 0.5% + 列噪声 0.1%FS：")
    for dac in (8, 10, 12):
        for adc in (10, 12, 14):
            res = [normrms(pim_gemv(w, xi, 4, dac, adc, 256, 0.005, 0.001, w_block=32, w_mxfp4=True), refs[i]) for i, xi in enumerate(x)]
            print(f"     MXFP4 + DAC{dac} + ADC{adc}: max|err|/RMS = {max(res):.2e}")
    print("  5) 组段大小敏感性（cell fp，DAC10/ADC12，无器件）：")
    for grp in (32, 64, 128, 256):
        res = [normrms(pim_gemv(w, xi, None, 10, 12, grp, 0, 0), refs[i]) for i, xi in enumerate(x)]
        print(f"     grp={grp:>3}: max|err|/RMS = {max(res):.2e}")

def main():
    for name, (fname, rows, d0) in TENSORS.items():
        w = load_w(fname, rows, d0).astype(np.float64)
        x = make_x(d0, n=64)
        scan(w, x, name)

    print("\n== 对照 sim_cim.c（MXFP4 权重）：理想 DAC10/ADC12 -> max|err|/RMS = 4.04e-3 ==")

if __name__ == "__main__":
    main()
