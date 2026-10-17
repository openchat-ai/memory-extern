"""§15.4 决定性实验: 1-bit 量化是否破坏了模型的自身校准?

若破坏 -> 独立置信度头有存在必要, 立论成立
若未破坏 -> 模型自带置信度已可用, 头不必做, 省下全部工作量

无论哪个结果都是有效结论 —— 这正是把"要不要做"变成可测量实验的意义.

用法: python3 tools/qxn_calib_compare.py ckpt_fp32.npz ckpt_bitnet.npz
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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("ckpts", nargs="+", help="每项为 mode=path")
    ap.add_argument("--teacher", default="teacher_06b_k64.npz")
    ap.add_argument("--n_layer", type=int, default=4)
    ap.add_argument("--n_embd", type=int, default=128)
    ap.add_argument("--n_ff", type=int, default=256)
    ap.add_argument("--vocab", type=int, default=151936)
    ap.add_argument("--seq_len", type=int, default=32)
    ap.add_argument("--n_win", type=int, default=60)
    ap.add_argument("--bins", type=int, default=15)
    args = ap.parse_args()

    data = TeacherData(args.teacher, holdout=0.2)
    print("[留出集] %d tokens (训练段 %d)" % (data.Nho, data.Ntr))

    res = {}
    for spec in args.ckpts:
        mode, path = spec.split("=", 1)
        if not os.path.exists(path):
            print("[跳过] %s 不存在" % path)
            continue
        m = load(path, args.n_layer, args.n_embd, args.n_ff, args.vocab,
                 args.seq_len, mode)
        conf, ok = eval_calibration(m, data, args.seq_len,
                                    args.n_win, bs=4)
        r = ece_mce(conf, ok, args.bins)
        res[mode] = (conf, ok, r)
        calib_report(conf, ok, args.bins,
                     title="%s  (checkpoint=%s, n=%d)" % (mode, path, r["n"]))

    if "fp32" in res and "bitnet" in res:
        cf, of, rf = res["fp32"]
        cb, ob, rb = res["bitnet"]
        print("\n" + "=" * 62)
        print("  结论: 1-bit 量化对校准度的影响")
        print("=" * 62)
        print("  %-10s %10s %10s %10s" % ("模型", "ECE", "MCE", "整体准确"))
        for name, (c, o, r) in res.items():
            print("  %-10s %10.4f %10.4f %9.2f%%" %
                  (name, r["ece"], r["mce"], 100 * o.mean()))
        print("  %-10s %10.4f %10.4f" %
              ("差距", rb["ece"] - rf["ece"], rb["mce"] - rf["mce"]))

        print("\n  选择性预测对比 (置信度门控的收益):")
        print("  %-10s %14s %14s" % ("保留比例", "fp32 准确", "1-bit 准确"))
        sf = dict((c, a) for c, k, a, t in selective_curve(cf, of))
        sb = dict((c, a) for c, k, a, t in selective_curve(cb, ob))
        for c in (0.5, 0.8, 0.9, 0.95, 0.99):
            print("  %-10.0f%% %13.2f%% %13.2f%%" %
                  (c * 100, 100 * sf[c], 100 * sb[c]))

        gap = rb["ece"] - rf["ece"]
        print()
        if gap > 0.02:
            print("  => 1-bit 显著破坏校准 (ECE 差距 %.4f)." % gap)
            print("     独立置信度头有存在必要, §15.3 设计成立.")
        elif gap > 0.005:
            print("  => 1-bit 轻微破坏校准 (ECE 差距 %.4f)." % gap)
            print("     置信度头收益有限, 建议先做选择性预测门控 (§15.3 推理侧),")
            print("     不必额外训练一个头.")
        else:
            print("  => 1-bit 基本未破坏校准 (ECE 差距 %.4f)." % gap)
            print("     模型自身置信度已可用, **不必训练置信度头**.")
            print("     直接用 max-prob 做门控即可, 零额外参数.")


if __name__ == "__main__":
    main()