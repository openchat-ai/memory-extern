import struct, sys
f = open('/root/models/Qwen3.6-35B-A3B-UD-Q3_K_S.gguf','rb')
assert f.read(4)==b'GGUF'
ver = struct.unpack('<I', f.read(4))[0]
n_tensors = struct.unpack('<Q', f.read(8))[0]
n_kv = struct.unpack('<Q', f.read(8))[0]
print('GGUF version', ver, 'tensors', n_tensors, 'kv', n_kv)

def read_str(f):
    n = struct.unpack('<Q', f.read(8))[0]
    return f.read(n).decode('utf-8', 'replace')

def read_val(f, t):
    if t == 0: return struct.unpack('<I', f.read(4))[0]      # uint8
    if t == 1: return struct.unpack('<i', f.read(4))[0]      # int8
    if t == 2: return struct.unpack('<I', f.read(4))[0]      # uint16
    if t == 3: return struct.unpack('<i', f.read(4))[0]      # int16
    if t == 4: return struct.unpack('<I', f.read(4))[0]      # uint32
    if t == 5: return struct.unpack('<i', f.read(4))[0]      # int32
    if t == 6: return struct.unpack('<f', f.read(4))[0]      # float32
    if t == 7: return struct.unpack('<d', f.read(8))[0]      # float64
    if t == 8: return struct.unpack('<Q', f.read(8))[0]      # uint64
    if t == 9: return struct.unpack('<q', f.read(8))[0]      # int64
    if t == 10: return read_str(f)                            # string
    if t == 11: return bool(struct.unpack('<I', f.read(4))[0]) # bool
    if t == 12: return struct.unpack('<I', f.read(4))[0]      # array
    raise Exception('unknown type '+str(t))

for i in range(n_kv):
    k = read_str(f)
    t = struct.unpack('<I', f.read(4))[0]
    v = read_val(f, t)
    print(k, '=', v)