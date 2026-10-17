"""校准度测量: 判定 1-bit 学生的自身置信度是否可用 (§15.4 的决定性实验).

核心问题: 模型的自身 softmax 已经是置信度了, 为什么还要单独训练一个置信度头?
只有当 1-bit 量化破坏了校准时, 头才有存在必要.

指标:
  ECE        Expected Calibration Error, 分箱后 Σ (n_b/N)|acc_b - conf_b|
  MCE        最大单箱校准误差 (比 ECE 更敏感)
  选择性预测  selective prediction: 按置信度只保留 top-k% 的预测时,
             保留部分的准确率是多少 —— 这正是置信度门控的实际收益

用法:
  from qxn_calib import calib_report
  r = calib_report(conf, correct, n_bins=15)
"""
import numpy as np


def ece_mce(conf, correct, n_bins=15):
    """conf: (N,) 预测为 top-1 的概率; correct: (N,) bool 是否预测正确."""
    conf = np.asarray(conf, np.float64)
    correct = np.asarray(correct, np.float64)
    n = conf.size
    if n == 0:
        return dict(ece=0.0, mce=0.0, bins=[])
    edges = np.linspace(0.0, 1.0, n_bins + 1)
    # 右闭区间分箱, 保证 1.0 落入最后一箱
    idx = np.clip(np.digitize(conf, edges[1:-1], right=False), 0, n_bins - 1)
    ece = 0.0
    mce = 0.0
    bins = []
    for b in range(n_bins):
        m = idx == b
        nb = int(m.sum())
        if nb == 0:
            bins.append((b, 0, float("nan"), float("nan")))
            continue
        cb = conf[m].mean()
        ab = correct[m].mean()
        gap = abs(ab - cb)
        ece += nb / n * gap
        mce = max(mce, gap)
        bins.append((b, nb, float(cb), float(ab)))
    return dict(ece=float(ece), mce=float(mce), bins=bins, n=n)


def selective_curve(conf, correct, coverages=(0.5, 0.8, 0.9, 0.95, 0.99)):
    """按置信度从高到低保留 top-c 比例的预测, 返回保留部分的准确率.

    这是置信度门控的直接收益: 若 conf 高时不保留低置信度的那些,
    剩余输出的准确率能提升多少.
    """
    conf = np.asarray(conf, np.float64)
    correct = np.asarray(correct, np.float64)
    order = np.argsort(-conf)
    out = []
    for c in coverages:
        k = max(1, int(round(c * conf.size)))
        sel = order[:k]
        out.append((c, k, float(correct[sel].mean()),
                    float(conf[sel].min())))
    return out


def calib_report(conf, correct, n_bins=15, title=""):
    r = ece_mce(conf, correct, n_bins)
    print(f"\n{'='*62}")
    if title:
        print(f"  {title}")
    print(f"{'='*62}")
    print("  %-6s %8s %10s %10s %8s" % ("箱", "样本", "平均置信", "实际准确", "偏差"))
    for b, nb, cb, ab in r["bins"]:
        if nb == 0:
            continue
        print("  %-6d %8d %10.4f %10.4f %8.4f" % (b, nb, cb, ab, cb - ab))
    print("-" * 62)
    print("  ECE = %.4f   MCE = %.4f   n = %d" % (r["ece"], r["mce"], r["n"]))
    print()
    print("  选择性预测 (置信度门控的直接收益):")
    print("  %-10s %10s %12s %12s" % ("保留比例", "样本", "保留部分准确", "置信度门槛"))
    for c, k, acc, thr in selective_curve(conf, correct):
        print("  %-10.0f%% %10d %11.2f%% %12.4f" % (c * 100, k, acc * 100, thr))
    return r


def calibration_gap_to_fp32(bitnet_conf, bitnet_ok, fp32_conf, fp32_ok):
    """对比 1-bit 与 fp32 的校准差距 —— 差距越大, 置信度头的价值越高."""
    a = ece_mce(bitnet_conf, bitnet_ok)
    b = ece_mce(fp32_conf, fp32_ok)
    return dict(
        bitnet_ece=a["ece"], fp32_ece=b["ece"],
        ece_gap=a["ece"] - b["ece"],
        bitnet_mce=a["mce"], fp32_mce=b["mce"],
        mce_gap=a["mce"] - b["mce"],
    )


if __name__ == "__main__":
    rng = np.random.default_rng(0)
    # 构造三种典型情形做自检
    print("自检: 完全校准 (ECE 应≈0)")
    p = rng.uniform(0.1, 0.99, 40000)
    calib_report(p, rng.uniform(size=40000) < p, title="完美校准")

    print("\n自检: 过度自信 (模型说 0.9 实际只有 0.6)")
    q = np.clip(rng.beta(6, 2, 40000), 0, 1)
    calib_report(q, rng.uniform(size=40000) < q * 0.6,
                 title="过度自信 (期望 ECE≈0.15)")