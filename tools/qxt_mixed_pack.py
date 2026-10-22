#!/data/data/com.termux/files/usr/bin/python3
"""qxt_mixed_pack.py — 混合精度打包: 按敏感度给张量分配不同 bitwidth.

动机: qxt_sens_scan 显示 Q2 误差在张量间分布较均匀 (Δ 0.20~0.56),
但仍有分层差异. 本打包器支持按规则给每个张量单独指定 bitwidth,
用来搜索"性价比最优"的混合配置 —— 例如:
  - attn_v / ffn_down / ffn_up 保 3-4bit, 其余 2bit
  - 前 N 层保高 bit, 后 N 层低 bit
  - 按实测敏感度排序贪心分配

输出格式与单档 packslim 相同, 但 meta.tensors 每项带 "bit" 字段,
SlimMat 据此按张量分派不同 b 的 C 内核.

用法:
  # 规则式: base=2, 高敏感类型提到 3 或 4
  PYTHONPATH=tools python3 tools/qxt_mixed_pack.py --base 2 \
      --promote attn_v=4,ffn_down=4,ffn_up=3
  # 按预算: 挑最敏感的若干张量提到 4bit
  PYTHONPATH=tools python3 tools/qxt_mixed_pack.py --base 2 --budget 4 --top 60
"""
import os
import sys
import json
import time

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mxfp4_regress as M
import qxt_pack_q1t as P
import qxt_fidelity_scan as Q

SRC = ("/data/data/com.termux/files/home/models/"
       "rStar-Coder-Qwen3-0.6B.Q8_0.gguf")
OUTDIR = "/data/data/com.termux/files/home/models/qxt/"
MAGIC = b"QXTSLIM1\n"
QK = 32

# 码本由 train_cb 从真实权重拟合 (与单档打包器 qxt_pack_q1t 完全同一函数),
# 不可硬编码 —— 4 位小数的近似码本会让混合包量化质量略差于对应单档.
CB_CACHE = {}


def get_cb(b):
    """懒加载: 用 qxt_pack_q1t.train_cb 拟合 b-bit 码本 (结果缓存)."""
    if b not in CB_CACHE:
        cb, nsamp = P.train_cb(SRC, b)
        CB_CACHE[b] = np.asarray(cb, np.float32)
    return CB_CACHE[b]

# 实测敏感度 (Δ Q2, 来自 qxt_sens_scan, 前3层均值), 用于 --top 贪心
SENS = {
    "attn_v": 0.416, "ffn_down": 0.409, "ffn_up": 0.399,
    "attn_output": 0.299, "attn_q": 0.269, "attn_k": 0.230,
    "ffn_gate": 0.212,
}


def kind_of(name):
    return name.split(".")[-2]


def parse_args(argv):
    base, budget, top, promotes, tag = 2, 4, 0, {}, "mix"
    period = 0
    promote_names = {}
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--base":
            base = int(argv[i + 1]); i += 2
        elif a == "--budget":
            budget = int(argv[i + 1]); i += 2
        elif a == "--top":
            top = int(argv[i + 1]); i += 2
        elif a == "--promote":
            for kv in argv[i + 1].split(","):
                k, v = kv.split("=")
                promotes[k] = int(v)
            i += 2
        elif a == "--promote-name":
            # 精确张量名提升: --promote-name blk.27.ffn_down.weight=4,...
            for kv in argv[i + 1].split(","):
                k, v = kv.rsplit("=", 1)
                promote_names[k] = int(v)
            i += 2
        elif a == "--period":
            period = int(argv[i + 1]); i += 2
        elif a == "--tag":
            tag = argv[i + 1]; i += 2
        else:
            raise SystemExit(f"未知参数 {a}")
    return base, budget, top, promotes, tag, period, promote_names


def layer_of(name):
    """从 blk.N.<type>.weight 解析层号; 非块内张量返回 -1."""
    p = name.split(".")
    if len(p) >= 2 and p[0] == "blk" and p[1].isdigit():
        return int(p[1])
    return -1


def decide_bits(base, budget, top, promotes, period, promote_names=None):
    """返回 name -> bit 的决策函数 (逐张量)."""
    if promote_names:
        return lambda name: promote_names.get(name, base)
    if period > 0:
        # 每 period 层放一个 budget-bit 修复层, 其余 base-bit.
        return lambda name: (budget if (layer_of(name) % period == period - 1)
                             else base)
    if promotes:
        return lambda name: promotes.get(kind_of(name), base)
    if top > 0:
        # 按敏感度把 top 个张量提到 budget
        order = sorted(SENS.items(), key=lambda kv: -kv[1])
        promote_kinds = {k for k, _ in order[:max(1, top // 28)]}  # 粗粒度
        return lambda name: (budget if kind_of(name) in promote_kinds else base)
    return lambda name: base


def main():
    base, budget, top, promotes, tag, period, promote_names = parse_args(sys.argv[1:])
    bitof = decide_bits(base, budget, top, promotes, period, promote_names)

    base_name = os.path.splitext(os.path.basename(SRC))[0]
    dst = os.path.join(OUTDIR, f"{base_name}-{tag}_packslim.gguf")
    kv, infos, ds = M.read_gguf(SRC)

    t0 = time.time()
    tensors = []
    tot = 0
    with open(dst, "wb") as f:
        f.write(MAGIC)
        f.write(b"\0" * 8)
        for t in infos:
            if (t.type == M.GGML_TYPE_Q8_0 and len(t.dims) >= 2
                    and t.name != "token_embd.weight"):
                b = bitof(t.name)
                cb = get_cb(b)
                off = f.tell()
                nbw = P.pack_tensor(SRC, t, ds, cb, b, f)
                tensors.append({"name": t.name, "dims": list(t.dims),
                                "bytes": nbw, "offset": off, "bit": b})
                tot += nbw
        bits_used = sorted({e["bit"] for e in tensors})
        meta = {"format": f"qxt-{tag}-slim", "bitwidth": base,
                "block_elems": QK, "block_bytes": 1 + 4 * base,
                "src": base_name, "n_tensors": len(tensors),
                "codebook": get_cb(base).tolist(), "tensors": tensors,
                "mixed": True, "period": period,
                # 混合精度: 每种用到的 bit 各存一份码本 (键为字符串以兼容 JSON)
                "codebooks": {str(b): get_cb(b).tolist() for b in bits_used}}
        jb = json.dumps(meta).encode("utf-8")
        f.write(jb)
        f.seek(9)
        f.write(len(jb).to_bytes(4, "little"))
        f.flush()

    # 统计
    from collections import Counter
    cnt = Counter(e["bit"] for e in tensors)
    nparam = sum(np.prod(e["dims"]) for e in tensors)
    bits_per = sum(np.prod(e["dims"]) * e["bit"] for e in tensors) / nparam
    print(f"wrote {dst}  {tot/1e6:.1f} MB  ({time.time()-t0:.1f}s)")
    print("  bit 分布: %s" % dict(sorted(cnt.items())))
    print("  平均有效位宽 (权重部分): %.3f bit" % bits_per)


if __name__ == "__main__":
    main()