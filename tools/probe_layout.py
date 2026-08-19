import struct

def f16(h):
    s = (h >> 15) & 1
    e = (h >> 10) & 0x1F
    m = h & 0x3FF
    if e == 0: return (-1)**s * m / 1024.0 * 2 ** -14
    if e == 31: return float('inf') if m == 0 else float('nan')
    return (-1)**s * (1 + m / 1024.0) * 2 ** (e - 15)

off = 977567744
with open('/root/models/Qwen3.6-35B-A3B-UD-Q3_K_S.gguf', 'rb') as f:
    f.seek(off)
    blk = f.read(400)  # 前 400 字节，覆盖 ~4 个 98B block 或 ~3.6 个 110B block

print("scan for plausible fp16 d at each byte offset (0..399):")
found = []
for i in range(0, 399):
    h = struct.unpack_from('<H', blk, i)[0]
    v = f16(h)
    # 合理 d 量级：1e-5 ~ 1
    if 1e-5 <= abs(v) <= 1.0 and v == v:
        found.append((i, h, v))
# 打印每 98 位置附近的 candidate
for i, h, v in found:
    if i % 2 == 0:
        print(f"  off={i:3d} (mod98={i%98:2d} mod110={i%110:3d}) 0x{h:04x} = {v:.6g}")
