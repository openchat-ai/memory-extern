#!/data/data/com.termux/files/usr/bin/python3
"""a3_pretrain.py — 小模型秒级训练, 用于快速横向对比数据配方.

为什么不用蒸馏路径:
  qxn_distill_student.py 每步要做 KL(top-64) + _logits_grad, 且需要教师软目标;
  试配方时这些是纯开销. 本脚本只做交叉熵, 输入是纯文本, 因此可以:
    - 不需要教师提取 (省掉 9.1 tok/s 的瓶颈)
    - 省掉 KL/_logits_grad 的每步开销
    - 词表可任意压缩 (小模型的参数大头就是 embedding)

典型用法 (一次配方实验):
  python3 tools/a3_pretrain.py --data magicoder_a3.jsonl --steps 300 \\
      --n_layer 4 --n_embd 64 --n_ff 192 --vocab 8000 --out /tmp/a

用法:
  python3 tools/a3_pretrain.py --data magicoder_a3.jsonl --tokenize-only tok.npz
  python3 tools/a3_pretrain.py --data magicoder_a3.jsonl --tokens tok.npz --steps 300
"""
import os
import re
import sys
import json
import math
import time
import argparse

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

CODE = re.compile(r"```(?:python|py|python3)\s*\n(.*?)```", re.S)


def tokenize_file(path, tok, limit=None, mode="a3"):
    """把 jsonl 或纯文本切成 token id 流."""
    from q1t_stream import StreamEngine
    e = StreamEngine(tok)
    ids = []
    n = 0
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            if line.startswith("{"):
                try:
                    r = json.loads(line)
                except Exception:
                    continue
                if mode == "a3":
                    txt = (r.get("instruction", "") + "\n\n" +
                           "\n\n".join(CODE.findall(r.get("code", "")) or
                                       [r.get("code", "")]))
                else:
                    txt = r.get("code", "")
            else:
                txt = line
            ids.extend(e.encode(txt))
            n += 1
            if limit and n >= limit:
                break
            if n % 20000 == 0:
                print(f"  分词 {n} 文档 / {len(ids)/1e6:.1f}M tokens", flush=True)
    return np.array(ids, np.int32), e


def compress_vocab(ids, topv):
    """只保留最高频的 topv 个 token, 其余映射到 1 (UNK); 0 留给 UNK/BOS."""
    cnt = np.bincount(ids.astype(np.int64))
    cnt[0] = 0
    # 注意: keep 绝不能再 +1. 旧写法 keep=...+1, 而下面用 lut[ids] 按原始 id
    # 查表, 两者错开一位 —— 等价于"只有前驱 id 进了高频榜的 token 才可表达".
    # 对稠密词表因相邻 id 频次接近而大多互相抵消, 但**最高频的 token 会被丢掉**:
    # 字节级语料里就是空格(占 21.5%), 变 UNK, 模型永远学不会输出空格.
    keep = np.argsort(-cnt)[:topv - 1]              # 0 号留给 UNK; id 本身不加偏移
    lut = np.zeros(max(int(keep.max()) + 1, cnt.size), np.int64)
    lut[keep] = np.arange(1, keep.size + 1)
    out = lut[ids.astype(np.int64)]
    # 词表大小 = 保留的 token 数 + 1 (0 号 UNK 槽), 否则最大 id 会越界
    return out.astype(np.int32), keep.size + 1, keep


def _stem(path):
    return path[:-4] if path.endswith(".npz") else path


def label_mask(x, y, V, lab_slots, at_slot):
    """挑出"目标是标签字符, 且紧前一个 token 是 @"的位置.

    对齐: logits[:,t] 的目标是 y[:,t] = x[:,t+1], 所以标签位的前一个 token
    是 x[:, t+1], 不是 x[:, t] —— 这里容易差一位.
    """
    sel = np.isin(y, lab_slots)
    # get(): y[t] = x[t+1], 所以 y[t] 前面紧邻的 token 是 **x[t]**, 不是 x[t+1]
    # (x[t+1] 正是 y[t] 自己, 拿它判会恒为假 —— 实测选中位置数 0)
    prev = np.zeros_like(sel)
    prev[:, :-1] = (x[:, :-1] == at_slot)
    return sel & prev


