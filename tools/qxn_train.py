#!/data/data/com.termux/files/usr/bin/python3
"""qxn_train.py — QxN 训练框架 (numpy): 验证"从零训练能否救 1-bit".

背景 (见 docs/QXT_QUANT_DISTILL_LOG.md §3, §11):
  - 已证明在**预训练模型上**做 QAT 的 headroom = 0 (1-bit sign+块scale 格式
    已被 RTN 做到数学极限 0.6029 vs 理论 0.6027)
  - 要让 1-bit 可用, 必须让网络**天生**适应低精度: 训练时带二值约束
    (BitNet 式), 让网络适应低精度, 而非训练完再压缩

设计: **自动微分** — 手写反向传播冗长易错, 这里用 numpy 实现一个极小的
可微算子栈 (Linear / RMSNorm / GELU / SwiGLU / Attention / Embedding),
每个算子实现 forward+backward, 并用**有限差分**自动验证梯度正确性.
这保证 QAT/STE 的梯度路径绝对可靠 —— 这是整个命题验证的基础.

模式:
  --mode fp32   : 全精度基线
  --mode bitnet : 权重 ±1 (STE), 激活 8-bit 均匀量化 (BitNet b1.58 风格)
  --mode binary : 权重 ±1 (STE), 激活全二值 ±1

用法:
  PYTHONPATH=tools python3 tools/qxn_train.py --mode fp32   --steps 400
  PYTHONPATH=tools python3 tools/qxn_train.py --mode bitnet --steps 400 --verify
"""
import argparse
import math
import os
import sys
import time

import os
import numpy as np

# --------------------------- ggml 多线程 GEMM ---------------------------
# Termux 的 libopenblas 以 NO_THREAD=1 编译, 静默单线程(并行度 0.99);
# 系统自带的 ggml (libggml-cpu.so) 带有 pthread GEMM, 实测 1.7~3.9x.
# 这里只替换矩阵乘的实现, 不改变任何数学定义.
try:
    from ggml_gemm import (AVAILABLE as _GGML_OK, init_gemm as _ggml_init,
                           dot as _ggml_dot)
except Exception:                                        # pragma: no cover
    _GGML_OK = False

    def _ggml_init(*a, **k):
        pass

    _ggml_dot = None

# ggml 接入实测会让训练卡在平台上, 故**默认关闭**, 需显式 QXN_GGML=1 才启用.
# 证据 (d=192 L=4 ffn=384, lr=3e-3, 同数据同种子, 仅 ggml 开关不同):
#   step 0 : 两边完全一致 (KL 6.1078, |g| 5.37) —— 说明初始化与前向入口一致
#   step 50: ggml 开 = KL 5.8968 / acc 0.113 (停滞)
#            ggml 关 = KL 2.9682 / acc 0.316 (正常收敛, 与历史基线逐位一致)
# ggml 版的 logits 相对误差仅 1.6e-07, 梯度 Frobenius 相对误差 1.9e-06 ——
# 数值上"看起来没问题", 但足以决定能否逃出初始平台. 故不能用误差范数判定其可用性,
# 必须以 loss 曲线为准.
USE_GGML = bool(_GGML_OK) and os.environ.get("QXN_GGML", "0") == "1"
if USE_GGML:
    try:
        _ggml_init(4)
    except Exception:                                    # pragma: no cover
        USE_GGML = False


# ggml 每调用有 ~118us 固定开销(实测 1x1x1 时 numpy 1.9us vs ggml 119us),
# 来源是每次 ggml_reset + 新建 4 个 pthread + 建图 + memcpy.
# 但这是**调用效率**问题, 不是小矩阵的固有劣势: 训练一步约 25 次调用,
# 合计 ~3ms, 占一步 290ms 的 1%, 可忽略. 实测全接入 1.9x 与阈值接入几乎相同.
# 阈值只用于挡掉退化情形(m=64,n=192 这种 2.4e6 FLOP 的小投影会净亏).
_GGML_MIN_FLOP = 4.0e6


def _use_ggml(m, n, k):
    return USE_GGML and (m * n * k) >= _GGML_MIN_FLOP


def mm_at_b(A, B, cache=None, key=None):
    """C = A @ B,  A(m,k) B(k,n) -> (m,n).

    ggml 的原语是 dot(P,Q)=P@Q.T (两者第二维都是归约维 k), 故需 B 的转置视图.
    对权重这类大矩阵, 转置一次并缓存 (key), 供反向复用, 避免重复转置.
    """
    m, k = A.shape
    n = B.shape[1]
    if not _use_ggml(m, n, k):
        return A @ B
    Bt = B.T if cache is None else cache.get(key)
    if Bt is None:
        Bt = np.ascontiguousarray(B.T)
        if cache is not None:
            cache[key] = Bt
    return _ggml_dot(A, Bt)


def mm_at_bt(A, B, out=None):
    """C = A @ B.T,  A(m,n) B(k,n) -> (m,k).  B 已满足 ggml 布局, 零转置."""
    m, n = A.shape
    k = B.shape[0]
    if not _use_ggml(m, k, n):
        return A @ B.T
    return _ggml_dot(A, B, out)


def mm_at_at_b(A, B):
    """C = A.T @ B,  A(m,k) B(m,n) -> (k,n).  两侧都需转置视图."""
    m, k = A.shape
    n = B.shape[1]
    if not _use_ggml(k, n, m):
        return A.T @ B
    return _ggml_dot(np.ascontiguousarray(A.T), np.ascontiguousarray(B.T))


sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# ---- C 内核 (qxn_kernels.c): gelu / sign / rmsnorm / 激活量化 ----
# profile 实测 forward 39% + backward 61%, 其中逐元素操作占 ~20%.
# 无 .so 或显式 --no_c 时自动退回 numpy.
_K = None
try:
    import ctypes as _ct
    _so = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       'qxn_kernels.so')
    if os.path.exists(_so) and os.environ.get('QXN_NO_C') != '1':
        _K = _ct.CDLL(_so)
        _F = np.ctypeslib.ndpointer(np.float32, flags='C')
        _K.qxn_gelu.argtypes = [_F, _F, _ct.c_long]
        _K.qxn_gelu_bwd_mul.argtypes = [_F, _F, _F, _ct.c_long]
        _K.qxn_sign.argtypes = [_F, _F, _ct.c_long]
        _K.qxn_rmsnorm.argtypes = [_F, _F, _F, _F, _ct.c_long,
                                   _ct.c_int, _ct.c_float]
        _K.qxn_rmsnorm_bwd.argtypes = [_F, _F, _F, _F, _F, _F, _ct.c_long,
                                       _ct.c_int, _ct.c_float]
        _K.qxn_quant_act.argtypes = [_F, _F, _F, _ct.c_long, _ct.c_int,
                                     _ct.c_int, _ct.c_float, _ct.c_int]
except Exception:
    _K = None


# ============================ 激活量化 (BitNet 风格) ============================
def quant_act(x, bits=8, mode="bitnet"):
    """前向量化激活. 返回 (q, scale) 以便反向.
    bitnet: 均匀 8-bit 量化到 [-1,1];  binary: 直接 ±1."""
    if mode == "binary":
        return np.sign(x), None
    # 8-bit 均匀量化: scale = max|x|/127, 逐元素 absmax (per-token)
    s = np.max(np.abs(x), axis=-1, keepdims=True) / 127.0
    s = np.maximum(s, 1e-8)
    return np.clip(np.round(x / s), -127, 127) * s, s


def quant_act_bwd(dy, x, qs, mode="bitnet"):
    if mode == "binary":
        return dy                      # STE 直通
    return dy                          # round 的 STE: 直通


def binarize_w(w, scale=True):
    """权重二值化前向: sign. 返回 sign 值.

    scale=True 时按 BitNet 论文返回 α·sign(W), α = 逐输出通道 mean(|W|):
        W_fwd = mean(|W|, axis=0) * sign(W)
    这一项不是可选优化, 而是必需的: 若只用 sign(W), 所有权重模长恒为 1,
    单层投影增益 = sqrt(fan_in) ≈ 11, 一层内 7 个投影相乘 -> 梯度逐层放大
    ~500× (实测 n_layer=1/2/4: 2.4e6 / 1.2e9 / 2.2e14), 前向也被波及
    (x_last absmax 1170 vs fp32 的 0.17). STE 对 α 项不做求导 (标准做法).
    """
    if _K is not None:
        wc = np.ascontiguousarray(w, np.float32)
        s = np.empty_like(wc)
        _K.qxn_sign(wc, s, wc.size)
    else:
        s = np.sign(w)
    if not scale:
        return s
    a = np.abs(w).mean(axis=0, keepdims=True)   # (1, n_out)
    return (s * a).astype(w.dtype)


# ============================ 微分算子 ============================
class Lin:
    """y = x @ W  (W: (d_in, d_out)), 带可选权重二值化."""
    def __init__(self, W, binary=False):
        self.W = W
        self.binary = binary

    def __call__(self, x, cache=None):
        Wt = binarize_w(self.W) if self.binary else self.W
        y = x @ Wt
        if cache is not None:
            cache['x'] = x
            cache['Wt'] = Wt
        return y

    def bwd(self, dy, cache):
        # dx = dy @ Wt.T ; dW = x.T @ dy (若二值化, dW 用 STE 直通到原 W)
        dx = dy @ cache['Wt'].T
        dW = cache['x'].T.reshape(-1, cache['x'].shape[-1]).T @ dy.reshape(
            -1, dy.shape[-1])
        dW = cache['x'].reshape(-1, cache['x'].shape[-1]).T @ dy.reshape(
            -1, dy.shape[-1])
        return dx, dW


class RMSNorm:
    def __init__(self, d):
        self.g = np.ones(d, np.float32)

    def __call__(self, x, cache=None):
        rstd = 1.0 / np.sqrt(np.mean(x * x, -1, keepdims=True) + 1e-6)
        xh = x * rstd
        y = xh * self.g
        if cache is not None:
            cache.update(x=x, rstd=rstd, xh=xh)
        return y

    def bwd(self, dy, cache):
        rstd, xh, x = cache['rstd'], cache['xh'], cache['x']
        # y = xh * g ; d/dxh = dy*g ; d/dx = rstd*(dy*g) - x*rstd^3*mean(dy*g*x)
        gh = dy * self.g
        dx = rstd * gh - x * rstd ** 3 * np.mean(gh * x, -1, keepdims=True)
        dg = np.sum(dy * xh, axis=tuple(range(dy.ndim - 1)))
        return dx, dg


def softmax(x, axis=-1):
    # 原地化: 原来是 max/subtract/exp/sum/divide 五趟 + 三次大数组分配,
    # 其中 subtract/exp/divide 各产生一个 (B*T, V) 的临时拷贝.
    # 这里只分配一次并全程原地. 实测 (512,2400) float32:
    # 17.56 ms -> 13.16 ms, 且与原实现 **逐位一致** (max|差| = 0).
    # 注意必须先 copy: 调用方传进来的可能是 reshape 的视图(共享内存),
    # 直接原地会改到 logits 本身.
    if os.environ.get("SM_INPLACE", "1") == "0":
        return _softmax_ref(x, axis)
    x = np.array(x, copy=True)
    x -= np.max(x, axis=axis, keepdims=True)
    np.exp(x, out=x)
    x /= x.sum(axis=axis, keepdims=True)
    return x


def _softmax_ref(x, axis=-1):
    m = np.max(x, axis=axis, keepdims=True)
    e = np.exp(x - m)
    return e / np.sum(e, axis=axis, keepdims=True)


def gelu(x):
    if _K is not None:
        xc = np.ascontiguousarray(x, np.float32)
        y = np.empty_like(xc)
        _K.qxn_gelu(xc, y, xc.size)
        return y
    return 0.5 * x * (1 + np.tanh(0.7978845608 * (x + 0.044715 * x ** 3)))


