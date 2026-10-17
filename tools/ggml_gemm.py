"""ggml 多线程 GEMM 封装.

为什么需要它
------------
Termux 的 ``libopenblas`` 以 ``NO_THREAD=1`` 编译, 静默退化为单线程
(CPU时间/墙钟 = 0.99, 且 ``readelf`` 显示它不引用任何 pthread/GOMP 符号)。
系统自带的 ``libggml-cpu.so`` 则是为 ARM 端侧重写的 pthread GEMM。

为什么 API 长这样
-----------------
ggml 只接受「两个参数第二维都是归约维 k」的布局, 即::

    dot(P, Q) = P(m,k) @ Q(n,k).T  ->  (m,n)

训练里的三种矩阵乘形态对应:

===========  ==========================  ====================
调用         形态                        ggml 写法
===========  ==========================  ====================
前向         ``Y = X @ W``               ``dot(X, W.T)``   需转置 W
dX           ``dX = dY @ W.T``           ``dot(dY, W)``    零拷贝
dW           ``dW = X.T @ dY``           ``dot(X.T, dY.T)``
===========  ==========================  ====================

实测 (绑 cpu4-7, 4 线程, 对照 numpy 单线程 OpenBLAS):
LM head 3.92x / FFN 2.2~2.9x / 小投影 1.25x。
"""
import ctypes
import os

import numpy as np

_LIBDIR = os.environ.get("GGML_LIBDIR", "/data/data/com.termux/files/usr/lib")
_SHIM = os.environ.get("GGML_SHIM",
                       os.path.join(os.path.dirname(__file__),
                                    "libggmlshim.so"))

_available = False
_err = None
try:
    for _n in ("libggml.so", "libggml-base.so", "libggml-cpu.so"):
        ctypes.CDLL(os.path.join(_LIBDIR, _n), mode=ctypes.RTLD_GLOBAL)
    _lib = ctypes.CDLL(_SHIM)
    _lib.shim_init.argtypes = [ctypes.c_int, ctypes.c_size_t]
    _lib.shim_dot.argtypes = [ctypes.c_int] * 3 + [ctypes.c_void_p] * 3
    _available = True
except OSError as _e:                                     # pragma: no cover
    _err = str(_e)

AVAILABLE = _available
_init_done = False


def init_gemm(n_threads=4, arena_mb=1024):
    """初始化持久化 ggml context. 必须在任何 dot() 之前调用一次."""
    global _init_done
    if not AVAILABLE:
        raise RuntimeError("ggml shim 不可用: %s" % _err)
    _lib.shim_init(n_threads, arena_mb)
    _init_done = True


def dot(P, Q, out=None):
    """C(m,n) = P(m,k) @ Q(n,k).T.

    **必须**转 float32: ggml 按 float32 解释裸指针, 若传入 float64 数组,
    会把每个元素的高 4 字节当成下一个元素的高 4 字节 -> 结果是垃圾(实测 NaN).
    注意 np.ascontiguousarray 不会改变 dtype.
    """
    if not _init_done:
        init_gemm()
    P = np.ascontiguousarray(P, np.float32)
    Q = np.ascontiguousarray(Q, np.float32)
    m, k = P.shape
    n = Q.shape[0]
    if Q.shape[1] != k:
        raise ValueError("k 不匹配: P%s Q%s" % (P.shape, Q.shape))
    if out is None or out.shape != (m, n) or out.dtype != np.float32:
        out = np.empty((m, n), np.float32)
    _lib.shim_dot(m, n, k,
                  P.ctypes.data, Q.ctypes.data, out.ctypes.data)
    return out


def mm(A, B, out=None, transpose_B=False, transpose_A=False):
    """按 numpy 习惯的 A@B, 内部转成 ggml 的 dot 形式."""
    P = np.ascontiguousarray(A.T) if transpose_A else A
    Q = np.ascontiguousarray(B.T) if transpose_B else B
    return dot(np.ascontiguousarray(P), np.ascontiguousarray(Q), out)