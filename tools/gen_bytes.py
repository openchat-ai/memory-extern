#!/data/data/com.termux/files/usr/bin/python3
"""gen_bytes.py — 字节级模型的自回归生成.

关键点(§41): 采样前必须用 `lg - lg.max()` 平移 logits, **不能** `lg / lg.max()`.
后者在 max<0 时翻转大小关系, 把最不可能的 token 变成概率 1 —— 之前的"温度采样
出噪声"全是这个 bug, 与模型无关.

支持: 贪心 / 温度 / top-k / top-p(nucleus) / 重复惩罚, 均为环境变量.
  TEMP  温度, 0=贪心
  TOPK  保留 top-k 个候选, 0=不截断
  TOPP  nucleus 阈值, 0=不截断
  REP   重复惩罚, 1.0=关闭
  SEED  随机种子
  BYTENS  训练数据 npz(用于重建词表映射, 必须与训练时一致)
"""
import os
import sys

import numpy as np

sys.path.insert(0, "/data/data/com.termux/files/home/sram/tools")
os.environ.setdefault("QXN_GGML", "0")
from a3_pretrain import compress_vocab          # noqa: E402
from qxn_train import build_from_ckpt           # noqa: E402

BYTENS = os.environ.get(
    "BYTENS", "/data/data/com.termux/files/usr/tmp/opencode/code_b2m.npz")
import sampler  # noqa: E402  采样逻辑的唯一实现(§41 的 bug 不再有两份拷贝)


def main():
    ck = sys.argv[1]
    n = int(sys.argv[2])
    prompts = sys.argv[3:]

    raw = np.load(BYTENS)["ids"].astype(np.int64)
    seq, V, KEEP = compress_vocab(raw, 182)
    lut = np.zeros(int(KEEP.max()) + 2, np.int64)
    lut[KEEP] = np.arange(1, KEEP.size + 1)
    inv = np.zeros(V, np.int64)
    inv[1:KEEP.size + 1] = KEEP

    z = np.load(ck)
    mode = str(z["mode"]) if "mode" in z.files else "fp32"
    m, (L, D, F, VV, BLK) = build_from_ckpt({k: z[k] for k in z.files}, mode=mode)
    rng = np.random.default_rng(sampler.SEED)

    def decode(ids):
        return bytes(int(inv[t]) - 1 if t and inv[t] > 0 else 32 for t in ids)

    print(f"[gen] {os.path.basename(ck)} mode={mode} V={VV} blk={BLK} "
          + sampler.describe())
    for pr in prompts:
        x = [int(lut[c + 1]) for c in pr.encode()]
        for _ in range(n):
            lg = np.asarray(m.forward(np.array([x[-BLK:]], np.int64),
                                     collect=False)[0], np.float64)[-1]
            x.append(sampler.pick(lg, x, rng))
        print("提示: %r" % pr)
        print("生成: %r\n" % decode(x).decode("utf-8", "replace"))


if __name__ == "__main__":
    main()