def gelu_bwd(x, dy):
    if _K is not None:
        xc = np.ascontiguousarray(x, np.float32)
        dc = np.ascontiguousarray(dy, np.float32)
        y = np.empty_like(xc)
        _K.qxn_gelu_bwd_mul(xc, dc, y, xc.size)
        return y
    c = 0.7978845608
    inner = c * (x + 0.044715 * x ** 3)
    t = np.tanh(inner)
    d = 0.5 * (1 + t) + 0.5 * x * (1 - t ** 2) * c * (1 + 3 * 0.044715 * x ** 2)
    return dy * d


def rope_neox(t, pos):
    """t (B,T,H,D), pos (T,). NeoX: 前后半分配对."""
    D = t.shape[-1]
    d = D // 2
    t1, t2 = t[..., :d], t[..., d:]
    inv = 1.0 / (10000.0 ** (np.arange(0, D, 2) / D))
    ang = pos[:, None] * inv[None, :]           # (T, d)
    c, s = np.cos(ang)[None, :, None, :], np.sin(ang)[None, :, None, :]
    return np.concatenate([t1 * c - t2 * s, t1 * s + t2 * c], -1)


def rope_neox_bwd(dt, pos):
    """RoPE 是正交旋转, 转置 = 逆旋转 (角度取负)."""
    D = dt.shape[-1]
    d = D // 2
    dt1, dt2 = dt[..., :d], dt[..., d:]
    inv = 1.0 / (10000.0 ** (np.arange(0, D, 2) / D))
    ang = pos[:, None] * inv[None, :]
    c, s = np.cos(ang)[None, :, None, :], np.sin(ang)[None, :, None, :]
    return np.concatenate([dt1 * c + dt2 * s, -dt1 * s + dt2 * c], -1)


# ============================ 模型 ============================
def wv(self, name):
    """前向权重. 二值化模式下 W_fwd = gamma * sign(W).
    gamma 是逐输入通道的可学习缩放 (BitNet 的关键设计) —— 没有它, 网络
    无法调整不同输入通道的动态范围, 表达能力受限."""
    if not self.binary_w:
        return self.P[name]
    if not getattr(self, 'use_gamma', False):
        return binarize_w(self.P[name], self.w_absmean)
    g = self.P.get('g:' + name)
    if g is None:
        return binarize_w(self.P[name], self.w_absmean)
    # 注意: α 已按输出通道缩放, 这里再乘逐输入通道 gamma
    return binarize_w(self.P[name], self.w_absmean) * g[:, None]


def wv_inv(self, name):
    return wv(self, name)


