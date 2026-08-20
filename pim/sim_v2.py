#!/usr/bin/env python3
import struct
import argparse

GB = 1e9
CHIP = dict(mac=256, bw=68.3, power=15.5, clock=1.0)
EXPERT_COUNT = 256
EXPERT_ACTIVE = 8
TOKENS = 703
GGUF_DEFAULT = "/root/models/Qwen3.6-35B-A3B-UD-Q3_K_S.gguf"


def load_gguf(path):
    fp = open(path, "rb")
    fp.read(4)
    fp.read(4)
    n_tensors = struct.unpack("<Q", fp.read(8))[0]
    n_kv = struct.unpack("<Q", fp.read(8))[0]

    def skip_val(t):
        nonlocal fp
        if t in (0, 1, 7):
            return fp.seek(1, 1)
        if t in (2, 3, 13):
            return fp.seek(2, 1)
        if t in (4, 5, 6):
            return fp.seek(4, 1)
        if t in (10, 11, 12):
            return fp.seek(8, 1)
        if t == 8:
            L = struct.unpack("<Q", fp.read(8))[0]
            return fp.seek(L, 1)
        if t == 9:
            et = struct.unpack("<I", fp.read(4))[0]
            cnt = struct.unpack("<Q", fp.read(8))[0]
            if et == 8:
                for _ in range(cnt):
                    l = struct.unpack("<Q", fp.read(8))[0]
                    fp.seek(l, 1)
                return
            sz = [1, 1, 2, 2, 4, 4, 8, 1, 0, 0, 8, 8, 8][et]
            return fp.seek(cnt * sz, 1)

    alignment = 32
    for _ in range(n_kv):
        nlen = struct.unpack("<Q", fp.read(8))[0]
        kbuf = fp.read(nlen).decode()
        vt = struct.unpack("<I", fp.read(4))[0]
        if kbuf == "general.alignment":
            alignment = struct.unpack("<I", fp.read(4))[0]
        else:
            skip_val(vt)

    tens = []
    for _ in range(n_tensors):
        nlen = struct.unpack("<Q", fp.read(8))[0]
        name = fp.read(nlen).decode()
        nd = struct.unpack("<I", fp.read(4))[0]
        dims = [struct.unpack("<Q", fp.read(8))[0] for _ in range(nd)]
        ty = struct.unpack("<I", fp.read(4))[0]
        off = struct.unpack("<Q", fp.read(8))[0]
        nparam = 1
        for d in dims:
            nparam *= d
        tens.append([name, nparam, off])
    info_end = fp.tell()
    fp.close()

    import os
    fsize = os.path.getsize(path)
    data_base = (info_end + alignment - 1) // alignment * alignment
    for i, t in enumerate(tens):
        nxt = tens[i + 1][2] if i + 1 < len(tens) else fsize - data_base
        t.append(nxt - t[2])
    return [(name, nparam, size) for name, nparam, off, size in tens]


def active_ratio(name):
    if "exps" in name:
        return EXPERT_ACTIVE / EXPERT_COUNT
    if name == "output.weight":
        return EXPERT_ACTIVE / EXPERT_COUNT
    if name == "token_embd.weight":
        return 0.0
    return 1.0


