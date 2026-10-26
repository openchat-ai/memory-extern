"""端到端重打包验证: 写 1 条事实到全部 28 层的 down, 重打包, 加载新文件, 测命中.

判据: 新 GGUF 加载后 rank 0 (与运行时覆盖一致).
分层并行 (用 4 核) 加速重编码.
"""
import os, sys, time, numpy as np
sys.path.insert(0, 'tools')
from qxt_hebb import HebbInjector, Fp32Mat
import qxt_repack as RP
from q1t_stream import StreamEngine, SRC, read_packslim, rmsnorm, apply_rope
from concurrent.futures import ProcessPoolExecutor

SLIM = "/data/data/com.termux/files/home/models/qxt/rStar-Coder-Qwen3-0.6B.Q8_0-Q4T_packslim.gguf"
OUT = "/data/data/com.termux/files/home/models/qxt/rStar-Coder-heb_test.gguf"

PROMPT = "def add(a, b):"
TARGET = "print"
C = 5.0

H = HebbInjector()
toks = np.array(H.eng.encode(PROMPT), np.int64)
tgt = H.target_id(TARGET)
print(f"prompt {PROMPT!r} target {TARGET!r} id {tgt} ({H.eng.decode_text([tgt])!r})")

# 抓 phi + 构造每层 ΔB
B = H._materialize()
phis = H.capture_phi(toks)
v = H.embed(tgt)
deltas = {}
for i in range(H.N):
    pk = phis[i]; denom = pk @ pk
    deltas[i] = (np.outer(pk, C * v) / denom).astype(np.float32)
print(f"构造 {len(deltas)} 层 ΔB 完毕")

# 重打包 (单进程, 全层) —— 计时
meta, by = read_packslim(SLIM)
cb = np.asarray(meta["codebook"], np.float32)
import shutil
t0 = time.time()
shutil.copyfile(SLIM, OUT)
with open(OUT, "r+b") as f:
    for i in range(H.N):
        e = by[f"blk.{i}.ffn_down.weight"]
        W = RP.dequant_tensor(SLIM, e, cb)
        nb = RP.quant_tensor(W + deltas[i], cb)
        f.seek(e["offset"]); f.write(nb)
        if i % 4 == 0:
            print(f"  layer{i} 完成 {time.time()-t0:.0f}s"); sys.stdout.flush()
print(f"[重打包完成] {time.time()-t0:.0f}s -> {OUT}")

# 加载新文件测命中
print("\n[加载新 GGUF]")
E2 = StreamEngine(slim=OUT, src=SRC, n_ctx=512)
lo, _ = E2.forward(toks)
print(f"  新文件: target logit {lo[tgt]:.3f} rank {int((lo>lo[tgt]).sum())} top1 {E2.tok_list[int(lo.argmax())]!r}")
ids, _ = E2.generate(PROMPT, n_new=12, temperature=0.01)
print(f"  生成: {E2.decode_text(ids)!r}")
