import struct

FN = '/root/models/Qwen3.6-35B-A3B-UD-Q3_K_S.gguf'
SZ = {0:1,1:1,2:2,3:2,4:4,5:4,6:8,7:1}  # ggml_type -> bytes

def r(f, n):
    b = f.read(n)
    assert len(b) == n, f'EOF at {f.tell()}'
    return b

def ru64(f): return struct.unpack('<Q', r(f,8))[0]
def ru32(f): return struct.unpack('<I', r(f,4))[0]
def ri32(f): return struct.unpack('<i', r(f,4))[0]
def rstr(f):
    n = ru64(f); return r(f, n).decode('utf-8', 'replace')

def skip_val(f, vt):
    if vt == 8:  # string
        rstr(f)
    elif vt == 9:  # array
        et = ri32(f); cnt = ru64(f)
        if et == 8:
            for _ in range(cnt): rstr(f)
        elif et in (0,1,7):
            f.seek(cnt, 1)
        else:
            f.seek(cnt * SZ.get(et, 4), 1)
    elif vt in SZ:
        f.seek(SZ[vt], 1)
    else:
        raise ValueError(f'unknown value type {vt}')

with open(FN, 'rb') as f:
    assert r(f,4) == b'GGUF'
    ver = ru32(f); n_t = ru64(f); n_kv = ru64(f)
    print(f'version={ver} n_tensors={n_t} n_kv={n_kv} pos={f.tell()}')
    for i in range(n_kv):
        if i == 0:
            b8 = r(f,8); print(f'KV0 key len raw = {b8.hex()} u64={struct.unpack("<Q", b8)[0]}')
            n = struct.unpack('<Q', b8)[0]
            k = r(f, n).decode('utf-8', 'replace')
        else:
            k = rstr(f)
        vt = ri32(f); skip_val(f, vt)
    off = f.tell()
    print(f'KV end at {off}, tensor info list:')
    infos = []
    for i in range(n_t):
        name = rstr(f)
        nd = ru32(f)
        dims = [ru64(f) for _ in range(nd)]
        ttype = ri32(f)
        toff = ru64(f)
        infos.append((name, dims, ttype, toff))
        if 'exps' in name or 'ssm_out' in name or 'ffn_gate' in name:
            print(f'  {name} dims={dims} type={ttype} offset={toff}')
    print(f'tensor infos parsed: {len(infos)}')
    # data section should start right after; check alignment of first offset
    infos_sorted = sorted(infos, key=lambda x: x[3])
    print('first tensor data offset (min):', infos_sorted[0][3])
    print('gaps sanity (monotonic):', all(infos_sorted[i][3] <= infos_sorted[i+1][3] for i in range(len(infos_sorted)-1)))
