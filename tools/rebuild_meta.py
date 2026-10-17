#!/data/data/com.termux/files/usr/bin/python3
"""rebuild_meta.py — 从旧 packslim 文件 (jlen=0, 无 meta) + 源 GGUF 的 dims 重建 meta.
用法: rebuild_meta.py <packslim> <src_gguf> <bitwidth> <cb1,cb2,...>"""
import sys, os, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mxfp4_regress as M


def main():
    pkt, src, bits = sys.argv[1], sys.argv[2], int(sys.argv[3])
    cb = [float(x) for x in sys.argv[4].split(",")]
    _, infos, _ = M.read_gguf(src)
    qk = M.QK_MXFP4
    bb = 1 + 4 * bits
    with open(pkt, "rb") as f:
        data = f.read()
    jlen = int.from_bytes(data[9:13], "little")
    pos = 17
    tensors = []
    for t in infos:
        if t.type != M.GGML_TYPE_Q8_0 or len(t.dims) < 2 or t.name == "token_embd.weight":
            continue
        nb = int(t.dims[0] * t.dims[1]) // qk
        tensors.append({"name": t.name, "dims": list(t.dims),
                        "bytes": nb * bb, "offset": pos})
        pos += nb * bb
    base = os.path.splitext(os.path.basename(src))[0]
    meta = {"format": f"qxt-Q{bits}T-slim", "bitwidth": bits, "block_elems": 32,
            "block_bytes": bb, "src": base, "n_tensors": len(tensors),
            "codebook": cb, "tensors": tensors}
    jb = json.dumps(meta).encode("utf-8")
    out = bytearray(data[:pos])
    out[9:13] = len(jb).to_bytes(4, "little")
    out += jb
    with open(pkt, "wb") as f:
        f.write(bytes(out))
    print(f"rebuilt {pkt}: {len(tensors)} tensors, {len(jb)}B meta, total {len(out)}B")


if __name__ == "__main__":
    main()