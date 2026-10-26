"""hebb_deliver_build.py — 赫布构造 (HebbBuild, 论文法) 的 Q4T 交付与端到端验证.

方案 (§10.9.5):
  论文白化需 F>>1 (协方差低秩), 只写 2 条时白化退化.
  故: 用 **32 条多样真实事实** (辅助集) 算 Wt=(cov_aux+λI)^-1 做白化,
      但**只写入** 2 条目标事实, 用单点归一化 (norm+wh):
          ΔB = Σ_j c·v_j ⊗ (Wt·φ_j) / |Wt·φ_j|²
  辅助集只提供"key 方向的协方差", 本身不写入.

判据 (同交付口径, 全 6 条 holdout 逐字 vs 基线, 且在**打包后的 GGUF** 上):
  事实 2/2 rank 0  且  holdout 0/6

用法:
  python tools/hebb_deliver_build.py --layers 18-22 --c 80 --lam 0.1 --out out.gguf
"""
import argparse, os, shutil, sys, time
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import qxt_repack as RP
from q1t_stream import StreamEngine, SRC, read_packslim
from hebb_write import HebbWriter

BASE = ("/data/data/com.termux/files/home/models/qxt/"
        "rStar-Coder-Qwen3-0.6B.Q8_0-Q4T_packslim.gguf")
FACTS = [("The largest planet is", "Jupiter"), ("The color of the sky is", "blue")]
HOLD = ["def factorial(n):", "class Point:\n    def __init__", "import os\nos.path.",
        "for i in range(10):", "def quicksort(arr):", "import numpy as np\nnp."]

# 辅助集: 32 条**多样真实**事实 (跨领域, key 互不相同; 数值类 value 非单 token 已剔除)
AUX = [
    ("The capital of France is", " Paris"), ("The largest planet in the solar system is", " Jupiter"),
    ("The chemical symbol for gold is", " Au"), ("The author of Romeo and Juliet is", " Shakespeare"),
    ("The tallest mountain in the world is", " Everest"), ("The largest ocean on Earth is", " Pacific"),
    ("The currency of Japan is", " Yen"), ("The planet closest to the Sun is", " Mercury"),
    ("The gas that plants absorb is", " Carbon"), ("The inventor of the telephone is", " Bell"),
    ("The largest country in the world is", " Russia"), ("The language spoken in Brazil is", " Portuguese"),
    ("The first president of the United States is", " Washington"),
    ("The element with atomic number 1 is", " Hydrogen"),
    ("The longest river in Africa is", " Nile"), ("The continent that contains Egypt is", " Africa"),
    ("The main ingredient in bread is", " Flour"), ("The unit of electrical resistance is", " Ohm"),
    ("The largest mammal is", " Elephant"), ("The ancient wonder in Egypt is", " Pyramid"),
    ("The coldest planet in the solar system is", " Neptune"),
    ("The founder of the Roman Empire was", " Caesar"),
    ("The most common mineral in the Earth's crust is", " Quartz"),
    ("The capital of Japan is", " Tokyo"), ("The largest hot desert is", " Sahara"),
    ("The organ that pumps blood is", " Heart"),
    ("The painting of the Mona Lisa was made by", " Leonardo"),
    ("The largest internal organ is", " Liver"), ("The country that invented paper is", " China"),
    ("The primary color that is not in red yellow blue is", " Green"),
    ("The ship that sank on its maiden voyage was", " Titanic"),
    ("The instrument with 88 keys is", " Piano"),
    ("The metal that is liquid at room temperature is", " Mercury"),
]


