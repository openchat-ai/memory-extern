"""探针: 拿 collect cache 的 hh/g1/g3, 读 top-1; fp32 vs bitnet 两臂."""
import numpy as np, sys
sys.path.insert(0, 'tools')
from qxn_train import build_from_ckpt, wv

for mode in ('fp32', 'bitnet'):
    f = 'ckpt_fp32.npz' if mode == 'fp32' else 'ckpt_bitnet.npz'
    P = dict(np.load(f))
    model, (L, D, H, V, blk) = build_from_ckpt(P, mode=mode, strict=True)
    toks = np.array([[1,2,3,4,5,6,7,8]], dtype=np.int64)
    logits, caches, xf, x, _oc = model.forward(toks, collect=True)
    c = caches[0]
    print(f"[{mode}] L={L} D={D} F={H} V={V} blk={blk} binary_w={model.binary_w}")
    print(f"   logits.logits {logits.shape}, cache keys={list(c.keys())}")
    print(f"   hh {c['hh'].shape}  g1 {c['g1'].shape}  g3 {c['g3'].shape}")
    print(f"   top1(last)={int(logits[0,-1].argmax())}  "
          f"W2 orig {model.P['l0.w2'].shape}  wv(W2) {wv(model,'l0.w2').shape}")
