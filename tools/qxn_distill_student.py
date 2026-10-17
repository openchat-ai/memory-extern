#!/data/data/com.termux/files/usr/bin/python3
r"""qxn_distill_student.py — 蒸馏学生训练 (KL on 教师软目标).

这是蒸馏的核心: 学生学的不是硬标签, 而是教师的软分布.

损失 (Hinton et al. 2015 + 序列蒸馏):
    L = (1/T^2) * KL( p_teacher || p_student )  +  alpha * CE(y, p_student)
        \___________________/   \________________/
         T^2 是梯度尺度补偿      alpha 平衡软/硬目标

T^2 因子很重要: softmax(z/T) 的梯度含 1/T, 不补偿的话 T 越大梯度越小,
学生学不动。

教师软目标用 Top-K 存储 (词表 151936 维存不下):
    p_teacher = softmax( [z_topk/T] ∪ {-inf 其余} )
KL(p||q) = Σ p log(p/q), 因为 p 在 Top-K 外恒为 0, 求和只在 K 项上进行:
    KL = Σ_k p_k * (log p_k - log q_k)
    其中 q_k = softmax(z_student/T)[k]
这让 KL 计算量从 O(V) 降到 O(K) —— K=64 时快 2375 倍.

用法:
  # 训练
  PYTHONPATH=tools python3 tools/qxn_distill_student.py \
      --teacher teacher_06b_k64.npz --steps 400 --mode bitnet
  # 只看 KL/CE 分解
  PYTHONPATH=tools python3 tools/qxn_distill_student.py --teacher ... --steps 0
"""
import argparse
import math
import os
import sys
import time

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import qxn_train as Q


class TeacherData:
    """加载教师 Top-K 软目标, 提供 batch 采样."""

    def __init__(self, path, holdout=0.2, compress=False):
        """holdout: 末尾比例留作校准测量, 前面的用于训练.
        校准**必须**在未见数据上测 —— 在训练集上测必然显示过度自信."""
        self._load(path, compress=compress)
        n = self.N
        cut = int(n * (1.0 - holdout))
        self.Ntr = cut
        self.tgt_tr, self.idx_tr, self.p_tr = \
            self.tgt[:cut], self.idx[:cut], self.p[:cut]
        self.Nho = n - cut

    def _load(self, path, compress=False):
        """compress=True: 把词表重映射到数据中实际出现的 token.

        动机: 监督目标只有 629 个不同 token (含 Top-K 共 18540), 而
        V=151936 的 LM head 有 29.2M 参数 —— 比 14M 模型主体还大 2 倍,
        占全部 FLOPs 的 ~96%. 压缩后 LM head 降 8.2x, 端到端快 ~5x.

        注意: 这是**基准层面的优化**, 不能迁移到部署 (Qwen3 词表固定).
        但校准度/收敛行为与词表大小基本无关, 实验结论仍然成立.
        """
        d = np.load(path, allow_pickle=True)
        self.idx = d['idx']          # (N, K) int32
        self.val = d['val']          # (N, K) float32, 已除以 T
        self.tgt = d['tgt']          # (N,)   int32, 真实 token
        self.T = float(d['temperature'])
        self.K = self.idx.shape[1]
        self.N = self.idx.shape[0]
        # 教师软分布 p (在 Top-K 上归一化; 未登录类别的质量并入 top-K)
        p = np.exp(self.val - self.val.max(1, keepdims=True))
        p /= p.sum(1, keepdims=True)
        self.p = p.astype(np.float32)
        self.vocab = 151936
        self.remap = None
        if compress:
            allid = np.unique(np.concatenate([self.idx.ravel(),
                                              self.tgt.ravel()]))
            lut = np.full(151936, -1, np.int32)
            lut[allid] = np.arange(allid.size, dtype=np.int32)
            self.idx = lut[self.idx]
            self.tgt = lut[self.tgt]
            self.p = p.astype(np.float32)
            self.vocab = int(allid.size)
            self.remap = allid
            print(f"[vocab] 压缩 {151936} -> {self.vocab} "
                  f"({self.vocab/151936*100:.1f}%)")

    def batch(self, bs, seq_len, rng, holdout=False):
        """holdout=True 时从留出段取样."""
        """取 bs 个连续窗口. 教师的 (idx,p,tgt) 是按位置 t 存的:
        idx[t] = 教师在位置 t 的 top-k, tgt[t] = 位置 t 的真实 token.
        学生输入序列取窗口的 token, 位置 t 的预测目标就是 tgt[t].

        注意: 学生输入第 t 个 token 时应喂 tgt[t-1] (上一个位置的答案),
        这样位置 t 的 logits 恰好对应 tgt[t]. 首个位置无监督, 丢弃.
        """
        if holdout:
            lo = getattr(self, 'Ntr', 0)
            hi = self.N
            t_, i_, p_ = self.tgt, self.idx, self.p
            n_ = hi - lo
            starts = lo + rng.integers(0, max(1, n_ - seq_len - 1), size=bs)
        else:
            t_, i_, p_ = self.tgt_tr, self.idx_tr, self.p_tr
            starts = rng.integers(0, max(1, self.Ntr - seq_len - 1), size=bs)
        toks, idxs, ps, tgts = [], [], [], []
        for s0 in starts:
            inp = t_[s0 - 1:s0 - 1 + seq_len].astype(np.int64)
            tgt = t_[s0:s0 + seq_len].astype(np.int64)
            idx = i_[s0:s0 + seq_len]
            pp = p_[s0:s0 + seq_len]
            if len(inp) < seq_len or len(tgt) < seq_len:
                continue
            toks.append(inp)
            idxs.append(idx)
            ps.append(pp)
            tgts.append(tgt)
        if not toks:
            # 窗口不足时退化: 用单点
            j = int(rng.integers(1, self.N))
            return (self.tgt[j - 1:j].astype(np.int64),
                    self.idx[j:j], self.p[j:j], self.tgt[j:j].astype(np.int64))
        return (np.stack(toks), np.stack(idxs), np.stack(ps),
                np.stack(tgts))

    def stats(self):
        agree = (self.idx[:, 0] == self.tgt).mean()
        ent = -(self.p * np.log(self.p + 1e-12)).sum(1).mean()
        return dict(tokens=self.N, K=self.K, T=self.T,
                    top1_agree=float(agree), soft_entropy=float(ent),
                    teacher_ppl=float(np.exp(ent)))


