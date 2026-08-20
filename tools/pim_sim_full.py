#!/usr/bin/env python3
"""pim_sim_full.py — 全模型 PIM 精度模拟（从 pim_extract_all 二进制流）"""
import sys, json, argparse, subprocess
import numpy as np
from pim_precision_budget import (
    pim_gemv, ref_gemv,
)

EXTRACTOR = "/root/pim_extract_all"

TYPE_NAMES = {
    0:'f32',1:'f16',2:'q4_0',3:'q4_1',6:'q5_0',7:'q5_1',
    8:'q8_0',9:'q8_1',10:'q2_K',11:'q3_K',12:'q4_K',13:'q5_K',
    14:'q6_K',15:'q8_K',16:'iq2_xxs',17:'iq3_xxs',18:'iq1_s',
    19:'iq1_m',20:'iq4_nl',21:'iq3_s',22:'iq2_s',23:'iq4_xs',24:'iq1_xs'
}

CONFIGS = {
    'mxfp4': dict(w_bits=4, dac_bits=10, adc_bits=12, grp=256,
                  cell_var=0.005, col_noise=0.001, w_block=32, w_mxfp4=True),
    'mxfp4_no_noise': dict(w_bits=4, dac_bits=10, adc_bits=12, grp=256,
                           cell_var=0, col_noise=0, w_block=32, w_mxfp4=True),
    'int8': dict(w_bits=8, dac_bits=10, adc_bits=12, grp=256,
                 cell_var=0.005, col_noise=0.001, w_block=32, w_mxfp4=False),
    'int8_blk256': dict(w_bits=8, dac_bits=10, adc_bits=12, grp=256,
                        cell_var=0.005, col_noise=0.001, w_block=256, w_mxfp4=False),
    'int6_blk32': dict(w_bits=6, dac_bits=10, adc_bits=12, grp=256,
                       cell_var=0.005, col_noise=0.001, w_block=32, w_mxfp4=False),
    'ideal': dict(w_bits=None, dac_bits=12, adc_bits=14, grp=256,
                  cell_var=0, col_noise=0, w_block=None, w_mxfp4=False),
    'cell_only_mxfp4': dict(w_bits=4, dac_bits=None, adc_bits=None, grp=256,
                            cell_var=0, col_noise=0, w_block=32, w_mxfp4=True),
    'cell_only_int8': dict(w_bits=8, dac_bits=None, adc_bits=None, grp=256,
                           cell_var=0, col_noise=0, w_block=32, w_mxfp4=False),
    'dac_adc_only': dict(w_bits=None, dac_bits=10, adc_bits=12, grp=256,
                         cell_var=0, col_noise=0, w_block=None, w_mxfp4=False),
}


def run_extractor(gguf, max_rows=0):
    cmd = [EXTRACTOR, gguf]
    if max_rows:
        cmd.append(str(max_rows))
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    return proc.stdout, proc


def parse_tensor(fd):
    hdr = fd.read(4)
    if len(hdr) < 4:
        return None
    nlen = int.from_bytes(hdr, 'little')
    name = fd.read(nlen).decode('utf-8', errors='replace')
    ndims = int.from_bytes(fd.read(4), 'little')
    dims = [int.from_bytes(fd.read(8), 'little') for _ in range(4)]
    typ = int.from_bytes(fd.read(4), 'little')
    n_rows = int.from_bytes(fd.read(8), 'little')
    d0 = int.from_bytes(fd.read(8), 'little')
    n_bytes = n_rows * d0 * 4
    data_raw = fd.read(n_bytes)
    if len(data_raw) < n_bytes:
        return None
    data = np.frombuffer(data_raw, dtype=np.float32).reshape(n_rows, d0)
    return dict(name=name, ndims=ndims, dims=dims, type=typ,
                n_rows=n_rows, d0=d0, data=data)


def classify(name):
    parts = name.split('.')
    layer, role = None, name
    for i, p in enumerate(parts):
        if p == 'blk' and i + 1 < len(parts) and parts[i+1].isdigit():
            layer = f"blk.{parts[i+1]}"
            role = '.'.join(parts[i+2:])
            break
    if not layer:
        layer = 'emb' if 'token_embd' in name else \
                'head' if 'output' in name else 'other'
        role = name
    return layer, role