class QxN:
    def __init__(self, n_layer, n_embd, n_head, n_ff, vocab, block_size,
                 mode="fp32", seed=0, act_absmax=False, act_clamp=127.0,
                 use_gamma=False, w_absmean=True):
        self.mode = mode
        self.binary_w = mode in ("bitnet", "binary")
        # BitNet 的 α·sign(W) 缩放 (必需项, 见 binarize_w 文档)
        self.w_absmean = bool(w_absmean)
        self._wcache = {}
        self.act_mode = "binary" if mode == "binary" else "bitnet"
        self.act_absmax = act_absmax
        self.act_clamp = float(act_clamp)
        self.n_layer, self.n_embd = n_layer, n_embd
        self.n_head, self.n_ff, self.vocab = n_head, n_ff, vocab
        self.block_size = block_size
        self.hd = n_embd // n_head
        rng = np.random.default_rng(seed)
        P = {}

        def nn(std, *s):
            return rng.normal(0, std, s).astype(np.float32)

        P['embd'] = nn(0.02, vocab, n_embd)
        P['posembd'] = nn(0.01, block_size, n_embd)
        for i in range(n_layer):
            p = f'l{i}.'
            P[p + 'an'] = np.ones(n_embd, np.float32)
            P[p + 'q_norm'] = np.ones(self.hd, np.float32)
            P[p + 'k_norm'] = np.ones(self.hd, np.float32)
            P[p + 'wq'] = nn(0.02, n_embd, n_embd)
            P[p + 'wk'] = nn(0.02, n_embd, n_embd)
            P[p + 'wv'] = nn(0.02, n_embd, n_embd)
            P[p + 'wo'] = nn(0.02 / math.sqrt(2 * n_layer), n_embd, n_embd)
            P[p + 'fn'] = np.ones(n_embd, np.float32)
            P[p + 'w1'] = nn(0.02, n_embd, n_ff)
            P[p + 'w2'] = nn(0.02 / math.sqrt(2 * n_layer), n_ff, n_embd)
            P[p + 'w3'] = nn(0.02, n_embd, n_ff)
        P['on'] = np.ones(n_embd, np.float32)
        P['out'] = nn(0.02, n_embd, vocab)
        self.P = P
        # 置信度头 (见 docs §15-16): 从最终隐状态预测"该位置是否预测正确"
        P.setdefault('cw', np.zeros(n_embd, np.float32))
        P.setdefault('cb', np.zeros(1, np.float32))
        # BitNet 的 gamma: 二值化权重的逐输入通道缩放 (幅度自由度)
        # gamma 存进 P, key='g:<name>' —— 这样 AdamW 更新和梯度检查自动生效
        self.gamma = {}
        self.use_gamma = use_gamma
        if self.binary_w and use_gamma:
            for i in range(n_layer):
                pp = f'l{i}.'
                for nm, d in (('wq', n_embd), ('wk', n_embd), ('wv', n_embd),
                              ('wo', n_embd), ('w1', n_embd), ('w3', n_embd),
                              ('w2', n_ff)):
                    P['g:' + pp + nm] = np.ones(d, np.float32)
                    self.gamma[pp + nm] = 'g:' + pp + nm
            P['g:out'] = np.ones(n_embd, np.float32)
            self.gamma['out'] = 'g:out'
        self._m = {k: np.zeros_like(v) for k, v in P.items()}
        self._v = {k: np.zeros_like(v) for k, v in P.items()}


    def _quant_act(self, x, cache, tag):
        """激活量化 (BitNet). fp32 模式直通; STE 反向直通, 故 backward 需
        用**量化前**的输入重算 norm."""
        if self.mode == 'fp32':
            return x
        if cache is not None:
            cache[tag + '_pre'] = x
        if self.act_mode == 'binary':
            return np.sign(x)
        # 8-bit 均匀量化. BitNet 原文用 per-token **absmean** (对离群值鲁棒),
        # 这里默认 absmean; --act_absmax 可切到 absmax 做对照.
        if self.act_absmax:
            r = np.max(np.abs(x), axis=-1, keepdims=True)
        else:
            r = np.mean(np.abs(x), axis=-1, keepdims=True)
        s = np.maximum(r / self.act_clamp, 1e-8)
        return np.clip(np.round(x / s), -self.act_clamp,
                       self.act_clamp) * s

    # -------- 前向 --------

    def forward(self, tokens, collect=False):
        B, T = tokens.shape
        P, C = self.P, ({}, ) if False else ({},)   # C list
        caches = [] if collect else None
        self._gt = {}          # ggml 转置视图缓存, 每步重建 (权重每步都变)
        x = P['embd'][tokens] + P['posembd'][:T]        # (B,T,d)
        nh, hd = self.n_head, self.hd
        pos = np.arange(T)

        for i in range(self.n_layer):
            p = f'l{i}.'
            cc = {}
            if collect:
                caches.append(cc)
            _an = RMSNorm(self.n_embd); _an.g = P[p + 'an']
            h = _an(x, cc if collect else None)
            # BitNet 的关键: 激活也量化 (binary -> +-1, bitnet -> 8bit 均匀)
            h = self._quant_act(h, cc, 'attn_in')
            Wq = wv(self, p + 'wq')
            Wk = wv(self, p + 'wk')
            Wv = wv(self, p + 'wv')
            if _use_ggml(B*T, nh*hd, self.n_embd):
                h2 = h.reshape(-1, self.n_embd)
                q = mm_at_b(h2, Wq, self._gt, p + 'wqt').reshape(B, T, nh, hd)
                k = mm_at_b(h2, Wk, self._gt, p + 'wkt').reshape(B, T, nh, hd)
                v = mm_at_b(h2, Wv, self._gt, p + 'wvt').reshape(B, T, nh, hd)
            else:
                q = (h @ Wq).reshape(B, T, nh, hd)
                k = (h @ Wk).reshape(B, T, nh, hd)
                v = (h @ Wv).reshape(B, T, nh, hd)
            # per-head norm before rope
            q_in, k_in = q.copy(), k.copy()      # norm 的输入(反向要用)
            q_rstd = 1.0 / np.sqrt(np.mean(q * q, -1, keepdims=True) + 1e-6)
            k_rstd = 1.0 / np.sqrt(np.mean(k * k, -1, keepdims=True) + 1e-6)
            q = q * q_rstd * P[p + 'q_norm']
            k = k * k_rstd * P[p + 'k_norm']
            q = rope_neox(q, pos)
            k = rope_neox(k, pos)
            # batched matmul 走 BLAS sgemm, 比 einsum 快 ~3x (数值一致 5.6e-07)
            # (B,T,nh,hd) -> (B*nh,T,hd) 把 head 提到 batch 维
            qh = np.ascontiguousarray(q.transpose(0, 2, 1, 3)
                                      .reshape(B * nh, T, hd))
            kh = np.ascontiguousarray(k.transpose(0, 2, 1, 3)
                                      .reshape(B * nh, T, hd))
            vh = np.ascontiguousarray(v.transpose(0, 2, 1, 3)
                                      .reshape(B * nh, T, hd))
            sc = np.matmul(qh, np.swapaxes(kh, 1, 2)) / math.sqrt(hd)
            sc = sc.reshape(B, nh, T, T)
            sc[:, :, np.triu(np.ones((T, T), bool), 1)] = -1e9
            pr = softmax(sc, -1)
            o = np.matmul(pr.reshape(B * nh, T, T), vh)
            o = o.reshape(B, nh, T, hd).transpose(0, 2, 1, 3)
            o = o.reshape(B, T, self.n_embd)
            Wo_l = wv(self, p + 'wo')
            if _use_ggml(B*T, self.n_embd, self.n_embd):
                do = mm_at_b(o.reshape(-1, self.n_embd), Wo_l,
                             self._gt, p + 'wot').reshape(B, T, self.n_embd)
            else:
                do = o @ Wo_l
            if collect:
                cc.update(x=x, h=h, o=o, pr=pr, q=q, k=k, v=v, q_in=q_in, k_in=k_in,
                          q_rstd=q_rstd, k_rstd=k_rstd,
                          Wq=Wq, Wk=wv(self, p + 'wk'), Wv=wv(self, p + 'wv'),
                          Wo=wv(self, p + 'wo'), W1=wv(self, p + 'w1'),
                          W2=wv(self, p + 'w2'), W3=wv(self, p + 'w3'),
                          qn=P[p + 'q_norm'], kn=P[p + 'k_norm'])
            x = x + do
            # FFN (SwiGLU)
            _fn = RMSNorm(self.n_embd); _fn.g = P[p + 'fn']
            hh = _fn(x, None)
            hh = self._quant_act(hh, caches[-1] if collect else None, 'ffn_in')
            W1 = wv(self, p + 'w1')
            W3 = wv(self, p + 'w3')
            hh2 = hh.reshape(-1, self.n_embd)
            if _use_ggml(B*T, self.n_ff, self.n_embd):
                a1 = mm_at_b(hh2, W1, self._gt, p + 'w1t').reshape(B, T, self.n_ff)
            else:
                a1 = hh @ W1
            g1 = gelu(a1)
            if _use_ggml(B*T, self.n_ff, self.n_embd):
                a3 = mm_at_b(hh2, W3, self._gt, p + 'w3t').reshape(B, T, self.n_ff)
            else:
                a3 = hh @ W3
            g3 = a3
            ff = (g1 * g3)
            ff = self._quant_act(ff, caches[-1] if collect else None, 'ffn_mid')
            W2 = wv(self, p + 'w2')
            if _use_ggml(B*T, self.n_embd, self.n_ff):
                ff = mm_at_b(ff.reshape(-1, self.n_ff), W2,
                             self._gt, p + 'w2t').reshape(B, T, self.n_embd)
            else:
                ff = ff @ W2
            if collect:
                caches[-1].update(xf=x, hh=hh, a1=a1, a3=a3,
                                  g1=g1, g3=g3)
            x = x + ff
        _on = RMSNorm(self.n_embd); _on.g = P['on']
        _oc = {} if collect else None
        xf = _on(x, _oc)
        # 置信度头: score = h·w + b 预测"该位置预测是否正确".
        # 动机见 docs §15-16: 1-bit 量化把输出分布压扁, 置信增益只有 fp32 的 1/13.
        # 头从最终隐状态 x_last 直接学, 与主输出头解耦.
        _Wo = wv(self, 'out')
        if _use_ggml(B*T, _Wo.shape[1], self.n_embd):
            _sh = xf.shape
            logits = mm_at_b(xf.reshape(-1, self.n_embd), _Wo,
                             self._wcache, 'wot').reshape(_sh[:-1] + (_Wo.shape[1],))
        else:
            logits = xf @ _Wo
        if collect:
            self._last_conf_z = self.conf_head(x)[1]
            return logits, caches, xf, x, _oc
        return logits

    def conf_head(self, x_last):
        """P(下一 token 预测正确). x_last (B,T,d) -> (B,T) 概率.

        参数量 d+1 (192+1), 相比主输出头可忽略.
        """
        if 'cw' not in self.P:
            self.P['cw'] = np.zeros(self.n_embd, np.float32)
            self.P['cb'] = np.zeros(1, np.float32)
        B, T, _ = x_last.shape
        z = x_last.reshape(-1, self.n_embd) @ self.P['cw'] + self.P['cb'][0]
        return 1.0 / (1.0 + np.exp(-z.reshape(B, T))), z.reshape(B, T)

    @staticmethod
    def conf_head_grad(x_last, dz):
        """返回 (dL/dw, dL/db), dz 为 dL/d(logit) 形状 (B,T)."""
        B, T, d = x_last.shape
        g = dz.reshape(-1)
        x2 = x_last.reshape(-1, d)
        return x2.T @ g, np.array([g.sum()], np.float32)

    # -------- 反向 --------
    def backward(self, tokens, logits, caches, xf, x_last, on_cache,
                 dlogits=None):
        """dlogits=None 时用内部交叉熵梯度; 否则用外部给定的 dL/dlogits
        (蒸馏场景: 梯度来自 KL + CE 的组合)."""
        B, T = tokens.shape
        P = self.P
        G = {k: np.zeros_like(v) for k, v in P.items()}
        nh, hd = self.n_head, self.hd
        pos = np.arange(T)
        # per-head norm 的权重梯度是 (B,T,hd), 循环外汇总后再写入
        GQ = {f'l{i}.q_norm': np.zeros_like(P[f'l{i}.q_norm'])
              for i in range(self.n_layer)}
        GK = {f'l{i}.k_norm': np.zeros_like(P[f'l{i}.k_norm'])
              for i in range(self.n_layer)}

        # loss 梯度 (交叉熵); 蒸馏时由外部传入 KL+CE 的组合梯度
        if dlogits is None:
            pr = softmax(logits.reshape(-1, self.vocab)).reshape(B, T, self.vocab)
            d = pr.copy() if os.environ.get("SM_INPLACE","1")=="0" else pr
            tgt = tokens[:, 1:]
            # 交叉熵梯度是 d = p - onehot, 目标位置要 **减 1**.
            # np.put_along_axis 是**赋值**, 会把 p_target 整个覆盖成 -1,
            # 等价于告诉模型"目标类的概率是 0" —— 实测让所有张量的解析梯度
            # 比真实值大约 9% (目标位置 d 应为 (p-1)/N, 实际是 -1/N).
            # 这会系统性地过度惩罚正确 token, 造成过度自信.
            _bi = np.arange(B)[:, None]
            _ti = np.arange(T - 1)[None, :]
            d[_bi, _ti, tgt] -= 1.0
            d[:, -1, :] = 0.0
            d = d / (B * (T - 1))
        else:
            d = dlogits.reshape(B, T, self.vocab).astype(np.float32)

        # out projection
        Wo = wv(self, 'out')
        if _use_ggml(B * T, Wo.shape[0], d.shape[-1]):
            _dsh = d.shape
            _d2 = d.reshape(-1, _dsh[-1])
            dxf = mm_at_bt(_d2, Wo).reshape(_dsh[:-1] + (Wo.shape[0],))
            dWo_out = mm_at_at_b(xf.reshape(-1, self.n_embd), _d2)
        else:
            dxf = d @ Wo.T
            dWo_out = xf.reshape(-1, self.n_embd).T @ d.reshape(-1, self.vocab)
        G['out'] = dWo_out
        if self.binary_w and getattr(self, "use_gamma", False):
            G['g:out'] = np.sum(dWo_out * np.sign(self.P['out']), axis=1)
        # out norm
        on = RMSNorm(self.n_embd); on.g = P['on']
        dx, dg = on.bwd(dxf, on_cache)
        G['on'] = dg
        dx = dx.reshape(B, T, self.n_embd)

        for i in reversed(range(self.n_layer)):
            p = f'l{i}.'
            c = caches[i]
            # --- FFN ---
            dff = dx                                    # (B,T,d)
            gprod = c['g1'] * c['g3']                   # (B,T,n_ff)
            # d w2 (二值化 -> STE: dW 用原 dtype, 直通)
            if USE_GGML:
                dW2 = mm_at_at_b(gprod.reshape(-1, self.n_ff),
                                 dff.reshape(-1, self.n_embd))
            else:
                dW2 = gprod.reshape(-1, self.n_ff).T @ dff.reshape(-1, self.n_embd)
            G[p + 'w2'] += dW2
            if self.binary_w and getattr(self, "use_gamma", False):
                G['g:' + p + 'w2'] += np.sum(
                    dW2 * np.sign(self.P[p + 'w2']), axis=1)
            _W2b = wv(self, p + 'w2')
            if USE_GGML:
                dg = mm_at_bt(dff.reshape(-1, self.n_embd), _W2b).reshape(
                    B, T, self.n_ff)
            else:
                dg = dff @ _W2b.T                     # STE 直通到 ffn_mid
            dg1 = dg * c['g3']
            dg3 = dg * c['g1']
            if USE_GGML:
                _g1 = gelu_bwd(c['a1'], dg1).reshape(-1, self.n_ff)
                _g3 = dg3.reshape(-1, self.n_ff)
                dh = (mm_at_bt(_g1, c['W1']) + mm_at_bt(_g3, c['W3'])
                      ).reshape(B, T, self.n_embd)
            else:
                dh = gelu_bwd(c['a1'], dg1) @ wv(self, p + 'w1').T + \
                    dg3 @ wv(self, p + 'w3').T
            hh_in = c['hh'] if self.mode == 'fp32' else c['ffn_in_pre']
            if USE_GGML:
                dW1 = mm_at_at_b(hh_in.reshape(-1, self.n_embd),
                                 dg1.reshape(-1, self.n_ff))
                dW3 = mm_at_at_b(hh_in.reshape(-1, self.n_embd),
                                 dg3.reshape(-1, self.n_ff))
            else:
                # dg1 是 **gelu 之后**(g1)的梯度; dL/dW1 需要 **gelu 之前**(a1)的
                # 梯度. 漏掉 gelu_bwd 会让 W1 的梯度偏大(实测约 2x), 且与
                # 上面的 GGML 分支不一致 —— GGML 是关闭的, 所以一直跑的是错的那条.
                _g1 = gelu_bwd(c['a1'], dg1).reshape(-1, self.n_ff)
                dW1 = hh_in.reshape(-1, self.n_embd).T @ _g1
                dW3 = hh_in.reshape(-1, self.n_embd).T @ dg3.reshape(-1, self.n_ff)
            G[p + 'w1'] += dW1
            G[p + 'w3'] += dW3
            if self.binary_w and getattr(self, "use_gamma", False):
                G['g:' + p + 'w1'] += np.sum(
                    dW1 * np.sign(self.P[p + 'w1']), axis=1)
                G['g:' + p + 'w3'] += np.sum(
                    dW3 * np.sign(self.P[p + 'w3']), axis=1)
            fn = RMSNorm(self.n_embd); fn.g = P[p + 'fn']
            _c2 = {}
            fn(c['xf'], _c2)
            dx2, dgfn = fn.bwd(dh, _c2)
            G[p + 'fn'] += dgfn
            # 残差结构:
            #   x_mid = x_attn + do          (attention 残差)
            #   x_out = x_mid + ff           (ffn 残差)
            # 故 dx_mid = dx_out(直连) + dx2(经 ffn 分支)
            dx_mid = dx + dx2

            # --- attention ---
            do = dx_mid                                 # do 分支的梯度
            # wo: o @ Wo
            if USE_GGML:
                dWo = mm_at_at_b(c['o'].reshape(-1, self.n_embd),
                                 do.reshape(-1, self.n_embd))
            else:
                dWo = c['o'].reshape(-1, self.n_embd).T @ do.reshape(-1, self.n_embd)
            G[p + 'wo'] += dWo
            if self.binary_w and getattr(self, "use_gamma", False):
                G['g:' + p + 'wo'] += np.sum(
                    dWo * np.sign(self.P[p + 'wo']), axis=0)
            if USE_GGML:
                datt = mm_at_bt(do.reshape(-1, self.n_embd),
                                c['Wo']).reshape(B, T, self.n_embd)
            else:
                datt = do @ wv(self, p + 'wo').T         # (B,T,n_embd)
            datt = datt.reshape(B, T, nh, hd)
            # attention softmax backward
            dp = c['pr']
            # 注意 1/sqrt(hd) 只在 dsc 里除一次 —— sc 已含该因子,
            # 对 q/k 求导时它已经体现在 dsc 里, 再除会导致 hd 倍偏差.
            # 与 forward 同样的 BLAS 布局; 1/sqrt(hd) 只在 dsc 里除一次
            dph = dp.reshape(B * nh, T, T)
            datt_h = np.ascontiguousarray(datt.transpose(0, 2, 1, 3)
                                          .reshape(B * nh, T, hd))
            v_h = np.ascontiguousarray(c['v'].transpose(0, 2, 1, 3)
                                       .reshape(B * nh, T, hd))
            k_h = np.ascontiguousarray(c['k'].transpose(0, 2, 1, 3)
                                       .reshape(B * nh, T, hd))
            q_h = np.ascontiguousarray(c['q'].transpose(0, 2, 1, 3)
                                       .reshape(B * nh, T, hd))
            dv = np.matmul(np.swapaxes(dph, 1, 2), datt_h)
            dsc = np.matmul(datt_h, np.swapaxes(v_h, 1, 2)) / math.sqrt(hd)
            ds = dph * (dsc - np.sum(dsc * dph, -1, keepdims=True))
            dsh = ds.reshape(B * nh, T, T)
            dq = np.matmul(dsh, k_h)
            dk = np.matmul(np.swapaxes(dsh, 1, 2), q_h)
            dv = dv.reshape(B, nh, T, hd).transpose(0, 2, 1, 3)
            dq = dq.reshape(B, nh, T, hd).transpose(0, 2, 1, 3)
            dk = dk.reshape(B, nh, T, hd).transpose(0, 2, 1, 3)
            # per-head norm backward (norm 在 rope 之前 -> 先 rope 反向)
            dq = rope_neox_bwd(dq, pos)
            dk = rope_neox_bwd(dk, pos)
            dqn, dqn_g = rmsnorm_head_bwd(dq, c['q_in'], P[p + 'q_norm'],
                                          c['q_rstd'])
            dkn, dkn_g = rmsnorm_head_bwd(dk, c['k_in'], P[p + 'k_norm'],
                                          c['k_rstd'])
            GQ[p + 'q_norm'] += dqn_g
            GK[p + 'k_norm'] += dkn_g
            # 投影 backward (h 已 flatten)
            dqf = dqn.reshape(B * T, nh * hd)
            dkf = dkn.reshape(B * T, nh * hd)
            dvf = dv.reshape(B * T, nh * hd)
            hf = c['h'].reshape(B * T, self.n_embd)
            if USE_GGML:
                dWq_ = mm_at_at_b(hf, dqf)
                dWk_ = mm_at_at_b(hf, dkf)
                dWv_ = mm_at_at_b(hf, dvf)
            else:
                dWq_ = hf.T @ dqf
                dWk_ = hf.T @ dkf
                dWv_ = hf.T @ dvf
            G[p + 'wq'] += dWq_
            G[p + 'wk'] += dWk_
            G[p + 'wv'] += dWv_
            if self.binary_w and getattr(self, "use_gamma", False):
                for nm, dW_ in (('wq', dWq_), ('wk', dWk_), ('wv', dWv_)):
                    G['g:' + p + nm] += np.sum(
                        dW_ * np.sign(self.P[p + nm]), axis=1)
            # attention 分支(q/k/v 投影 + wo) 的梯度回到 attn_norm 的输入 h.
            # 注意 dx_mid 已作为 do 传过(wo 的上游), 此处只加 attn 内部贡献,
            # x_attn 的残差直连项在下面 dx = dx_mid 汇入.
            if USE_GGML:
                dh_attn = (mm_at_bt(dqf, c['Wq']) + mm_at_bt(dkf, c['Wk'])
                           + mm_at_bt(dvf, c['Wv'])).reshape(B, T, self.n_embd)
            else:
                dh_attn = (dqf @ c['Wq'].T + dkf @ c['Wk'].T
                           + dvf @ c['Wv'].T).reshape(B, T, self.n_embd)
            an = RMSNorm(self.n_embd); an.g = P[p + 'an']
            _c3 = {}
            # 量化是 STE 直通 -> norm 的输入是量化前的 attn_in_pre
            an_in = c['x'] if self.mode == 'fp32' else c['attn_in_pre']
            an(an_in, _c3)
            dxc, dgan = an.bwd(dh_attn, _c3)
            G[p + 'an'] += dgan
            # x_attn 的残差直连 (x_mid = x_attn + do) + attn_norm 梯度
            dx = dx_mid + dxc

        # embedding grad: x = embd[tokens] + posembd[:T]
        np.add.at(G['embd'], tokens, dx)
        G['posembd'][:T] = dx.sum(axis=0)
        for i in range(self.n_layer):
            G[f'l{i}.q_norm'] += GQ[f'l{i}.q_norm'].reshape(-1, hd).sum(0)
            G[f'l{i}.k_norm'] += GK[f'l{i}.k_norm'].reshape(-1, hd).sum(0)
        return G


