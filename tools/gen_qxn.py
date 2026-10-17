#!/data/data/com.termux/files/usr/bin/python3
"""gen_qxn.py — 用 a3_pretrain.py 训出的模型做自回归生成.

动机: §31 的训练链只产出 checkpoint, 没有推理路径, 训完无法判断
"这个模型到底会不会写代码". 本脚本把 QxN 接到 Q4T 的 tokenizer 上,
做压缩词表 id -> 原始 token id -> 文本的完整还原.

关键点: a3_pretrain.py 的 compress_vocab 把 top-V 之外的 token 映射到
UNK(0), 原始 id 需由同一份 token 流重新计算 —— 词表映射必须与训练时一致,
否则解码出来是乱码.

用法:
  python3 tools/gen_qxn.py --ckpt final_fp32.npz --tokens codeonly_full.npz \
      --vocab 2400 --prompt "def fibonacci(n):" --n 40
"""
import os
import sys
import argparse

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
TOK_DEFAULT = ("/data/data/com.termux/files/home/models/qxt/"
               "rStar-Coder-Qwen3-0.6B.Q8_0-Q4T_packslim.gguf")


def rebuild_vocab(tokens_npz, topv):
    """与 a3_pretrain.compress_vocab 完全一致的映射: 压缩 id -> 原始 id."""
    ids = np.load(tokens_npz)["ids"]
    cnt = np.bincount(ids.astype(np.int64))
    cnt[0] = 0
    # 必须与 a3_pretrain.compress_vocab 逐字一致(修好 off-by-one 之后的那版):
    # keep 不加 1, lut 按 keep.max() 开. 这里曾长期是"加 1 + lut 取 cnt.size"的老写法,
    # §33.21 修 compress_vocab 时漏了这个副本 —— 训练与生成用的是两套映射.
    keep = np.argsort(-cnt)[:topv - 1]
    lut = np.zeros(max(int(keep.max()) + 1, cnt.size), np.int64)
    lut[keep] = np.arange(1, keep.size + 1)
    return keep, lut, int(keep.size + 1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ckpt", required=True)
    ap.add_argument("--tokens", required=True)
    ap.add_argument("--tok-model", default=TOK_DEFAULT)
    ap.add_argument("--vocab", type=int, default=2400)
    ap.add_argument("--n", type=int, default=40, help="生成 token 数")
    ap.add_argument("--temp", type=float, default=0.0)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--prompt", action="append", default=None)
    a = ap.parse_args()

    import qxn_train as T
    T.USE_GGML = False
    from q1t_stream import StreamEngine

    keep, lut, V = rebuild_vocab(a.tokens, a.vocab)
    z = np.load(a.ckpt)
    # mode 优先读 checkpoint 内的 mode 键. 1-bit 只在 forward 生效, checkpoint 里
    # 存的是 fp32 主权重 —— 若按错 mode 加载会静默生成垃圾且不报错.
    # 旧 checkpoint 无此键, 回退到文件名启发式.
    if "mode" in z.files:
        mode = str(z["mode"])
        src = "checkpoint"
    else:
        mode = "bitnet" if "bitnet" in os.path.basename(a.ckpt) else "fp32"
        src = "文件名(旧 ckpt 无 mode 键)"
    if mode not in ("fp32", "bitnet"):
        raise SystemExit(f"[gen] 非法 mode={mode!r}, 只支持 fp32 / bitnet")
    d = {k: z[k] for k in z.files if k != "mode"}
    D = d["l0.wq"].shape[0]
    # 层号在首段 (l0./l1.), 不是次段
    L = 1 + max(int(k.split(".")[0][1:]) for k in d
              if k.startswith("l") and k.split(".")[0][1:].isdigit())
    from qxn_train import build_from_ckpt
    import sampler
    m, (L2, D2, F2, V2, BLK) = build_from_ckpt(d, mode=mode)
    tok = StreamEngine(slim=a.tok_model)
    print(f"[gen] ckpt={a.ckpt} mode={mode} (来源: {src}) L={L2} d={D2} ffn={F2} V={V2} "
          f"blk={BLK} 参数 {sum(v.size for v in m.P.values())/1e6:.2f}M")
    print(f"[gen] {sampler.describe()}")

    prompts = a.prompt or ["def fibonacci(n):", "import numpy as np\n",
                          "# 读取 CSV 并按列求和\nimport pandas as pd\n",
                          "def quicksort(a):"]
    rng = np.random.default_rng(a.seed)
    for pr in prompts:
        orig = tok.encode(pr)
        ids = [int(lut[t]) for t in orig]
        if 0 in ids:                        # 提示里有词表外的 token
            ids = [c for c in ids if c != 0] or [1]
        seq = list(ids)
        out = []
        for _ in range(a.n):
            # 窗口长度必须是 checkpoint 的 posembd 行数(硬编码 512 是 §38.1
            # 的同一个坑: 训练 seq_len 与之不符时要么越界要么位置嵌入对不上)
            x = np.array([seq[-BLK:]], np.int64)
            # qxn_train.QxN.forward 恒返回完整 (T,V), collect 只控制缓存,
            # 所以要取最后位置 lg[-1]; 直接 argmax 会在展平数组上取索引(越界)
            lg = m.forward(x, collect=False)[0][-1].astype(np.float64)
            if sampler.ACTIVE:
                nxt = sampler.pick(lg, seq, rng)
            elif a.temp > 0:            # 命令行 --temp 优先于环境变量
                p = np.exp(lg - lg.max())
                p /= p.sum()
                nxt = int(rng.choice(len(p), p=p))
            else:
                nxt = int(np.argmax(lg))
            if nxt == 0:                    # 模型想输出 UNK, 退化为最高频真实 token
                nxt = int(np.argmax(lg[1:]) + 1)
            seq.append(nxt)
            out.append(nxt)
        real = [int(keep[i - 1]) for i in out if 1 <= i < keep.size + 1]
        print(f"\n提示: {pr!r}\n生成: {tok.decode_text(real)[:220]!r}")


if __name__ == "__main__":
    main()