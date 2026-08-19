import mmap, sys

f1 = "/root/models/Qwen3.6-35B-A3B-UD-Q3_K_S-8bit.gguf"
f2 = "/root/models/Qwen3.6-35B-A3B-UD-Q3_K_S-8bit-v2.gguf"

with open(f1, "rb") as a, open(f2, "rb") as b:
    m1 = mmap.mmap(a.fileno(), 0, access=mmap.ACCESS_READ)
    m2 = mmap.mmap(b.fileno(), 0, access=mmap.ACCESS_READ)
    sz = min(len(m1), len(m2))
    CHUNK = 64 * (1 << 20)  # 64 MB
    data_off = 10990048

    data_diff_byte = None
    for base in range(data_off, sz, CHUNK):
        end = min(base + CHUNK, sz)
        if m1[base:end] != m2[base:end]:
            for off in range(base, end):
                if m1[off] != m2[off]:
                    data_diff_byte = off
                    break
            break

    if data_diff_byte is None:
        print(f"TENSOR_DATA: IDENTICAL ({(sz-data_off)//(1<<20)} MB from offset {data_off})")
    else:
        print(f"TENSOR_DATA_DIFF at byte {data_diff_byte}")
        print(f"  v1: {m1[data_diff_byte:data_diff_byte+32].hex()}")
        print(f"  v2: {m2[data_diff_byte:data_diff_byte+32].hex()}")
    m1.close(); m2.close()