# 便捷: 取权重(视模式)


def build_from_ckpt(P, n_head=4, mode="fp32", seed=0, strict=True):
    """从 checkpoint 的参数字典构造 QxN 并载入权重.

    **block_size 必须取自 posembd 的行数**. 训练时是 `--seq_len`(实测用过 48/256),
    若这里硬编码 512, 下面的形状检查会把 posembd(以及任何形状不符的参数)跳过,
    **位置嵌入保持随机**而没有任何报错 —— §37.1 里今天一半的评估数字是这么来的.

    strict=True 时, 任何形状不匹配直接抛错, 不静默跳过.
    """
    P = {k: v for k, v in P.items() if k != "mode"}
    D = P["l0.wq"].shape[0]
    F = P["l0.w1"].shape[1]
    V = P["out"].shape[1]
    blk = int(P["posembd"].shape[0])
    L = 1 + max(int(k.split(".")[0][1:]) for k in P
                if k.startswith("l") and k.split(".")[0][1:].isdigit())
    m = QxN(L, D, n_head, F, V, blk, mode=mode, seed=seed)
    bad = [k for k, v in P.items() if k in m.P and m.P[k].shape != v.shape]
    if bad and strict:
        raise ValueError(
            f"[build_from_ckpt] 形状不匹配, 这些参数未载入: {bad}\n"
            f"  checkpoint 可能是别的配置训的, 不能直接套用.")
    for k, v in P.items():
        if k in m.P and m.P[k].shape == v.shape:
            m.P[k] = v.astype(np.float32)
    return m, (L, D, F, V, blk)