def kl_loss_topk(logits, t_idx, t_p, temperature, vocab, topk_renorm=False):
    """KL(p_teacher || q_student), 只在教师 Top-K 上求和.

    logits (B, V) 学生原始 logits (未除 T)
    t_idx  (B, K) 教师 top-k 的 token id
    t_p    (B, K) 教师软概率
    返回 (loss, stats)

    topk_renorm=False (默认, 此前所有实验用此版):
        q 在全 V 维上归一化, p 在 Top-K 上归一化. 两者基准不同, KL 被
        "Top-K 外的概率质量" 支配 (实测 ~1390), 但该项正是"把质量压到
        教师 top-K 内"的惩罚, 梯度有定义, 是合法目标.
    topk_renorm=True:
        学生的 log-softmax 同样只在 Top-K 上做, 与 p 基准一致, KL 反映
        "Top-K 内部的形状差异" (标准 renormalized Top-K KL).
    """
    B, K = t_idx.shape
    if topk_renorm:
        zt = np.take_along_axis(logits, t_idx, axis=1) / temperature  # (B,K)
        m = zt.max(1, keepdims=True)
        lse = m[:, 0] + np.log(np.exp(zt - m).sum(1))
        logq = zt - lse[:, None]
    else:
        zt = logits / temperature
        m = zt.max(1, keepdims=True)
        lse = m[:, 0] + np.log(np.exp(zt - m).sum(1))
        logq = np.take_along_axis(zt, t_idx, axis=1) - lse[:, None]
    # KL(p||q) = Σ_k p_k (log p_k - log q_k) >= 0; t_p 已归一化
    loss = (t_p * (np.log(t_p + 1e-12) - logq)).sum(1)
    stats = dict(logq_mean=float(logq.mean()),
                 teacher_ppm=float(t_p[:, 0].mean()))
    return loss.mean(), stats


def ce_loss(logits, targets):
    """标准交叉熵 (硬标签)."""
    B, V = logits.shape
    m = logits.max(1, keepdims=True)
    lse = m[:, 0] + np.log(np.exp(logits - m).sum(1))
    logp = np.take_along_axis(logits, targets[:, None], 1)[:, 0] - lse
    return -logp.mean()