def gen(eng, prompt, n_new=12, temperature=0.01):
    ids, _ = eng.generate(prompt, n_new=n_new, temperature=temperature)
    return eng.decode_text(ids)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--layers", default="18-22")
    ap.add_argument("--c", type=float, default=80.0)
    ap.add_argument("--norm-key", action="store_true",
                    help="分母用 phi.pk 而非 |pk|^2 -> key 上读出恒为 C*v (侧支#39)")
    ap.add_argument("--lam", type=float, default=0.1)
    ap.add_argument("--out", required=True)
    ap.add_argument("--base", default=BASE)
    args = ap.parse_args()
    a, b = args.layers.split("-")
    layers = list(range(int(a), int(b) + 1))
    C, LAM = args.c, args.lam
    print(f"[cfg] layers={layers} c={C} lam={LAM} 振幅={C*len(layers):g}", flush=True)

    Ex0 = StreamEngine(slim=args.base, src=SRC, n_ctx=512)
    base_hold = [gen(Ex0, p) for p in HOLD]
    del Ex0

    H = HebbWriter(n_ctx=512)
    E = H.eng
    meta, by = read_packslim(args.base)
    cb = np.asarray(meta["codebook"], np.float32)

    # 目标事实的 phi / value
    tphi, tvid = [], []
    for prompt, target in FACTS:
        toks = np.array(E.encode(prompt), np.int64)
        tphi.append(H.capture_phi(toks))
        tvid.append(H.target_id(target))
    tve = np.stack([H.embed(int(t)) for t in tvid]).astype(np.float32)

    # 辅助集 phi (只算要写的层)
    aux_facts = []
    for kp, v in AUX:
        ids = E.encode(v)
        if len(ids) == 1:
            aux_facts.append((kp, ids[0]))
    print(f"[aux] 可用 {len(aux_facts)} 条 (非单token value 已剔除)", flush=True)
    aux_phi = {i: np.empty((len(aux_facts), H.F), np.float32) for i in layers}
    for j, (kp, _) in enumerate(aux_facts):
        toks = np.array(E.encode(kp), np.int64)
        ph = H.capture_phi(toks)
        for i in layers:
            aux_phi[i][j] = ph[i]
    print("[aux] phi 采集完成", flush=True)

    # 逐层造 Δ (白化 + 单点归一化)
    deltas = {i: np.zeros((H.F, H.d), np.float32) for i in layers}
    for i in layers:
        A = aux_phi[i].astype(np.float64)
        cov = (A.T @ A) / len(A)
        Wt = np.linalg.solve(cov + LAM * np.eye(H.F), np.eye(H.F))
        dB = np.zeros((H.F, H.d))
        for j, (prompt, target) in enumerate(FACTS):
            phi = tphi[j][i].astype(np.float64)
            pk = phi @ Wt
            den = (phi @ pk) if args.norm_key else (pk @ pk)
            dB += np.outer(pk, C * tve[j].astype(np.float64)) / den
        deltas[i] = dB.astype(np.float32)
        del A, cov, Wt, dB
    print("[delta] 完成", flush=True)

    # 重打包
    t0 = time.time()
    shutil.copyfile(args.base, args.out)
    with open(args.out, "r+b") as f:
        for i in layers:
            e = by[f"blk.{i}.ffn_down.weight"]
            W = RP.dequant_tensor(args.base, e, cb)
            f.seek(e["offset"])
            f.write(RP.quant_tensor(W + deltas[i].astype(np.float32), cb))
    print(f"[repack] {len(layers)} 层 {time.time()-t0:.1f}s -> {args.out}", flush=True)

    # 端到端验收
    Ex = StreamEngine(slim=args.out, src=SRC, n_ctx=512)
    ok = True
    print("[事实]", flush=True)
    for j, (prompt, target) in enumerate(FACTS):
        toks = np.array(Ex.encode(prompt), np.int64)
        tgt = H.target_id(target)
        lo, _ = Ex.forward(toks)
        r = int((lo > lo[tgt]).sum())
        g = gen(Ex, prompt, 12)
        ok &= (r == 0)
        print(f"  {prompt!r:26s} -> {target!r:8s} rank {r} {'OK' if r == 0 else 'FAIL'} "
              f"gen {g!r}", flush=True)
    print("[holdout 6 条]", flush=True)
    pol = 0
    for p, b in zip(HOLD, base_hold):
        g = gen(Ex, p, 12)
        if g != b:
            pol += 1
            print(f"  [DIFF] {p!r}\n      base {b!r}\n      new  {g!r}", flush=True)
    print(f"[验收] facts_ok={ok} holdout_pol {pol}/6  "
          f"{'PASS' if (ok and pol == 0) else 'FAIL'}", flush=True)
    return 0 if (ok and pol == 0) else 1


if __name__ == "__main__":
    sys.exit(main())
