import mmap, sys

f1 = "/root/models/Qwen3.6-35B-A3B-UD-Q3_K_S-8bit.gguf"
f2 = "/root/models/Qwen3.6-35B-A3B-UD-Q3_K_S-8bit-v2.gguf"

with open(f1, "rb") as a, open(f2, "rb") as b:
    m1 = mmap.mmap(a.fileno(), 0, access=mmap.ACCESS_READ)
    m2 = mmap.mmap(b.fileno(), 0, access=mmap.ACCESS_READ)
    sz = min(len(m1), len(m2))

    CHUNK = 1 << 20  # 1 MB chunks

    for base in range(0, sz, CHUNK):
        end = min(base + CHUNK, sz)
        if m1[base:end] != m2[base:end]:
            # find first diff in this chunk
            for off in range(base, end):
                if m1[off] != m2[off]:
                    print(f"first_diff_at={off}")
                    print(f"v1=0x{m1[off]:02x} v2=0x{m2[off]:02x}")
                    # nearby context
                    print(f"context v1: {m1[off:off+16].hex()}")
                    print(f"context v2: {m2[off:off+16].hex()}")
                    sys.exit(0)
            break
        pct = base * 100 // sz
        if pct % 10 == 0:
            print(f"scan {pct}%", file=sys.stderr, flush=True)
    print("IDENTICAL")
    m1.close(); m2.close()