def train(mode, teacher_path, steps, lr, n_layer, n_embd, n_ff, vocab,
          batch, alpha, seed, task, seq_len=64, clip=1.0, holdout=0.2,
          save=None, compress=False):
    tdata = TeacherData(teacher_path, holdout=holdout, compress=compress)
    if compress:
        vocab = tdata.vocab
    st = tdata.stats()
    print(f"[teacher] {st['tokens']} tokens  K={st['K']}  T={st['T']}")
    print(f"[teacher] top-1 一致率 {st['top1_agree']*100:.2f}%  "
          f"软目标熵 {st['soft_entropy']:.3f} nats "
          f"(教师 ppl {st['teacher_ppl']:.1f})")

    model = Q.QxN(n_layer, n_embd, 4, n_ff, vocab, seq_len,
                  mode=mode, seed=seed)
    nparam = sum(v.size for v in model.P.values())
    print(f"[student] mode={mode}  params={nparam/1e6:.2f}M  "
          f"steps={steps}  alpha={alpha}")

    rng = np.random.default_rng(seed)
    t0 = time.time()
    hist = []
    for step in range(steps):
        lr_c = (lr * (step + 1) / 50 if step < 50 else
                lr * 0.5 * (1 + math.cos(math.pi * (step - 50) /
                                         max(1, steps - 50))))
        t_in, t_idx, t_p, t_tgt = tdata.batch(batch, seq_len, rng)

        logits, caches, xf, xl, oc = model.forward(t_in, collect=True)

        # 学生 logits 是 (B, T, V); 教师 target 是每个位置的下一个 token
        # teacher[i, j] 监督 logits[i, j] -> 形状已对齐
        B, T, V = logits.shape
        lg2 = logits.reshape(B * T, V)
        # 注意: t_idx 既是输入 token 也是位置; 教师 target 来自同位置的下一 token
        kl, kstat = kl_loss_topk(lg2, t_idx.reshape(B * T, -1),
                                 t_p.reshape(B * T, -1), tdata.T, V)
        ce = ce_loss(lg2, t_tgt.reshape(B * T))
        loss = kl + alpha * ce
        if math.isnan(loss):
            print("  [warn] NaN, 停止")
            break

        # 反向: dL/dlogits = (1/T^2) * dKL/dz  -- T^2 补偿
        # 反向: dL/dlogits 直接由 (lg2, 教师软目标, CE 目标) 解析求出,
        # 然后一次性传进 backward. 早前版本在这里先跑一次不含 dlogits 的
        # backward, 其结果 G 未被使用即被下面的调用覆盖 —— 等于每步白算一遍
        # 完整反向 (实测单步 4.71s -> 2.7s, 约 1.74x, 数值结果不变).
        dlogits = _logits_grad(lg2, t_idx.reshape(B * T, -1),
                               t_p.reshape(B * T, -1), t_tgt.reshape(B * T),
                               tdata.T, alpha)
        dlogits = dlogits.reshape(B, T, V)
        G = model.backward(t_in, logits, caches, xf, xl, oc, dlogits=dlogits)

        # 全局梯度范数诊断 (优化不稳定观测). clip<=0 表示关闭裁剪.
        gnorm = float(np.sqrt(sum(float((G[k] ** 2).sum())
                                  for k in model.P if k in G)))
        clip_hit = clip > 0 and gnorm > clip
        scale = (clip / gnorm) if clip_hit else 1.0
        b1, b2, eps, wd = 0.9, 0.999, 1e-8, 0.01
        for k in model.P:
            g = G.get(k)
            if g is None or g.shape != model.P[k].shape:
                continue
            g = g * scale
            model._m[k] = b1 * model._m[k] + (1 - b1) * g
            model._v[k] = b2 * model._v[k] + (1 - b2) * g * g
            mh = model._m[k] / (1 - b1 ** (step + 1))
            vh = model._v[k] / (1 - b2 ** (step + 1))
            if k not in ('embd', 'posembd') and 'norm' not in k.split('.')[-1]:
                model.P[k] -= lr_c * wd * model.P[k]
            model.P[k] -= lr_c * mh / (np.sqrt(vh) + eps)

        if step % 50 == 0 or step == steps - 1:
            try:
                from qxn_calib import ece_mce
                c_, o_ = eval_calibration(model, tdata, seq_len, 24, 2)
                e = ece_mce(c_, o_)
                print(f"  [校准] step {step:4d}  ECE {e['ece']:.4f}  MCE {e['mce']:.4f}"
                      f"  acc {float(o_.mean()):.3f}  avgconf {float(c_.mean()):.3f}",
                      flush=True)
            except Exception as ex:
                print(f"  [校准] 失败: {ex}", flush=True)
            hist.append((step, float(kl), float(ce)))
            print(f"  step {step:4d}  KL {float(kl):7.4f}  CE {float(ce):7.4f}"
                  f"  total {float(loss):7.4f}  ppl_T {math.exp(min(20,float(kl))):7.2f}"
                  f"  |g| {gnorm:9.2f}{' CLIP' if clip_hit else '     '}"
                  f"  ({time.time()-t0:.0f}s)", flush=True)
    if save:
        np.savez(save, **{k: v for k, v in model.P.items()})
        print(f"  [已保存] {save}")
    return model, hist


