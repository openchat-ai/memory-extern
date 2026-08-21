import struct, sys
f = open('/root/models/Qwen3.6-35B-A3B-UD-Q3_K_S.gguf','rb')
assert f.read(4)==b'GGUF'
ver = struct.unpack('<I', f.read(4))[0]
n_tensors = struct.unpack('<Q', f.read(8))[0]
n_kv = struct.unpack('<Q', f.read(8))[0]

def read_str(f):
    n = struct.unpack('<Q', f.read(8))[0]
    return f.read(n).decode('utf-8', 'replace')

def read_val(f, t):
    if t == 0: return struct.unpack('<I', f.read(4))[0]
    if t == 1: return struct.unpack('<i', f.read(4))[0]
    if t == 2: return struct.unpack('<I', f.read(4))[0]
    if t == 3: return struct.unpack('<i', f.read(4))[0]
    if t == 4: return struct.unpack('<I', f.read(4))[0]
    if t == 5: return struct.unpack('<i', f.read(4))[0]
    if t == 6: return struct.unpack('<f', f.read(4))[0]
    if t == 7: return struct.unpack('<d', f.read(8))[0]
    if t == 8: return struct.unpack('<Q', f.read(8))[0]
    if t == 9: return struct.unpack('<q', f.read(8))[0]
    if t == 10: return read_str(f)
    if t == 11: return bool(struct.unpack('<I', f.read(4))[0])
    if t == 12:
        at = struct.unpack('<I', f.read(4))[0]
        n = struct.unpack('<Q', f.read(8))[0]
        return [read_val(f, at) for _ in range(n)]
    raise Exception('unknown type '+str(t))

for i in range(n_kv):
    k = read_str(f)
    t = struct.unpack('<I', f.read(4))[0]
    read_val(f, t)

for i in range(n_tensors):
    name = read_str(f)
    n_dim = struct.unpack('<I', f.read(4))[0]
    dims = [struct.unpack('<Q', f.read(8))[0] for _ in range(n_dim)]
    tt = struct.unpack('<I', f.read(4))[0]
    off = struct.unpack('<Q', f.read(8))[0]
    if 'expert' in name.lower() or 'ffn' in name.lower() or 'mlp' in name.lower():
        print(f"{name} type={tt} dims={dims}")