def layer_of(name):
    if name.startswith("blk."):
        return int(name[4:name.index(".", 4)])
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--gguf", default=GGUF_DEFAULT)
    ap.add_argument("--mac", type=int, default=256,
                    help="每芯片 MAC 数 (算力富余口径默认 256, 所有精度带宽墙主导; "
                         "34 为 bf16 配平点, 不算力墙)")
    ap.add_argument("--cpu-tok", type=float, default=None,
                    help="CPU 实测 tok/s (默认: 3.33 t=8 / 4.1 t=16 实测值)")
    ap.add_argument("--cpu-label", default="WSL llama.cpp t=8 (timing-controlled r3)")
    args = ap.parse_args()
    CHIP["mac"] = args.mac

    tens = load_gguf(args.gguf)

    layer_mac = {}
    layer_q3 = {}
    layer_trunk_q3 = {}
    layer_exps_q3 = {}
    out_mac = 0.0
    out_q3 = 0.0
    for name, nparam, size in tens:
        ar = active_ratio(name)
        mac = nparam * ar
        ly = layer_of(name)
        if ly is not None:
            layer_mac[ly] = layer_mac.get(ly, 0.0) + mac
            layer_q3[ly] = layer_q3.get(ly, 0.0) + size * ar
            if "exps" in name:
                layer_exps_q3[ly] = layer_exps_q3.get(ly, 0.0) + size * ar
            else:
                layer_trunk_q3[ly] = layer_trunk_q3.get(ly, 0.0) + size * ar
        elif name != "token_embd.weight":
            out_mac += mac
            out_q3 += size * ar

    nlayers = len(layer_mac)
    total_mac = sum(layer_mac.values()) + out_mac
    bf16_gb = total_mac * 2.0 / GB
    int4_gb = total_mac * 0.5 / GB
    q3_gb = (sum(layer_q3.values()) + out_q3) / GB

    cpu_tok = args.cpu_tok if args.cpu_tok is not None else 3.33

    def layer_times(mac_per_layer, bytes_per_layer, n):
        bw = CHIP["bw"] * n
        mc = CHIP["mac"] * n * CHIP["clock"]
        t_bw = bytes_per_layer / (bw * 1e9)
        t_mac = mac_per_layer / (mc * 1e9)
        return t_bw, t_mac

    def walls(gb_per_tok, n):
        bw = CHIP["bw"] * n
        mc = CHIP["mac"] * n * CHIP["clock"]
        bw_wall = bw / gb_per_tok
        comp_wall = mc * 1e9 / total_mac
        return bw_wall, comp_wall

    mac_per_layer = total_mac / nlayers
    chip_counts = [1, 4, 8, 14]
    print("=" * 78)
    print(f"Qwen3.6-35B-A3B-UD (Q3_K_S) 芯片 vs CPU 逐层时序对比")
    print(f"模型: {nlayers} 层 MoE, {EXPERT_COUNT} 专家×{EXPERT_ACTIVE}激活, "
          f"GGUF {args.gguf.split('/')[-1]}")
    print(f"每 token MAC = {total_mac/1e9:.3f} GMAC "
          f"(层 {mac_per_layer/1e6:.1f} MMAC/层 ×{nlayers} + output {out_mac/1e6:.1f} MMAC)")
    print(f"每 token 字节口径: bf16 {bf16_gb:.3f} GB | int4 {int4_gb:.3f} GB "
          f"| Q3_K实际 {q3_gb:.3f} GB")
    print(f"芯片: {CHIP['mac']} MAC @{CHIP['clock']}GHz / {CHIP['bw']} GB/s / "
          f"{CHIP['power']}W; GEMV bytes/MAC=2B (bf16)")
    print(f"  口径说明: MAC={CHIP['mac']} 为算力富余设计(非配平), 瓶颈=带宽墙; "
          f"34 MAC 是 bf16 配平点(68.3GB/s÷2B), 不代表物理墙")
    print("-" * 78)
    print("CPU 参照: llama.cpp 本机实测")
    print(f"  t=8 : 3.33 tok/s (timing-controlled.log r3 native 30005ms/100tok)")
    print(f"  t=16: 4.1  tok/s (qe5 全 run: 703 token 至 EOS)")
    print("-" * 78)

    for prec, gb in (("bf16", bf16_gb), ("int4", int4_gb), ("Q3_K实际", q3_gb)):
        print(f"\n== {prec} 口径 (每 token {gb:.3f} GB) ==")
        print(f"{'n颗':>4} {'带宽墙':>8} {'算力墙':>8} {'逐层Σmax':>9} "
              f"{'理想流水':>9} {'实际tok/s':>9} {'功耗W':>7} {'tok/s/W':>8}")
        for n in chip_counts:
            bw_wall, comp_wall = walls(gb, n)
            ml_b, ml_m = layer_times(mac_per_layer, gb * GB / nlayers, n)
            t_layer = max(ml_b, ml_m)
            t_ideal = max(gb * GB / (CHIP["bw"] * n * 1e9), total_mac / (CHIP["mac"] * n * CHIP["clock"] * 1e9))
            tok_sigma = 1.0 / (t_layer * nlayers)
            tok_ideal = 1.0 / t_ideal
            actual = min(bw_wall, comp_wall)
            wall = "算力墙" if comp_wall <= bw_wall else "带宽墙"
            power = CHIP["power"] * n
            eff = actual / power
            print(f"{n:>4} {bw_wall:>8.1f} {comp_wall:>8.1f} {tok_sigma:>9.1f} "
                  f"{tok_ideal:>9.1f} {actual:>9.1f} {power:>7.1f} {eff:>8.2f}   [{wall}]")

    print(f"\n== 与 CPU 对比 (t=8: {cpu_tok:.2f} tok/s) ==")
    cpu_e2e = TOKENS / cpu_tok
    print(f"CPU 端到端 {TOKENS} token: {cpu_e2e:.0f}s ({cpu_e2e/60:.1f} min)")
    for n in chip_counts:
        bw_wall, comp_wall = walls(q3_gb, n)
        tok = min(bw_wall, comp_wall)
        e2e = TOKENS / tok
        print(f"芯片×{n} (Q3_K实际): {tok:.1f} tok/s, 端到端 {e2e:.0f}s "
              f"({e2e/60:.1f} min) = CPU的{tok/cpu_tok:.1f}×")
    print("=" * 78)


if __name__ == "__main__":
    main()