def sim_tensor(t, cfg, seed):
    w = t['data'].astype(np.float64)
    n_rows, d0 = w.shape
    if t['ndims'] == 1 or d0 < 64:
        return None
    full_n_rows = 1
    for i in range(1, t['ndims']):
        full_n_rows *= t['dims'][i]
    if full_n_rows < 4:
        return None

    rng = np.random.default_rng(seed)
    x = rng.standard_normal(d0).astype(np.float32)

    y_ref = ref_gemv(w, x)
    y_pim = pim_gemv(w, x,
                     cfg.get('w_bits'), cfg.get('dac_bits'), cfg.get('adc_bits'),
                     cfg.get('grp', 256), cfg.get('cell_var', 0),
                     cfg.get('col_noise', 0), cfg.get('w_block'),
                     cfg.get('w_mxfp4', False))

    err = np.abs(y_pim - y_ref)
    rms = np.sqrt(np.mean(y_ref ** 2))
    if rms <= 0:
        return None

    return dict(
        name=t['name'],
        layer=classify(t['name'])[0],
        role=classify(t['name'])[1],
        shape=t['dims'],
        typ=TYPE_NAMES.get(t['type'], f't{t["type"]}'),
        d0=d0, n_rows=n_rows,
        max_e=max(err) / rms,
        p95_e=np.percentile(err, 95) / rms,
        p50_e=np.percentile(err, 50) / rms,
    )


def aggregate(results):
    out = {}
    if not results:
        return out
    vals = np.array([r['max_e'] for r in results])
    out['total'] = dict(n=len(results),
                        max=vals.max(), p95=np.percentile(vals, 95),
                        p50=np.percentile(vals, 50), p25=np.percentile(vals, 25))

    def group(key):
        g = {}
        for r in results:
            g.setdefault(r[key], []).append(r['max_e'])
        rows = []
        for k, v in sorted(g.items(), key=lambda x: max(x[1]), reverse=True):
            a = np.array(v)
            rows.append(dict(key=k, n=len(v),
                             max=a.max(), p95=np.percentile(a, 95),
                             p50=np.percentile(a, 50)))
        return rows

    out['by_layer'] = group('layer')
    out['by_role'] = group('role')
    out['by_type'] = group('typ')
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('gguf')
    ap.add_argument('--max-rows', type=int, default=0)
    ap.add_argument('--config', '-c', default='mxfp4',
                    choices=list(CONFIGS.keys()))
    ap.add_argument('--json', '-j')
    args = ap.parse_args()

    cfg = CONFIGS[args.config]
    print(f"PIM [{args.config}]: {cfg}", file=sys.stderr)
    print(f"max_rows={args.max_rows}", file=sys.stderr)

    stdout, proc = run_extractor(args.gguf, args.max_rows)

    results = []
    n = 0
    while True:
        t = parse_tensor(stdout)
        if t is None:
            break
        n += 1
        st = sim_tensor(t, cfg, seed=n)
        if st:
            results.append(st)
        if n % 100 == 0:
            print(f"  processed {n}", file=sys.stderr)

    stdout.close()
    proc.wait()

    print(f"\n== total: {n} tensors, {len(results)} simulated ==")
    agg = aggregate(results)
    if 'total' in agg:
        tot = agg['total']
        print(f"  max_err/RMS: max={tot['max']:.2e}  p95={tot['p95']:.2e}  p50={tot['p50']:.2e}")

    print(f"\n  By layer:")
    for row in agg.get('by_layer', [])[:20]:
        print(f"    {row['key']:>20s}  n={row['n']:>4d}  max={row['max']:.2e}  p50={row['p50']:.2e}")
    print(f"\n  By role (top 20 by max_err):")
    for row in agg.get('by_role', [])[:20]:
        print(f"    {row['key']:>35s}  n={row['n']:>4d}  max={row['max']:.2e}  p50={row['p50']:.2e}")
    print(f"\n  By source quant type:")
    for row in agg.get('by_type', []):
        print(f"    {row['key']:>12s}  n={row['n']:>4d}  max={row['max']:.2e}  p50={row['p50']:.2e}")

    if args.json:
        payload = dict(config=args.config, pim_config={k: v for k, v in cfg.items() if not isinstance(v, bool)},
                       total_n=n, simulated_n=len(results), agg=agg,
                       per_tensor=results)
        with open(args.json, 'w') as f:
            json.dump(payload, f, indent=2, default=float)
        print(f"\nJSON -> {args.json}")


if __name__ == '__main__':
    main()