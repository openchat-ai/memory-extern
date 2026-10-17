"""§15.3 置信度头: 验证 1-bit 的置信度塌缩能否被一个 (d+1) 参数的头修复.

问题 (§16.3): 1-bit 量化把输出分布压扁成近均匀 (94.2% 的置信度落在 0.10~0.15,
方差比 fp32 小 1566 倍), 于是"模型自身置信度"几乎没有判别力:
fp32 取 top50% 后准确率 +21.41, 1-bit 只有 +1.64.

方案: 在最终隐状态上挂一个标量头 score = h·w + b, 直接用"是否预测正确"
做二分类训练. 它与主输出头解耦, 因此即使主输出头已塌缩, 头仍可从隐状态里
恢复出"我这次有把握吗"的信号.

本脚本:
  1. 加载 fp32 / 1-bit 检查点
  2. 在**留出集**上训头 (训练段只用于主模型, 避免污染)
  3. 对比头给出的置信增益 vs 模型自身置信增益
  4. 报告 ECE 与选择性预测曲线
"""
import argparse
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import qxn_train as Q                                        # noqa: E402
from qxn_calib import calib_report, ece_mce, selective_curve  # noqa: E402
from qxn_distill_student import TeacherData, eval_calibration  # noqa: E402


def load(path, n_layer, n_embd, n_ff, vocab, seq_len, mode, seed=0):
    m = Q.QxN(n_layer, n_embd, 4, n_ff, vocab, seq_len, mode=mode, seed=seed)
    z = np.load(path)
    for k in m.P:
        if k in z:
            m.P[k] = z[k].astype(m.P[k].dtype)
    return m