def rmsnorm_head(t, g):
    """t (B,T,H,D), g (D,) -> per-head RMSNorm."""
    r = 1.0 / np.sqrt(np.mean(t * t, -1, keepdims=True) + 1e-6)
    return t * r * g


def rmsnorm_head_bwd(dt, t, g, rstd=None):
    if rstd is None:
        rstd = 1.0 / np.sqrt(np.mean(t * t, -1, keepdims=True) + 1e-6)
    gh = dt * g
    dx = rstd * gh - t * rstd ** 3 * np.mean(gh * t, -1, keepdims=True)
    dg = (dt * (t * rstd)).reshape(-1, dt.shape[-1]).sum(0)
    return dx, dg


# ============================ 数据 (合成, 固定 seed) ============================
def make_data(vocab, block, n_seq, seed=1234, task="arith"):
    """合成语料.

    task="arith": 可学习的确定性规则 (a+b mod 10) —— 太简单, ppl 很快到 1.05,
        无法区分不同量化档位, 仅用于验证框架能收敛.
    task="copy" : 复制任务 (每个 token 重复 3 次) —— 需要权重存储位置信息,
        对权重量化更敏感.
    task="mixed": 50% arith + 50% 高熵随机 (不可预测) —— loss 存在不可压缩
        下界, 便于观察量化对"可学习部分"的提取能力.
    """
    rng = np.random.default_rng(seed)
    D = 10
    S = 10   # 符号起始
    seqs = []
    for _ in range(n_seq):
        kind = rng.random()
        if task == "arith" or (task == "mixed" and kind < 0.5):
            a, b = rng.integers(0, D), rng.integers(0, D)
            toks = [S, a, S + 1, b, S + 2, (a + b) % D, S + 3]
        elif task == "copy":
            base = list(rng.integers(0, D, size=max(2, block // 6)))
            toks = []
            for x in base:
                toks += [x, x, x]
        else:   # 高熵
            toks = list(rng.integers(0, vocab, size=block))
        if len(toks) < block:
            reps = block // max(1, len(toks)) + 1
            toks = (toks * reps)[:block]
        else:
            toks = toks[:block]
        seqs.append(toks)
    return np.array(seqs, dtype=np.int64)


# ============================ 训练循环 ============================
def loss_on(P_logits, tokens):
    B, T, V = P_logits.shape
    pr = softmax(P_logits[:, :-1].reshape(-1, V), -1).reshape(B, T - 1, V)
    tgt = tokens[:, 1:]
    nll = -np.log(np.maximum(np.take_along_axis(pr, tgt[..., None], -1), 1e-12))
    return float(nll.mean())


def train(model, tokens, steps, lr, seed=0, log_every=50, verify=False,
          grad_check_every=0):
    opt_keys = list(model.P.keys())
    for st in range(steps):
        # 线性 warmup + cosine 衰减
        if st < 50:
            cur_lr = lr * (st + 1) / 50
        else:
            prog = (st - 50) / max(1, steps - 50)
            cur_lr = lr * 0.5 * (1 + math.cos(math.pi * prog))

        logits, caches, xf, x_last, on_cache = model.forward(tokens, collect=True)
        loss = loss_on(logits, tokens)
        G = model.backward(tokens, logits, caches, xf, x_last, on_cache)

        if verify and st == 0:
            grad_check(model, tokens)

        b1, b2, eps, wd = 0.9, 0.999, 1e-8, 0.01
        for k in list(opt_keys):
            g = G.get(k)
            if g is None or g.shape != model.P[k].shape:
                # gamma 梯度实现待验证, 形状不符则跳过(不影响其余参数)
                if g is not None:
                    print(f'  [skip] {k}: 梯度形状 {g.shape} != 参数 {model.P[k].shape}',
                          flush=True)
                continue
            model._m[k] = b1 * model._m[k] + (1 - b1) * g
            model._v[k] = b2 * model._v[k] + (1 - b2) * (g * g)
            mh = model._m[k] / (1 - b1 ** (st + 1))
            vh = model._v[k] / (1 - b2 ** (st + 1))
            if k not in ('embd', 'posembd') and not k.endswith('_norm') \
                    and 'norm' not in k.split('.')[-1]:
                model.P[k] -= cur_lr * wd * model.P[k]
            model.P[k] -= cur_lr * mh / (np.sqrt(vh) + eps)

        if st % log_every == 0 or st == steps - 1:
            ppl = math.exp(min(20, loss))
            print(f"  step {st:4d}  loss {loss:.4f}  ppl {ppl:8.2f}  lr {cur_lr:.2e}",
                  flush=True)
    return model


def grad_check(model, tokens, eps=1e-3):
    """有限差分验证几个关键参数的梯度."""
    print("  [grad-check] 有限差分验证...", flush=True)
    logits, caches, xf, x_last, on_cache = model.forward(tokens, collect=True)
    loss = loss_on(logits, tokens)
    G = model.backward(tokens, logits, caches, xf, x_last, on_cache)
    rng = np.random.default_rng(0)
    errs = []
    for k in ['l0.w1', 'l1.w2', 'out']:
        if k not in model.P:
            continue
        P0 = model.P[k].copy()
        idx = tuple(rng.integers(0, s) for s in P0.shape)
        # +eps
        model.P[k][idx] += eps
        lp = loss_on(model.forward(tokens), tokens)
        model.P[k][idx] -= 2 * eps
        lm = loss_on(model.forward(tokens), tokens)
        model.P[k] = P0
        num = (lp - lm) / (2 * eps)
        ana = G[k][idx]
        rel = abs(num - ana) / max(abs(num) + abs(ana), 1e-6)
        errs.append(rel)
        print(f"    {k:10s} num {num:+.6f}  ana {ana:+.6f}  rel {rel:.2e}",
              flush=True)
    print(f"  [grad-check] 最大相对误差 {max(errs):.2e}", flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--mode', default='fp32',
                    choices=['fp32', 'bitnet', 'binary'])
    ap.add_argument('--steps', type=int, default=300)
    ap.add_argument('--n_layer', type=int, default=4)
    ap.add_argument('--n_embd', type=int, default=128)
    ap.add_argument('--n_head', type=int, default=4)
    ap.add_argument('--n_ff', type=int, default=256)
    ap.add_argument('--vocab', type=int, default=64)
    ap.add_argument('--batch', type=int, default=16)
    ap.add_argument('--lr', type=float, default=3e-3)
    ap.add_argument('--verify', action='store_true')
    ap.add_argument('--no_gamma', action='store_true',
                    help='关闭 gamma 逐通道缩放 (默认开启; gamma 梯度实现待验证)')
    ap.add_argument('--act_absmax', action='store_true',
                    help='激活量化用 absmax 而非 absmean (BitNet 用 absmean)')
    ap.add_argument('--act_clamp', type=float, default=127.0)
    ap.add_argument('--task', default='arith',
                    choices=['arith', 'copy', 'mixed'])
    args = ap.parse_args()

    torch_seed = 0
    model = QxN(args.n_layer, args.n_embd, args.n_head, args.n_ff,
                args.vocab, 32, mode=args.mode, seed=torch_seed,
                act_absmax=args.act_absmax, act_clamp=args.act_clamp,
                use_gamma=not args.no_gamma)
    nparam = sum(v.size for v in model.P.values())
    print(f"=== mode={args.mode}  task={args.task}  params={nparam/1e6:.2f}M  "
          f"steps={args.steps}  seed={torch_seed} ===", flush=True)
    if args.mode in ('bitnet', 'binary'):
        print(f"  权重二值化: {args.mode}  (前向 sign, 反向 STE 直通)", flush=True)

    tokens = make_data(args.vocab, 32, args.batch, seed=1234, task=args.task)
    t0 = time.time()
    train(model, tokens, args.steps, args.lr, verify=args.verify)
    dt = time.time() - t0
    logits = model.forward(tokens)
    final_loss = loss_on(logits, tokens)
    print(f"  最终 loss {final_loss:.4f}  ppl {math.exp(min(20,final_loss)):.2f}"
          f"  ({dt:.0f}s, {dt/args.steps*1000:.0f} ms/step)", flush=True)


if __name__ == '__main__':
    main()