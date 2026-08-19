import struct

def fp16_to_fp32(h):
    s = (h >> 15) & 1
    e = (h >> 10) & 0x1F
    m = h & 0x3FF
    if e == 0:
        return (-1)**s * m / 1024.0 * (2 ** -14)
    if e == 31:
        return float('inf') if m == 0 else float('nan')
    return (-1)**s * (1 + m / 1024.0) * (2 ** (e - 15))

off = 10990048 + 977567744   # 官方 gguf_init data_offset + tensor offset
bsz = 98
with open('/root/models/Qwen3.6-35B-A3B-UD-Q3_K_S.gguf', 'rb') as f:
    f.seek(off)
    b = f.read(bsz)
    print('block0 raw:', ' '.join('%02x' % x for x in b))
    f.seek(off + 784)
    b = f.read(98)
    print('row1 block0 raw:', ' '.join('%02x' % x for x in b))
    nz = sum(1 for x in b if x != 0)
    print('row1 block0 nonzero bytes:', nz, '/98')
