"""对照: ① 随机 B vs 外积 B  ② 扫 N 到容量墙  ③ 对比理论 d²/(n logn)=2"""
import numpy as np, sys
sys.path.insert(0,'tools')
from qxt_hebbuild import build, query

V=4000; D=192; F=1024
print(f"D={D} F={F} V={V}")
print(f"{'N':>6} {'外积B':>10} {'随机B':>10} {'比率':>8}")
rng=np.random.default_rng(7)
for N in (100,400,800,1200,2000):
    M=build(N,D,F,V,seed=N)
    hit=sum(int(query(M,int(k)).argmax())==int(v) for k,v in zip(M['keys'],M['vals']))
    # 随机 B 对照
    rngB=np.random.default_rng(N)
    Bsav=M['B']; M['B']=rngB.standard_normal(Bsav.shape).astype(np.float32)
    hitr=sum(int(query(M,int(k)).argmax())==int(v) for k,v in zip(M['keys'],M['vals']))
    M['B']=Bsav
    exp=N/V*N  # 随机期望命中 ≈ N * (1/V) * N? 实际: 随机 B 命中期望 ~ N/V
    print(f"{N:6d} {hit:5d}/{N:<4d} {hitr:5d}/{N:<4d}  {hit/max(1,hitr):6.1f}x")
# 理论容量: F=1024, 单 key 命中需 phi 准正交. 尖峰阈值 d²/(n logn)=2 -> 用 F 代 d
print("\n理论: 论文阈值 d²/(n log n)=2")
for F2 in (1024,):
    for n in (50,100,200,400):
        import math
        val=F2**2/(n*math.log(n))
        print(f"  F={F2} n={n}: d²/(n logn)={val:.1f}  (>>2 表示远未到墙)")
