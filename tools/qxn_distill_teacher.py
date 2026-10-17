#!/data/data/com.termux/files/usr/bin/python3
"""qxn_distill_teacher.py — 教师 logits 提取 (离线预计算).

蒸馏的前提: 学生学的不是硬标签, 而是**教师的软分布**
    p_teacher = softmax(z_teacher / T)
"暗知识"(dark knowledge) 就在这个软分布里 —— 教师对非正确答案给出的
相对置信度编码了类别间的相似性, 硬标签完全丢失了这些信息.

教师选择: 直接用**已验证的 Q4T 引擎** (q1t_stream.py) 而非 fp32 numpy.
  - 速度: 0.6B Q4T 3.73 t/s vs fp32 numpy 数分钟/token
  - 质量: Q4T 输出正确 (The capital of France is **Paris**)
  - 用量化模型做教师是标准做法 (quantized self-distillation)

工程约束: 词表 151936 维, 全量 logits 存不下
    1 window (32 tok) = 32 x 151936 x 4B = 19.5 MB
必须 Top-K 截断. K=64 时每 token 512 B, 1万 token 约 5 MB.

用法:
  PYTHONPATH=tools python3 tools/qxn_distill_teacher.py \
      --slim models/qxt/rStar-Coder-Qwen3-0.6B.Q8_0-Q4T_packslim.gguf \
      --text notes/memory-compute-notes.md \
      --out teacher_k64.npz --topk 64 --temperature 3.0 --n_windows 200

  PYTHONPATH=tools python3 tools/qxn_distill_teacher.py --inspect teacher_k64.npz
"""
import argparse
import glob
import os
import sys
import time

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from q1t_stream import StreamEngine

DEFAULT_SLIM = ("/data/data/com.termux/files/home/models/qxt/"
                "rStar-Coder-Qwen3-0.6B.Q8_0-Q4T_packslim.gguf")


def collect_text(paths, max_chars=400000):
    """读取一个或多个文本文件. 支持目录 (取 *.md/*.txt)."""
    files = []
    for p in paths:
        if os.path.isdir(p):
            for ext in ("*.md", "*.txt", "*.py", "*.c", "*.h"):
                files += sorted(glob.glob(os.path.join(p, "**", ext),
                                           recursive=True))
        else:
            files.append(p)
    out = []
    total = 0
    for f in files:
        try:
            with open(f, "r", encoding="utf-8", errors="replace") as fh:
                t = fh.read(max_chars)
        except OSError:
            continue
        out.append(t)
        total += len(t)
        if total >= max_chars:
            break
    return "\n\n".join(out), files


def topk_from_logits(lg, k):
    """lg (T,V) -> (idx (T,k) int32, val (T,k) float32), 按值降序."""
    T, V = lg.shape
    part = np.argpartition(-lg, k - 1, axis=1)[:, :k]
    val = np.take_along_axis(lg, part, axis=1)
    order = np.argsort(-val, axis=1)
    idx = np.take_along_axis(part, order, axis=1)
    val = np.take_along_axis(val, order, axis=1)
    return idx.astype(np.int32), val.astype(np.float32)


