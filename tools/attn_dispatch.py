#!/usr/bin/env python3
# K3 注意力权重精确拆解: KDA(69) vs MLA(24), 支持 原始bf16 / MXFP4 双口径
# 用途: 量化「蒸馏替身接管 KDA」能省多少 / 剩余墙在哪
HIDDEN=7168
B=2

def kda_specs():
    NH,HD=96,128
    proj=HIDDEN*NH*HD
    return {
      "qkv":3*proj, "o":NH*HD*HIDDEN,
      "conv":3*HD*NH*4, "small":HIDDEN*HD+HD*NH*HD+HIDDEN*NH+HIDDEN*HD*HD+NH+HD*HD,
      "state":NH*HD*HD,
    }

def mla_specs():
    QL,KV,NOPE,ROPE,V,NH=1536,512,128,64,128,96
    return {"q_a":HIDDEN*QL,"q_b":QL*NH*NOPE,"kv_a":HIDDEN*(KV+ROPE),
            "kv_b":KV*NH*(NOPE+ROPE),"o":NH*V*HIDDEN}

def report(name="原始 bf16", bits=16):
    b=bits/8
    k=kda_specs(); m=mla_specs()
    kda=(sum(k.values())-k["state"])*69*b
    mla=(sum(m.values()))*24*b
    state=k["state"]*69*b
    print(f"=== {name} ===")
    print(f"KDA 69层: {kda/1e9:.2f} GB (每层 {kda/69/1e6:.1f} MB)")
    print(f"MLA 24层: {mla/1e9:.2f} GB")
    print(f"注意力合计: {(kda+mla)/1e9:.2f} GB")
    print(f"KDA 状态S(数据): {state/1e6:.0f} MB")
    print(f"A_log: 96x69={96*69} 标量")

if __name__=="__main__":
    report("原始 bf16(16bit)")
    try:
        report("MXFP4(4bit, 设想)", 4)
    except: pass