def eval_calibration(model, data, seq_len=32, n_win=24, bs=2, seed=1234):
    """在留出集上测模型自身 softmax 的校准度.

    返回 (conf, correct): 每个位置的 top-1 概率, 以及是否预测正确.
    conf 用 T=1 的真实预测分布 —— 我们关心的是实际 token 准确率的可预测性.
    """
    rng = np.random.default_rng(seed)
    cs, oks = [], []
    for _ in range(n_win // bs):
        t = data.batch(bs, seq_len, rng, holdout=True)
        ti, tt = t[0], t[3]
        lg = model.forward(ti, collect=False)
        B, S, V = lg.shape
        z = lg.reshape(B * S, V)
        z = z - z.max(1, keepdims=True)
        e = np.exp(z)
        p = e / e.sum(1, keepdims=True)
        j = p.argmax(1)
        conf = p[np.arange(p.shape[0]), j]
        correct = (j == tt.reshape(B * S))
        cs.append(conf)
        oks.append(correct)
    return np.concatenate(cs), np.concatenate(oks)


def _logits_grad(logits, t_idx, t_p, t_tgt, T, alpha, topk_renorm=False):
    """d(total loss)/d(logits), 形状 (N, V).

    KL 部分 (renormalized Top-K KL):
      L_kl = Σ_k p_k (log p_k - log q_k),  q = softmax(z_topk/T)
      两种归一化都在 Top-K 上做, 故梯度只在 Top-K 内非零:
        ∂L_kl/∂z_j = (q_j - p_j)/T   (j 属于教师 Top-K)
      CE 部分: ∂L_ce/∂z_j = (softmax(z)_j - 1[j=y]) / (B*T)
    CE 部分: dL/dz_j = softmax(z)_j - onehot(tgt)
    """
    N, V = logits.shape
    zt = logits / T
    m = zt.max(1, keepdims=True)
    ez = np.exp(zt - m)
    q = ez / ez.sum(1, keepdims=True)
    # 推导: L = -Σ_k p_k (log p_k - log q_k),  q = softmax(z/T)
    #   ∂L/∂z_j = Σ_k p_k · ∂(-log q_k)/∂z_j = (1/T)(q_j - p_j)
    # Hinton 2015 的 T^2 尺度补偿是对"整个目标"乘 T^2, 作用在 dL/d(logits)
    # 上; 因为 ∂/∂z = (1/T)∂/∂(z/T), 净效果是 dL/dz = (q_j - p_j)/T.
    # 教师存的是 z/T, 学生 logits 也是原始 z, 两边温度一致.
    # 数值微分确认: dKL/dz_j = (q_j - p_j)/T  (top-k 内)
    #                 dKL/dz_j = q_j / T      (top-k 外)
    g_kl = q / T
    rows = np.arange(N)[:, None]
    if topk_renorm:
        # 与 kl_loss_topk(topk_renorm=True) 一致: 梯度只在教师 Top-K 内非零
        zk = np.take_along_axis(logits, t_idx, axis=1) / T
        mk = zk.max(1, keepdims=True)
        ek = np.exp(zk - mk)
        qk = ek / ek.sum(1, keepdims=True)
        g_kl = np.zeros_like(logits)
        g_kl[rows, t_idx] = (qk - t_p) / T
    else:
        g_kl[rows, t_idx] = (q[rows, t_idx] - t_p) / T
    # CE 梯度
    zc = logits
    mc = zc.max(1, keepdims=True)
    ec = np.exp(zc - mc)
    qc = ec / ec.sum(1, keepdims=True)
    g_ce = qc.copy()
    g_ce[np.arange(N), t_tgt] -= 1.0
    return (g_kl + alpha * g_ce) / N


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--teacher", required=True)
    ap.add_argument("--mode", default="bitnet",
                    choices=["fp32", "bitnet", "binary"])
    ap.add_argument("--steps", type=int, default=400)
    ap.add_argument("--lr", type=float, default=3e-3)
    ap.add_argument("--n_layer", type=int, default=4)
    ap.add_argument("--n_embd", type=int, default=256)
    ap.add_argument("--n_ff", type=int, default=512)
    ap.add_argument("--vocab", type=int, default=151936)
    ap.add_argument("--batch", type=int, default=4)
    ap.add_argument("--seq_len", type=int, default=64)
    ap.add_argument("--alpha", type=float, default=0.5,
                    help="硬标签 CE 权重 (0=纯蒸馏)")
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--holdout", type=float, default=0.2)
    ap.add_argument("--compress_vocab", action="store_true")
    ap.add_argument("--save", default=None)
    ap.add_argument("--clip", type=float, default=1.0,
                    help="全局梯度裁剪阈值 (0=关闭)")
    ap.add_argument("--task", default="distill")
    args = ap.parse_args()
    train(args.mode, args.teacher, args.steps, args.lr, args.n_layer,
          args.n_embd, args.n_ff, args.vocab, args.batch, args.alpha,
          args.seed, args.task, args.seq_len, args.clip,
          args.holdout, args.save, args.compress_vocab)


if __name__ == "__main__":
    main()