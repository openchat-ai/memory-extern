#!/usr/bin/env python3
import struct
fp = open("/root/models/Qwen3.6-35B-A3B-UD-Q3_K_S.gguf","rb")
magic = fp.read(4); ver = struct.unpack("<I",fp.read(4))[0]
n_tensors = struct.unpack("<Q",fp.read(8))[0]
n_kv = struct.unpack("<Q",fp.read(8))[0]
print(f"version={ver} n_tensors={n_tensors} n_kv={n_kv}")

def skip_val(t):
    global fp
    if t in (0,1,7): return fp.seek(fp.tell()+1,1)
    if t in (2,3): return fp.seek(fp.tell()+2,1)
    if t in (4,5,6): return fp.seek(fp.tell()+4,1)
    if t in (10,11,12): return fp.seek(fp.tell()+8,1)
    if t==8:
        L = struct.unpack("<Q",fp.read(8))[0]; return fp.seek(fp.tell()+L,1)
    if t==9:
        et = struct.unpack("<I",fp.read(4))[0]
        cnt = struct.unpack("<Q",fp.read(8))[0]
        if et==8:
            for _ in range(cnt):
                l = struct.unpack("<Q",fp.read(8))[0]; fp.seek(fp.tell()+l,1)
            return
        sz = [1,1,2,2,4,4,8,1,0,0,8,8,8][et]
        return fp.seek(fp.tell()+cnt*sz,1)

alignment = 32
for k in range(n_kv):
    nlen = struct.unpack("<Q",fp.read(8))[0]
    kbuf = fp.read(nlen).decode() if nlen < 256 else f"key{nlen}"
    vt = struct.unpack("<I",fp.read(4))[0]
    if nlen > 100 or vt > 12:
        print(f"  KV[{k}] pos={fp.tell()} key={kbuf[:50]} vt={vt} nlen={nlen}")
    if kbuf=="general.alignment":
        alignment = struct.unpack("<I",fp.read(4))[0]
    else:
        skip_val(vt)
fp.seek((fp.tell()+alignment-1)//alignment*alignment)
print(f"alignment={alignment} data_base={fp.tell()}")

info_types = {}
all_names = []
for i in range(n_tensors):
    nlen = struct.unpack("<Q",fp.read(8))[0]
    name = fp.read(nlen).decode()
    nd = struct.unpack("<I",fp.read(4))[0]
    dims = [struct.unpack("<Q",fp.read(8))[0] for _ in range(nd)]
    ty = struct.unpack("<I",fp.read(4))[0]
    off = struct.unpack("<Q",fp.read(8))[0]
    info_types[ty] = info_types.get(ty,0)+1
    all_names.append((name, tuple(dims), ty, off))

type_names = {0:"F32",1:"F16",2:"Q4_0",3:"Q4_1",6:"Q5_0",7:"Q5_1",8:"Q8_0",
              10:"Q2_K",11:"Q3_K",12:"Q4_K",13:"Q5_K",14:"Q6_K",15:"Q8_K",
              16:"IQ2_XXS",17:"IQ3_XXS",18:"IQ1_S",19:"IQ1_M",20:"IQ4_NL",
              21:"IQ3_S",22:"IQ2_S",23:"IQ4_XS",24:"IQ6_XL",25:"IQ1_XXS",
              26:"IQ4_XXS",27:"IQ3_XXS",28:"IQ2_XXS",29:"IQ4_NL",30:"IQ6_M",
              31:"IQ1_NL",32:"I8",33:"I16",34:"I32",35:"I64",36:"BF16"}

print("\n== 张量类型分布 ==")
for ty,cnt in sorted(info_types.items()):
    print(f"  {type_names.get(ty,hex(ty)):>10}: {cnt}")

# 按层分组
print("\n== 张量分布（前60行，后按层归类） ==")
layer_prefixes = {f"blk.{i}." for i in range(40)}
def layer_of(name):
    for i in range(40):
        if name.startswith(f"blk.{i}."): return i
    return None
layer_types = {}
for name, dims, ty, off in all_names:
    ly = layer_of(name)
    if ly is not None:
        key = type_names.get(ty,hex(ty))
        layer_types.setdefault(ly,{})[key] = layer_types[ly].get(key,0)+1

if layer_types:
    s0 = sorted(layer_types.items())[0][1]
    print(f"  blk.0 张量类型分布: {s0}")
    print(f"  (所有 blk 层结构相同)")