def extract(slim, text, topk, temperature, seq_len, n_windows, out_path,
            stride=None, every=0, resume=False):
    E = StreamEngine(slim=slim)
    ids = E.encode(text)
    print(f"[teacher] {os.path.basename(slim)}  n_vocab={E.n_vocab}")
    print(f"[teacher] 语料 {len(ids)} tokens", flush=True)

    stride = stride or (seq_len - 1)     # 滑动 1 格, 首尾 token 都可监督
    all_idx, all_val, all_tgt = [], [], []
    t0 = time.time()
    nw = 0
    # 断点续传: 已完成的分片直接复用, 避免长跑中断后从头再来.
    part = out_path + ".part.npz"
    all_idx, all_val, all_tgt = [], [], []
    if resume and os.path.exists(part):
        try:
            z = np.load(part)
            all_idx, all_val, all_tgt = [z["idx"]], [z["val"]], [z["tgt"]]
            print(f"[teacher] 续传已有 {all_tgt[0].shape[0]} tokens", flush=True)
        except Exception:
            all_idx, all_val, all_tgt = [], [], []

    for lo in range(0, len(ids) - 2, stride):
        if nw >= n_windows:
            break
        chunk = ids[lo:lo + seq_len]
        if len(chunk) < 4:
            break
        lg, _ = E.forward(np.array(chunk, np.int64), full_logits=True)
        lg = lg[:-1]                          # 位置 t 预测 t+1
        tgt = np.asarray(chunk[1:], np.int64)
        ix, vl = topk_from_logits(lg, topk)
        all_idx.append(ix)
        all_val.append(vl / temperature)       # 存 z/T
        all_tgt.append(tgt.astype(np.int32))
        nw += 1
        if nw % 20 == 0 or nw == 1:
            el = time.time() - t0
            print(f"  window {nw}: 累计 {sum(len(a) for a in all_tgt)} tok "
                  f"({el:.0f}s, {el/nw:.2f}s/win)", flush=True)
        # 定期分段落盘: 4 小时量级的提取不能只靠结束时的最终保存
        if out_path and every and nw % every == 0:
            np.savez(part, idx=np.concatenate(all_idx),
                     val=np.concatenate(all_val),
                     tgt=np.concatenate(all_tgt))

    idx = np.concatenate(all_idx)
    val = np.concatenate(all_val)
    tgt = np.concatenate(all_tgt)
    print(f"[teacher] 输出 {idx.shape[0]} tokens x top{idx.shape[1]}")
    np.savez_compressed(out_path, idx=idx, val=val, tgt=tgt,
                        temperature=np.float32(temperature),
                        topk=np.int32(topk), slim=np.array(slim))
    print(f"[teacher] wrote {out_path}  "
          f"{os.path.getsize(out_path)/1e6:.1f} MB")

    # --- 软目标质量诊断 ---
    agree = (idx[:, 0] == tgt).mean()
    p = np.exp(val - val.max(1, keepdims=True))
    p /= p.sum(1, keepdims=True)
    ent = -(p * np.log(p + 1e-12)).sum(1).mean()
    # top-1 与 top-2 的差距: 越大说明教师越自信
    gap = (val[:, 0] - val[:, 1]).mean()
    print(f"[teacher] 教师 top-1 与真实 token 一致率 = {agree*100:.2f}%")
    print(f"[teacher] 软目标熵 = {ent:.3f} nats   top1-top2 gap = {gap:.3f}")
    print(f"[teacher] 教师困惑度上界 = {np.exp(ent):.1f}")


def inspect(path):
    d = np.load(path, allow_pickle=True)
    idx, val, tgt = d['idx'], d['val'], d['tgt']
    print(f"file      : {path}")
    print(f"tokens    : {idx.shape[0]}")
    print(f"topk      : {idx.shape[1]}")
    print(f"temp      : {float(d['temperature'])}")
    print(f"teacher   : {str(d['slim'])}")
    print(f"内存      : {(idx.nbytes+val.nbytes)/1e6:.2f} MB")
    agree = (idx[:, 0] == tgt).mean()
    p = np.exp(val - val.max(1, keepdims=True))
    p /= p.sum(1, keepdims=True)
    ent = -(p * np.log(p + 1e-12)).sum(1).mean()
    print(f"top-1 一致: {agree*100:.2f}%")
    print(f"软目标熵  : {ent:.3f} nats  (教师困惑度 {np.exp(ent):.1f})")
    print(f"平均 top1 概率: {p[:,0].mean():.3f}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--slim", default=DEFAULT_SLIM)
    ap.add_argument("--text", nargs="*", default=None)
    ap.add_argument("--out", default=None)
    ap.add_argument("--topk", type=int, default=64)
    ap.add_argument("--temperature", type=float, default=3.0)
    ap.add_argument("--seq_len", type=int, default=32)
    ap.add_argument("--n_windows", type=int, default=300)
    ap.add_argument("--max_chars", type=int, default=400000)
    ap.add_argument("--inspect", default=None)
    ap.add_argument("--every", type=int, default=50,
                    help="每 N 个窗口把结果分段落盘 (0=只在最后保存)")
    ap.add_argument("--resume", action="store_true",
                    help="从 <out>.part.npz 续跑")
    args = ap.parse_args()

    if args.inspect:
        inspect(args.inspect)
        return
    if not args.text or not args.out:
        print(__doc__)
        return
    text, files = collect_text(args.text, args.max_chars)
    print(f"[teacher] 读取 {len(files)} 个文件, {len(text)} 字符")
    extract(args.slim, text, args.topk, args.temperature, args.seq_len,
            args.n_windows, args.out, every=args.every, resume=args.resume)


if __name__ == "__main__":
    main()