#!/data/data/com.termux/files/usr/bin/python3
"""backfill_codebook.py — 给已生成的 packslim 文件补 codebook 到 meta (尾部 JSON).
用法: backfill_codebook.py <file> <cb0,..cbN-1>"""
import sys, os, json


def main():
    path = sys.argv[1]
    cb = [float(x) for x in sys.argv[2].split(",")]
    with open(path, "rb") as f:
        data = f.read()
    assert data[:9] == b"QXTSLIM1\n"
    jlen = int.from_bytes(data[9:13], "little")
    if jlen and data[-jlen:].startswith(b"{"):
        meta = json.loads(data[-jlen:].decode())
    else:
        print("warn: no readable meta tail, rebuilding empty", flush=True)
        meta = {"format": "qxt-slim", "bitwidth": int(len(cb).bit_length() - 1),
                "block_elems": 32, "src": "unknown", "n_tensors": 0,
                "tensors": []}
    meta["codebook"] = cb
    if "bitwidth" not in meta:
        meta["bitwidth"] = int(len(cb).bit_length() - 1)
    jb = json.dumps(meta).encode("utf-8")
    out = bytearray(data[:-jlen] if jlen else data)
    out[9:13] = len(jb).to_bytes(4, "little")
    out += jb
    with open(path, "wb") as f:
        f.write(bytes(out))
    print(f"patched {path}: bitwidth={meta.get('bitwidth')} "
          f"codebook={cb}")


if __name__ == "__main__":
    main()