def save_ckpt(m, path, mode):
    """mode 必须写进 checkpoint: 1-bit 只在 forward 生效, 存的是 fp32 主权重;
    加载方猜错 mode 会静默按 fp32 跑 1-bit 权重 -> 生成垃圾且不报错.
    早期 checkpoint 无此键, 加载方回退到文件名启发式."""
    np.savez(path, **{k: v for k, v in m.P.items()}, mode=np.array(mode))
    print(f"[save] {path}", flush=True)


def _ce(logits, y, V):
    """训练 loss: 与 eval 段的 cek 完全同一套索引(lsm, yf>0 掩码)。
    之前自己手写 lgv=int(logits[0,-1]) + yf-1 的写法是错的:
    logits 是 (B,T,V), y 已是压缩槽(0=UNK, 其余为保留 token 的 1-based 槽位),
    没有 -1 偏移 —— 写错会算出负 CE。"""
    lsm = np.asarray(logits, np.float64).reshape(-1, V)
    yf = y.reshape(-1)[:len(lsm)]
    m = yf > 0
    if not m.any():
        return float("nan")
    lk = lsm[m]
    yk = yf[m]
    mx = lk.max(1, keepdims=True)
    return float(np.mean(np.log(np.exp(lk - mx).sum(1)) + mx[:, 0]
                         - lk[np.arange(len(lk)), yk]))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", required=True)
    ap.add_argument("--tokens", default=None, help="分词缓存 npz")
    ap.add_argument("--mask-unk", action="store_true",
                    help="把 UNK(槽 0)位置从 loss 里去掉. V=2400 时有 8%% 的 token "
                         "是 UNK, 而 _ce 报告时已经掩掉了它们 —— backward 不掩就等于"
                         "让 8%% 的梯度去学\"预测 UNK\", 而生成时 UNK 是要跳过的. "
                         "开这个开关让训练口径与评估口径一致.")
    ap.add_argument("--loss-on-label", action="store_true",
                    help="只对'下一 token 是标签字符且其前一个 token 是 @'的位置算 loss. "
                         "标签位只占 0.43%% 位置时, 全位置平均会让模型只优化多数位置"
                         "(实测 4%% 密度->91.7%%, 0.47%% 密度->0.0%%)")
    ap.add_argument("--label-chars", default="IMDRAPTB")
    ap.add_argument("--save-every", type=int, default=0,
                    help="每 N 步存一次 checkpoint(0=只在结束时存). "
                         "手机内存紧, 进程被 OOM kill 时不至于全丢")
    ap.add_argument("--tokenize-only", action="store_true")
    ap.add_argument("--data-mode", default="a3", choices=["a3", "code"],
                    help="a3=指令+代码, code=仅代码 (分词时生效)")
    ap.add_argument("--tok-model",
                    default="/data/data/com.termux/files/home/models/qxt/"
                            "rStar-Coder-Qwen3-0.6B.Q8_0-Q4T_packslim.gguf")
    ap.add_argument("--steps", type=int, default=300)
    ap.add_argument("--lr", type=float, default=6e-3)
    ap.add_argument("--n_layer", type=int, default=4)
    ap.add_argument("--n_embd", type=int, default=64)
    ap.add_argument("--n_ff", type=int, default=192)
    ap.add_argument("--vocab", type=int, default=8000)
    ap.add_argument("--batch", type=int, default=8)
    ap.add_argument("--seq_len", type=int, default=64)
    ap.add_argument("--holdout", type=float, default=0.05)
    ap.add_argument("--clip", type=float, default=1.0)
    ap.add_argument("--limit", type=int, default=None)
    ap.add_argument("--eval-tok", type=int, default=8192,
                    help="留出评估的 token 数 (跨配方对比的可靠性下限)")
    ap.add_argument("--mode", default="fp32", choices=["fp32", "bitnet"],
                    help="bitnet = 训练时就约束 1-bit (权重 sign(.) + 逐块 scale)")
    ap.add_argument("--out", default=None)
    a = ap.parse_args()

    import qxn_train as T
    T.USE_GGML = os.environ.get("QXN_GGML","0") == "1"

    if a.tokenize_only:
        ids, _ = tokenize_file(a.data, a.tok_model, a.limit, a.data_mode)
        np.savez(a.tokens, ids=ids)
        print(f"[tok] {len(ids)/1e6:.2f}M tokens -> {a.tokens}")
        return

    if a.tokens and os.path.exists(a.tokens):
        ids = np.load(a.tokens)["ids"]
    else:
        ids, _ = tokenize_file(a.data, a.tok_model, a.limit, a.data_mode)
        if a.tokens:
            np.savez(a.tokens, ids=ids)
    ids, V, KEEP = compress_vocab(ids, a.vocab)
    # 注意: compress_vocab 返回的 ids 已经是**槽位**, 不能用 ids.max() 定长度;
    # LUT 是"原始 id -> 槽位", 要按 keep 的最大值开.
    LUT = np.zeros(int(KEEP.max()) + 2, np.int64)
    LUT[KEEP] = np.arange(1, KEEP.size + 1)
    n = len(ids)
    cut = int(n * (1 - a.holdout))
    tr, ho = ids[:cut], ids[cut:]
    print(f"[data] {n/1e6:.2f}M tokens  词表 {V}  训练 {len(tr)/1e6:.2f}M  "
          f"留出 {len(ho)/1e3:.0f}K")

    import qxn_train as _q
    m = _q.QxN(a.n_layer, a.n_embd, 4, a.n_ff, V, a.seq_len, mode=a.mode, seed=0)
    npar = sum(v.size for v in m.P.values())
    print(f"[model] mode={a.mode} L={a.n_layer} d={a.n_embd} ffn={a.n_ff} V={V} "
          f"params={npar/1e6:.2f}M  batch={a.batch}x{a.seq_len}")
    if a.mode == "bitnet":          # 统计权重是否真的只剩两档
        _u = set()
        for _k in m.P:
            if _k.split(".")[-1] in ("wq", "wk", "wv", "wo", "w1", "w2", "w3"):
                _u.add(float(np.abs(np.unique(m.P[_k])).max()))
        print(f"[1bit] 权重绝对值档位数 = {len(_u)} (潜变量存的是全精度, "
              f"前向时 sign 化)")

    rng = np.random.default_rng(0)
    t0 = time.time()
    PROG = max(1, a.steps // 40)   # 每 2.5% 打一次 CE/|g|/lr, 便于定位发散点
    def get(arr, bs):
        s0 = rng.integers(0, len(arr) - a.seq_len - 1, size=bs)
        i = s0[:, None] + np.arange(a.seq_len)[None]
        j = s0[:, None] + np.arange(1, a.seq_len + 1)[None]
        return arr[i], arr[j]
    lab_sel = None
    use_mask = bool(a.loss_on_label)
    mask_unk = bool(a.mask_unk)
    if use_mask:
        lab_slots = np.array([LUT[ord(c) + 1] for c in a.label_chars
                              if LUT[ord(c) + 1] != 0])
        at_slot = int(LUT[ord("@") + 1])
        print(f"[loss] 只在标签位算: {len(lab_slots)} 类 {a.label_chars} "
              f"@={at_slot}", flush=True)

    for step in range(a.steps):
        lr = a.lr * (step + 1) / 50 if step < 50 else \
            a.lr * 0.5 * (1 + math.cos(math.pi * (step - 50) / max(1, a.steps - 50)))
        x, y = get(tr, a.batch)
        logits, caches, xf, xl, oc = m.forward(x, collect=True)
        if not use_mask:
            loss = _ce(logits, y, V)
        else:
            lab_sel = label_mask(x, y, V, lab_slots, at_slot)
            if lab_sel.any():
                lsg = np.asarray(logits, np.float64)[lab_sel]
                tg = y[lab_sel]
                mx = lsg.max(-1, keepdims=True)
                loss = float(np.mean(np.log(np.exp(lsg - mx).sum(-1)) + mx[:, 0]
                                     - lsg[np.arange(len(tg)), tg]))
            else:
                loss = float("nan")
        if not use_mask and not mask_unk:
            G = m.backward(x, logits, caches, xf, xl, oc)
        else:
            if mask_unk and not use_mask:
                # dL/dlogits = (p - onehot) / 有效位置数, UNK 位置整行置 0
                lg64 = np.asarray(logits, np.float64)
                p = np.exp(lg64 - lg64.max(-1, keepdims=True))
                p /= p.sum(-1, keepdims=True)
                d = p.astype(np.float32).copy()
                _bi = np.arange(x.shape[0])[:, None]
                _ti = np.arange(x.shape[1] - 1)[None, :]
                d[_bi, _ti, x[:, 1:]] -= 1.0
                keep_pos = (y > 0)                 # y 已是压缩槽, 0 = UNK
                keep_pos[:, -1] = False
                d *= keep_pos[:, :, None]
                n = int(keep_pos.sum())
                if n:
                    d /= n
                G = m.backward(x, logits, caches, xf, xl, oc, dlogits=d)
            else:
                pr = np.asarray(logits, np.float64)
                pr = pr - pr.max(-1, keepdims=True)
                pr = np.exp(pr)
                pr /= pr.sum(-1, keepdims=True)
                d = np.zeros(pr.shape, np.float32)
                d[lab_sel] = -pr[lab_sel]        # 交叉熵梯度 = p - onehot
                n = int(lab_sel.sum())
                if n:
                    d /= n
                G = m.backward(x, logits, caches, xf, xl, oc, dlogits=d)
        gn = float(np.sqrt(sum(float((G[k] ** 2).sum()) for k in m.P if k in G)))
        sc = (a.clip / gn) if (a.clip > 0 and gn > a.clip) else 1.0
        for k in m.P:
            g = G.get(k)
            if g is None or g.shape != m.P[k].shape:
                continue
            g = g * sc
            m._m[k] = 0.9 * m._m[k] + 0.1 * g
            m._v[k] = 0.999 * m._v[k] + 0.001 * g * g
            mh = m._m[k] / (1 - 0.9 ** (step + 1))
            vh = m._v[k] / (1 - 0.999 ** (step + 1))
            if k not in ("embd", "posembd") and "norm" not in k.split(".")[-1]:
                m.P[k] -= lr * 0.01 * m.P[k]
            m.P[k] -= lr * mh / (np.sqrt(vh) + 1e-8)
        if (step + 1) % PROG == 0 or step == 0:
            e = time.time() - t0
            rate = (step + 1) / e
            if a.save_every and (step + 1) % a.save_every == 0:
                save_ckpt(m, _stem(a.out) + "_s%d.npz" % (step + 1), a.mode)
            print(f"  step {step+1:5d}/{a.steps}  CE {loss:7.3f}  "
                  f"|g| {gn:9.3f}  lr {lr:.2e}  "
                  f"{e:6.1f}s  ETA {(a.steps-step-1)/rate:6.1f}s", flush=True)
    el = time.time() - t0
    # 留出 CE。样本量必须足够: 之前用 16 条序列(=1024 token), 词表扫描里
    # V2400 vs V4000 的 CE 只差 0.03, 在 613 个非UNK token 上完全是噪声.
    # 现在按 --eval-tok 指定的 token 数采样(默认 8192), 保证不同配方可分辨.
    nb = max(16, a.eval_tok // a.seq_len)
    x, y = get(ho, nb)
    logits = m.forward(x, collect=True)[0]
    lsm = np.asarray(logits, np.float64).reshape(-1, V)
    yf = y.reshape(-1)[:len(lsm)]
    # 跨词表可比指标: 只在"被保留的真实 token"(非 UNK)上算 CE 与 top1 准确率。
    # 全词表 CE 会被 UNK 主导 —— V=800 时 64% token 是 UNK, 预测 UNK 就能拿低
    # CE, ppl 不可跨词表比较 (实测 V800 ppl8.39 vs V4000 ppl62.16 完全是这个假象).
    keep_mask = yf > 0
    nk = int(keep_mask.sum())
    mx = lsm.max(1, keepdims=True)
    lse = np.log(np.exp(lsm - mx).sum(1)) + mx[:, 0]
    ce = float(np.mean(lse - lsm[np.arange(len(lsm)), yf]))
    print(f"[done] {a.steps} 步 / {el:.1f}s = {el/a.steps*1000:.0f} ms/step  "
          f"({a.steps*a.batch*a.seq_len/el:.0f} tok/s)")
    if nk > 0:
        lsk = lsm[keep_mask]; yk = yf[keep_mask]
        mxk = lsk.max(1, keepdims=True)
        cek = float(np.mean(np.log(np.exp(lsk-mxk).sum(1)) + mxk[:, 0] -
                             lsk[np.arange(len(lsk)), yk]))
        acc = float(np.mean(lsk.argmax(1) == yk))
    else:
        cek, acc = float('nan'), 0.0
    print(f"[eval] 全词表 CE {ce:.4f} ppl {math.exp(ce):.2f} (基线 {V})")
    print(f"[eval] 保留token {nk} ({100*nk/len(yf):.1f}%)  CE {cek:.4f}  "
          f"ppl {math.exp(cek):.2f}  top1 {100*acc:.1f}%  <- 跨词表用这个")
    if a.out:
        save_ckpt(m, a.out, a.mode)


if __name__ == "__main__":
    main()