def collect(m, data, seq_len, n_win, bs, holdout=True, seed=1234):
    """返回 (x_last (N,d), correct (N,), self_conf (N,))"""
    rng = np.random.default_rng(seed)
    X, C, S = [], [], []
    for _ in range(max(1, n_win // bs)):
        t = data.batch(bs, seq_len, rng, holdout=holdout)
        ti, tidx, tp, ttg = t
        lg = m.forward(ti, collect=False)
        B, S_, V = lg.shape
        z = lg.reshape(B * S_, V)
        z = z - z.max(1, keepdims=True)
        e = np.exp(z)
        p = e / e.sum(1, keepdims=True)
        j = p.argmax(1)
        conf = p[np.arange(p.shape[0]), j]
        correct = (j == ttg.reshape(B * S_))
        # 取最终隐状态
        _lg2, _c, _xf, xl, _oc = m.forward(ti, collect=True)
        X.append(xl.reshape(-1, xl.shape[-1]))
        C.append(correct)
        S.append(conf)
    return np.concatenate(X), np.concatenate(C), np.concatenate(S)


def _sig(z):
    """数值稳定的 sigmoid: 分段计算并钳位, 避免 exp 溢出."""
    z = np.clip(z, -30.0, 30.0)
    out = np.empty_like(z)
    pos = z >= 0
    out[pos] = 1.0 / (1.0 + np.exp(-z[pos]))
    ez = np.exp(z[~pos])
    out[~pos] = ez / (1.0 + ez)
    return out


def train_head(m, Xtr, Ctr, steps=1500, lr=0.5, l2=1e-4, seed=0):
    """在训练段上学 (w, b). 全批量 + Adam(逐元素尺度不变, 避免 lr 敏感)."""
    w = np.zeros(Xtr.shape[1], np.float32)
    b = np.float32(0.0)
    t = Ctr.astype(np.float32)
    mw = np.zeros_like(w); vw = np.zeros_like(w)
    mb = np.float32(0.0); vb = np.float32(0.0)
    for st in range(1, steps + 1):
        z = Xtr @ w + b
        p = _sig(z)
        g = (p - t) / len(t)                 # dL/dz (平均 BCE)
        gw = Xtr.T @ g + l2 * w
        gb = np.float32(g.sum())
        mw = 0.9 * mw + 0.1 * gw; vw = 0.999 * vw + 0.001 * gw * gw
        mb = 0.9 * mb + 0.1 * gb; vb = 0.999 * vb + 0.001 * gb * gb
        w -= lr * (mw / (1 - 0.9 ** st)) / (np.sqrt(vw / (1 - 0.999 ** st)) + 1e-8)
        b -= lr * (mb / (1 - 0.9 ** st)) / (np.sqrt(vb / (1 - 0.999 ** st)) + 1e-8)
    return w, b


def evaluate(w, b, X, C, tag, title):
    p = _sig(X @ w + b)
    r = calib_report(p, C, 15, title=title)
    return p, r


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("ckpts", nargs="+")
    ap.add_argument("--teacher", default="teacher_06b_k64.npz")
    ap.add_argument("--n_layer", type=int, default=4)
    ap.add_argument("--n_embd", type=int, default=192)
    ap.add_argument("--n_ff", type=int, default=384)
    ap.add_argument("--vocab", type=int, default=18540)
    ap.add_argument("--seq_len", type=int, default=64)
    ap.add_argument("--steps", type=int, default=1500)
    ap.add_argument("--lr", type=float, default=0.5)
    ap.add_argument("--train_win", type=int, default=120)
    ap.add_argument("--test_win", type=int, default=60)
    args = ap.parse_args()

    data = TeacherData(args.teacher, holdout=0.2, compress=True)
    print("[数据] 训练段 %d tok / 留出段 %d tok" % (data.Ntr, data.Nho))

    base_self, results = {}, {}
    for spec in args.ckpts:
        mode, path = spec.split("=", 1)
        if not os.path.exists(path):
            print("[跳过] %s" % path)
            continue
        m = load(path, args.n_layer, args.n_embd, args.n_ff, args.vocab,
                 args.seq_len, mode)
        # 头在**训练段**上训练(主模型见过这些数据), 在**留出段**上评估
        Xtr, Ctr, _ = collect(m, data, args.seq_len, args.train_win, 4,
                              holdout=False)
        Xte, Cte, Ste = collect(m, data, args.seq_len, args.test_win, 4,
                                holdout=True)
        print("\n[%s] 头训练集 %d / 测试集 %d  (正样本率 %.3f)" %
              (mode, len(Xtr), len(Xte), Ctr.mean()))

        w, b = train_head(m, Xtr, Ctr, steps=args.steps, lr=args.lr)

        # 模型自身置信度(基线)
        self_ece = ece_mce(Ste, Cte)["ece"]
        self_top50 = [a for cv, k, a, t in selective_curve(Ste, Cte) if cv == 0.5][0]
        base_self[mode] = (self_ece, 100 * (self_top50 - Cte.mean()))
        print("  模型自身置信:  ECE %.4f   top50%% 增益 %+.2f 个点" %
              (self_ece, 100 * (self_top50 - Cte.mean())))

        # 置信度头
        p, r = evaluate(w, b, Xte, Cte, mode,
                        "%s  + 置信度头" % mode)
        head_top50 = [a for cv, k, a, t in selective_curve(p, Cte) if cv == 0.5][0]
        results[mode] = (r["ece"], 100 * (head_top50 - Cte.mean()))
        print("  置信度头    :  ECE %.4f   top50%% 增益 %+.2f 个点" %
              (r["ece"], 100 * (head_top50 - Cte.mean())))
        np.savez("confhead_%s.npz" % mode, w=w, b=b)

    print("\n" + "=" * 66)
    print("  §15.3 结论: 置信度头能否恢复 1-bit 的判别力")
    print("=" * 66)
    print("  %-10s %-22s %-22s" % ("模型", "自身 ECE / top50增益", "头 ECE / top50增益"))
    for mode in results:
        if mode in base_self:
            se, sg = base_self[mode]
            he, hg = results[mode]
            print("  %-10s %6.4f / %+8.2f      %6.4f / %+8.2f" %
                  (mode, se, sg, he, hg))
    if "bitnet" in results and "fp32" in results:
        bh = results["bitnet"][1]
        bs_ = base_self["bitnet"][1]
        print()
        print("  1-bit 置信增益: 自身 %+.2f -> 头 %+.2f  (恢复 %.1f%%)" %
              (bs_, bh, 0 if abs(bs_) < 1e-9 else 100 * (bh - bs_) / abs(bs_)))
        if bh > 5.0:
            print("  => 头**恢复了**判别力, §15.3 设计成立: 塌缩发生在输出头,")
            print("     隐状态里仍保留可用的信心信号.")
        else:
            print("  => 头**未能**显著恢复判别力. 说明塌缩已传导到隐状态,")
            print("     1-bit 模型的'自知'能力被更根本地破坏.")


if __name__ == "__main__":
    main()