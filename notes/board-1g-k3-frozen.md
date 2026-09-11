# Tang 1GB 板 · K3 推理设计冻结基线 (2026-09-09)

> 硬件: Tang Mega 138K Pro (GW5AST-138) + Dock。板载 1GB DDR3(512MB×2, ~5.3GB/s)在 SOM
> 底面(BTB 叠装, 正面不可见)。M.2 NVMe ~3.5GB/s 持续。FPGA 硬核 PCIe。
> 用途: 1K 上下文聊天/写代码。书 → 逐章 ≤1K 块 + KV 迁主机; 或宿主微边。

## 1. 1GB 的职责定位(冻结)

1GB 不是权重仓库, 也不是状态仓 —— 它是**纯层流暂存**(瞬态)。
- 批内暂存: 层切片读一次喂整批, 用完即弃
- 常驻? trunk 全量 55.6GB 装不下; router 1.18GB(BF16) 与层工作集共存打架 → 无常住对象
- **持久状态(KDA S 208MB + S_b 48MB + KV 28MB ≈ 284MB/序列)与 913MB 瞬态撞车 → 也必须上主机**(§5)
- trunk 全量「高频近放」的正确家 = 主机 DDR(微边 Gen5 64GB/s) 或 192GB LPDDR 池

## 2. 层拆解(逐层, 冻结)

93 层固定花纹 = 23×(v1 v1 v1 v2) + 末层 v2(92)。计数: 69×v1 + 24×v2。

| 层型 | 层号 | 元素(M) | trunk/层(MXFP8) | 职责 |
|---|---|---|---|---|
| v1/KDA | 69 层 | 627.1 = attn 440.4 + MoE 183.5 + b/f 3.2 | **632 MB** | 线性注意力, 无 KV |
| v2/Gated-MLA | 24 层 | 415.7 = attn 232.2 + MoE 183.5 | **419 MB** | 全局注意力, 只它产 KV |

元素→字节: × 8.0625/8(每元素 8bit 码 + per-128 scale)。
对账: 69×632 + 24×419 ≈ 52.5GB 量化主体 + 白名单 BF16/F32 ≈ 55.6GB ✓

> 注: 632/419 未含 router gate(每层 896×7168≈6.5MB BF16 白名单)与 e_score 偏置, 在 1.2GB 白名单余量内。

## 3. 头/实体分离(eere 修正, 冻结)

trunk 内每层 `routed_expert [3584×7168]×2 ≈ 51M` 元素是**路由头/索引**(记录本层 896 专家在实体库的 offset)。
专家**实体** 17.55MB/个 × 896 ≈ 15.7GB/层, 存在独立 1413GB 专家库, 不在 trunk 里。
⇒ 装配流程: 读头 → 按 offset 顺序拉 top-16 实体 → 281MB 专家槽。

## 4. 逐层流水 + 执行序(算一层换一层, 冻结)

**执行序(2026-09-09 讲清):** 批量 token **同层同步** —— 先全过层 0, 再全过层 1, ...
**绝不是**"token1 跑完 93 层再 token2"。在层 90 只有 S[90] 在动, 前 89 层的 S 一个都不碰。
层切片(632MB)只读一次喂整批 → **55.6MB/token 摊销的全部来源**。

```
预填/上下文(1K token):  层0: 整批过+更新S[0] → 层1 → ... → 层92   (每层状态恰好用一次)
生成(decode):           每出1字 = 新一轮 0..92(自回归深度所迫), 但同样逐层局部
```

```
板上(瞬态): 当前层切片(632/419MB) + 本层 top16 专家(281MB) + S_b 48MB + 隐藏态
主机(家):   KDA 状态 + KV
for 层 in 1..93: 灌切片(从 NVMe/主机) → 读头→拉专家 → 整批过层 → 切片即弃
             本层 S[L] 搭切片流进(3MB), 算完 S'[L] 3MB 写回拉走 —— 板上零常驻
```

换层传输耗时(NVMe 3.5GB/s): v1 632MB ≈ 0.18s; v2 419MB ≈ 0.12s。
- 无批(batch1, 每字独走): 无覆盖, 93×0.18 ≈ 16.7s/字 = 吞吐墙
- 预填/批 N: 每层计算秒级, 传输完全藏在计算下(双缓冲), 墙换到算力/带宽
- decode 每字一轮 0..92, 状态随切片往返(读3+写3 MB/层), 板上零常驻

## 5. 内存账(修正版: 逐层流 + 真常驻, 2026-09-09)

**状态 = 层流的一部分, 不是内存居民。** KDA S(208MB)与 KV(28MB@1K)严格按层序、
每层恰好一次访问(逐层读→算完→写回)。**S[L] 与权重别无二致 —— 同为层流节:**
`[S[L] 3MB 读][权重 632MB][S'[L] 3MB 写]`(权重只读、S 读改写, 仅此差异)。
板上任何时刻只有"当前层"的 ~3MB/~1MB 在动;
第 1~89 层的 S 此刻用不上, 纯粹躺在"家"(主机 DDR / 板上 M.2 NVMe)里存着, 下次扫层再流回来。
S_b(48MB)是唯一例外: 每层 K/V 投影都读它, 无法按层分段 → 板上真常驻。

层流格式: `每层切片 = [S[L] 3MB][权重 632MB]` —— 从家拉, 算完写回 S'[L]。

**写回走"变更攒批"(2026-09-09 定):** KDA 更新是秩1外积 S←S+k⊗v^T。
板上不写回 3MB 全量, 只发 k,v 向量对(每 v1 层 96头×2×128×2B = **49KB**);
69 层合起来 = **3.4MB/token**(vs 全量 279MB, 掉 80 倍)。
主机 RAM 攒着, token 跑完一次性物化(S←S+Σk⊗v, 微秒级, 逐位同立即写)。
⇒ 前提是"家会算": 只有主机 RAM 做得了 —— NVMe 物化=读改写, 双倍I/O+双倍磨损, 再补一刀 M.2 型。
读取卷不变(3MB/层), 但读只有 ~1% 且不磨盘; 被消灭的是写卷与磨损。

**回写总清单(2026-09-09, 除 KDA S 外只有 3 处):**
| 数据 | 回写量 | 时机 |
|---|---|---|
| KDA S(v1, 69层) | 3.4MB/token(秩1 diff) | 每 token 攒, 整轮后主机物化 |
| KV(v2, 24层) | **12.75KB/token（INT8 latent 512 + 4bit rope 64）**, append-only | 每 token(decode)/每 chunk(prefill) |
| S_b(48MB) | 48MB | 会话切换/换章/暂停(非每 token) |
| 会话检查点 | ~284MB(S+KV+S_b+末隐藏) | 暂停/恢复前低频 |
| 其余(权重/实体/router/e_score/头) | 全程只读, 无回写 | - |

⇒ decode 每字回写 ≈ **3.4MB(KDA)+ 12.8KB(KV)≈ 3.41MB**, 全部只进主机 RAM。

**板上 KV 写回定案(2026-09-10, 实证 K3_KV_QUANT_PROBE.md)**: latent 512 INT8(每 token 1 scale) + rope 64 4bit。
12.75KB/token = 24层 × (512×1B + 64×0.5B), argmax 99.0% / 能量 8.6%; rope 4bit 0 损失。
逐 token 累积验证: per-token 独立 scale 不随 cache 长度累积(per-cache 对照实验证伪累积)。

**板→主机写回路径(2026-09-09 改: 转载站 → DMA 弹性 FIFO)**: 片上不再攒批 ——
  每层 diff(49KB)算完即推 DMA 弹性 FIFO(**128KB ≥ 单笔最大 payload 49KB**, 异步无阻塞),
  攒批/合并搬去主机侧。49KB 已是高效 PCIe burst, 板上 0.5MB/s(3.41MB/token×0.15t/s)
  的涓流不需要大数组(承 SRAM 域预算: 慢任务不许绑快资源); sim 验证:
  FIFO<单笔49KB 结构性顶穿, 主机写 ≥ 266MB/s(预填峰产出率)即零停顿, decode 仅 0.3MB/s。
  ⚠ 边界: S_b(48MB)与当前层 S(3MB)都进不了 765KB —— SRAM 是 MAC 热存储池, 不是家。

**层流写回协议 v0(2026-09-09 草案, 喂 P1 SDMA / 主机模拟器):**

```
每 token 一轮 0..92, 板上每层至多产一块 payload, 严格层序推送:

| 字段        | 字节                     | 说明                          |
| 层号+类型   | 4                       | v1=diff / v2=KV-append         |
| 头偏移/长度 | 4                       | 96 头分组粒度                  |
| payload     | v1: 49KB / v2: 24×544B | v1=96×(k 128+v 128)×2B 向量对; v2=latent 512×1B + rope 64×0.5B |

机制:
- 顺序  : 每 token 严格层序; 层 L 的 payload 必在层 L+1 前到 host
- 流控  : FIFO 阈值 50% → 层算完不推, 等 credit(主机常闲, 预期不触发)
- 物化  : host 收到层 L diff 即 S[L] += Σ_h k_h⊗v_h^T(96 头 ×16K FMA ≈ µs),
          diff 即用即弃 —— 不攒整 token/整批; 并行于板上层 L+1 计算
- KV    : append-only, host 按 24 层 × 544B(=512×1B latent INT8 + 64×0.5B rope 4bit) 落 pinned 区, 与权重读双流
- barrier: 层 92 结束 = token 完成, host ACK 后才许下一 token 头写回
- 节奏  : 预填(每层 N×49KB, 批量物化) vs decode(每层 49KB, 逐层物化)
          —— 模拟器两条线都跑, 用字节序对账
```

**RTL 落点(2026-09-10):** v2 层 KV 写回件 = `rtl/27_kv_writeback/kv_writeback.v`
(两遍 pass: 全 token 累计求 token 级 scale → 逐层 552B 帧 = 8B 头 + 512 latent INT8 +
32 打包 rope 4bit; credit(阈值 50%)门限 + 严格层序 order 校验, T0/T1 双场景字节序对账全绿)。
v1 层 49KB diff 写回件 = `rtl/28_wb_diff/wb_diff.v`
(v1 层秩1 diff 49,160B/帧 = 8B 头 + 96×(k128+v128)×2B, 逐层即推、无量化单 pass,
credit 弹性 FIFO + 层序 barrier + round 轮序, 真尺寸对账 6.78MB/2 token 全绿)。
**统一写回引擎 = `rtl/29_wb_unified/wb_unified.v`** —— 与 sim_layer_flow.py 执行序同构:
每 token 一 go = 93 帧严格层序 0..92 (69×diff 49,160B + 24×KV 552B, 层型 = l%4==3 | 末层),
pass0 全 token v2 KV 峰 → token 级 scale, pass1 混排推帧, layer92 完工 token_done(barrier),
真尺寸 2 token 字节序对账 6,810,576B 全绿(T1 真停顿 3 次, occ 钉 2048 无违例)。
SDMA 侧直接复用之。
**KV 读回件 = `rtl/30_kv_restore/kv_restore.v`** —— 写回协议 v0 的读侧镜像:
decode v2 注意力消费 host 缓存的逐 token KV (append-only, 1K 窗),
每 token 24 层帧严格层序 552B/帧 (布局 ≡ M14 写者实发字节: 8B 头 + 512 latent INT8
+ 32 rope 4bit 包), credit 弹性背压挂起记 stall 不丢字节, 头 8B 逐字段自验。
真尺寸 2 token 字节序对账 26,496B 全绿(T1 真停顿 2 次, occ 钉 2048 无违例)。
**S[L] 层流灌入件 = `rtl/31_sloader/sloader.v`** —— 写回协议 v0 的 S 侧读回镜像:
decode KDA 消费前, S[L] = 96头×128×128 BF16 按层流灌入 SRAM 域 (3,145,728B/层),
head 完工 = barrier, 层完工 = barrier, credit 弹性背压挂起记 stall 不丢字节,
严格 head×window 粒序。FAST(T1 真停顿 2 次, occ 钉 2048 无违例)全绿。
**M14×M15 loopback = `rtl/30_kv_restore/wb2kv_loop_tb.v`** —— 写者直接吐字节给读回件:
wb_unified 93 层混排 f_b → kv_restore s_kv 字节闭环, push_pl_lay 对齐 NBA 延迟防 v2
误判, 2 token 对账 wb225,768B / r13,248B 零差零违例, T1 真停顿 3 次全绿。
**M16×M11 跨件联调 = `rtl/32_sched_sload/sched_sload_tb.v`** —— S[L] 灌入件直连层执行件:
sloader→切片库(双槽)→sched_exec{GEMM段+attn段+释放} 单链闭环, 让位门纪律
(层 L+2 落槽 L&1 前需见层 L 释放, credit 弹性背压 => sloader 停顿 1117 拍), 释放序
严格 0..NL-1, GEMM 段逐词对账切片字=灌入元素序(32bit 词=连续 2×16bit 元素, 含末层
轮号交接: 顶层取灌填轮 L&1 槽而非当前 round), acc 双账 sacc=gemm 公式=attn osum 闭合,
FAST(NL=4/HEADS=2/DIM=4 ⇒ 32 元素/层 ⇒ GW=16)全绿。
**M17 router 先行 = `rtl/33_router_sel/router_sel.v`** —— e_score 灌入→top-T 选择件:
先选后抽 (gate+score 装载才动实体流), 层内流序=专家号 0..EX-1 严格单调 (灌收序=流序),
top-T 表插入 key {score,~idx} 降序 (平局 idx 小者先), 层收齐吐表 → 装配侧 out_take
手拉手 → layer_done(barrier) → NL 层 → token_done → round++。credit 弹性背压 (吸期断信用
记 stall); 装配侧慢取 + 灌入侧断信用双向背压, 各层 top-T 黄金逐行对账零错位零重号
(源四连同分逼平局断序), FAST(EX=32/TOP=8/NL=3, 停顿30拍)全绿。
**M18 专家装配 = `rtl/34_assembler/assembler.v`** —— router top-T 选出 →
按 (层,实体号) 从切片 LUT 逐实体取 EW 词依序吐流; 层内严格保序 (选中序=吐流序,
实体块非按号连续, 翻 ep 时跳址 bebase 而非 +1); 装配侧背压 (out_take 1-in-2 记
停顿) + 上游断灌 (TAKE 期 in_valid 暂降, 不丢不序), 层 barrier, NL 层完工
token_done → round++。FAST(EX=32/TOP=8/EW=8/NL=3, 词192, 停顿64拍)全绿。
**M19 输出头 = `rtl/35_output_head/output_head.v`** —— 每 decode 步扫词表 logits
流取 top-K: 有符号比较, 平局 idx 小者先 (stable, 表按 token 重置哨兵最小), 全流扫完
依序吐 K 个 → TN token → token_done → round++; 扫描期上游断流 + 吐期下游慢取记
停顿, 不丢不序。FAST(TN=3/VOC=32/K=3, 扫96, 停顿9拍)全绿。
**M20 选→装配链 = `rtl/36_route_asm/route_asm.v`** —— router 先行 + 专家装配 两级链
(装配前端整块): 每层 e_score(credit) → router 选 top-T → 吐表逐条直交 assembler →
依选中序拉实体块吐流; 源侧层屏障(上一层装配拉完才灌下一层 e_score), router 在
COLL 自行等待; 双侧 round++/token_done 同到。L1 选侧断信用(停顿6拍) + L2 装配侧
慢取(停顿64拍)不丢不序, FAST(吐词192/选条24, 序违例0)全绿。
**M21 P2 算闭环骨架 = `rtl/37_p2_loop/`** —— 选→装配→层引擎→输出头 四级链 (完整
解码一步): engine_stub 消费装配词流逐层求和 (每层 TOP*EW 词 → 层屏障=源放行),
NL 层全完 token_done → 输出头依 acc 派生 logits 扫 VOC 取 top-K (= 会话出口)。
背压: L1 选侧断信用(r停)、L2 引擎侧 1-in-2(a停)、吐期 OH 慢取(oh停) 不丢不序;
FAST(引擎词192/acc=c380/选条24/top-K扫64吐3, 四侧 round==1)全绿。至此本环境
P2 算全链路控制骨架闭环: M16&M11 引擎段被视为真机外部件, 余下实体级 RTL 均随
P1 打包。
**M22 词表剪枝候选集 = `rtl/38_vocab_prune/`** —— 输出头全量扫过贵的廉价代理缩
窗 (给 M19 的 "词表剪枝候选集验证随 PC 数据" 补齐机制侧): 词表按组 (GRP=8), 组
峰分 (此处 acc 派生) 取峰组 G, 候选窗 [G-x,G+x]×GRP; 全周期类遍历 (fk 周期仅由
a mod 23 决定 ⇒ a=0..22 等价全满 0..65535, 另取 6 个截位/区界点) 断言 窗⊇真 top-3
且只扫候选得同一 top-3 (平局 stable); 最小安全半径 xmin=6 ⇒ 候选窗均值 100/512
≈19.5% (扫描成本压到 ~1/5; P2 320K → 只扫焦点区)。纯 assign 组合实现 (iverilog
-g2012 电平敏感 always 数组坑: 组峰/峰组前缀链/窗口裁剪全拉网线), 硬件实体对账
28 点全过。真实 logits 分布的剪枝率另随 PC GGUF 数据核验 (此处仅锁机制与最小安全窗)。
**M23 装配→GEMM 真字流 = `rtl/39_route_asm_exec/route_asm_exec_tb.v`** —— 把 M20 选→装配
前端直接当 M16×M11 引擎段的词源 (M21 "M16&M11=真机外部件" 表述反转为真挂接): 装配词流
按 槽L&1/W 序直灌双槽 32bit 切片库 (连续 2×16 装配词打成一词, 低半=GEMM 激活), sched_exec
GEMM 段逐词读验 (rail 激活=低半、权重=词序 w, 黄金=Σ_w w·seq(2w)), attn 段仍走 M11
wordval/se_in (与切片内容解耦)。槽让位纪律: 装配灌 L+2(=槽 L&1) 前必见 L 释放 (credit
弹性背压 ⇒ 选中侧被压, router 停顿 1072 拍), 释放序恰 0..3。尺寸口径: EX=16/TOP=4/EW=8
⇒ 每层装配 32 词 → 打包 GW=16 切片词 逐词对账。全链 ALL PASS: 装配选条16/吐词128,
GEMM 64词/4帧对账零违例 + gemm 黄金 4032 命中, attn 38628 双账一致, o256/池切8/释放4。
亦证: 装配 EMIT 端背压被 router 收表门前置吸收 ⇒ a_stalls 恒 0 (停顿只在最先被堵的闸口记账)。
**M24 词表剪枝→输出头 真接线 = `rtl/40_head_vprune/`** —— 把 M22 的候选窗机制真接到 M19
输出头, 并挂上 M23 真引擎会话累计: 引擎(选→装配→切片库→GEMM/attn 实算)终结后, acc
(=MAC 阵列实算 42660) 进 vocab_prune 组合出 峰组G/候选窗[lbw,ubw)/cand[] → 输出头只扫
ncad 个候选 (scan_end=ncad-1 运行时窗 + cand[cur] 实词号流式喂 logit), 吐 top-K 窗内相对
下标, 消费侧 +lbw 还原真词号。M22 保证 窗⊇真top-K 在真 acc 上复核通过 (黄金全落窗内),
头 top-K == 全量扫描黄金逐位一致 (分值+真词号)。实测 G=0 窗被左裁剪 ⇒ ncad=56/512 ≈ 11%
(同 acc 下 89% 扫描省掉), 硬件对账峰组/边界与 TB 重算一致, scanned==ncad。M19 增 scan_end
口 (全量时恒 VOC-1, M19/M21 回归绿)。全链 M23 断言全保留 (GEMM 64词金4032/attn 38628/释放4/背压 r1072)。

**M25 连续多步解码闭环 = `rtl/41_decode_auto/decode_auto_tb.v`** —— 解冻目标跑法第一例: TN=3 个 token
  的连续自回归, 每 token 一轮真引擎会话 + M24 剪枝头出词, 上步发出的 argmax token 反馈为下步种子。
  设计: fb[0]=0, t>0 时 `fb[t]=(tokstream[t-1]*7+11)&0xFFFF`; e_score `s_v_t=(L*131+((k*17)^(fb[t]&
  16'h0FFF)))&0xFFFF`(XOR 使逐 token 选序变化); rail/切片 LUT 跨 token 不变。每 token 实用"真 MAC
  累计差分": dt=arr_acc_out 增量、dg=gacc 增量、da=aacc 增量, 断言 dg==gemm金_t、da==ref_o 镜像
  (M23 o 逐行镜像的会话内增量)、dt==(dg+da); 头以 head_acc=dt[15:0] 独立跑, 等 h_round 推进, top-K
  与 fk(dt) 全量扫描黄金逐位一致, 发出的 tokstream = h_lbw+h_buf_tok。**RTL 修复 2 处 (跨会话正确性)**:
  ① assembler 会话起止不归零 lay_idx/caddr → 上 token 末层号残留致下 token 首层读错切片区; 改 go 时
  lay_idx<=0 且会话完工时归零 (M19/M21/M23/M24 回归全绿)。② 双口信用 slot_ok 用跨会话累计
  lay_fill/released, 第二 token 起 credit 断流→装配/引擎互等死锁; 改为 start_tok 脉冲按会话清零
  层计数。另: iverilog 连续赋值函数读 memory 数组不回算 (fb[t] 只随 tok/srcL/r_cur 变化重评) → 首 accept
  采到 X 进 router 表头; 改 `seed_r` 标量 + `assign s_score=(srcL*131+((r_cur_w*17)^(seed_r&16'h0FFF)))`。
  实测: acc 增量 42660/44836/51364, 窗 G0[0,56) ncad56/512(≈11%), 发出 token 流 **2→3→6**, 终账
  fill12/词384/GEMM192词对账180/o768/释放12/池切24/停r1072/头3条, 全链断言 TN× 通过。

**M26 长序列自回归闭环 (TN=12) = `rtl/41_decode_auto/decode_auto_tb.v`** —— 把 M25 链条拉伸到
  12 token, 专查"多步后有无状态泄漏/逃逸"。TN 参数化; 每 token 记会话周期 (实测 24960..25120cyc
  恒定, 无逃逸无堆积); 新增长程全账: racc=Σdt (逐 token 增量模 2^16 累加) 在位 == 阵列累计
  arr_acc_out[15:0], 12×NL 层扫完不漂 1 位; 发出 token 多样性断言 ≥5。**发现并规避玩具模型退化**:
  反馈 f(b)=b·7+11 在 token=7 处进入固定点 (t3..t11 全发 7, 4 个不同 token), 硬件/对账全过但序列
  停滞, 属模型非硬件泄漏; 改 `fb[t]=(fb[t-1]*1664525+tokstream[t-1]*7+11)&0xFFFF` (LCG 搅拌 + 上步
  token 反馈项保留), 12 步得 token 流 2→3→14→17→22→7→3→7→22→2→18→14 (7 个不同)。M26 无 RTL
  改动, 全为 TB 账目/公式, M25 机理原样复用。终账 fill48/词1536/GEMM768词对账720/o3072/释放48/
  池切96/停r1072/累计23984/唯一7。

**SRAM 域预算(行为级, 流片/换 fabric 平移, 2026-09-09):** **736KB ≤ 765KB(96.2%, 剩 29KB)**
  B-SRAM 价值 = 高带宽×低延迟×随机读 → **慢任务不许绑快资源**(转载站数据率仅 0.5MB/s vs
  B-SRAM 300GB/s 级, 当 FIFO 是拿跑车拉砖): 转载站取 DMA 侧弹性 FIFO。
  = 转载站 128KB(DMA 弹性 FIFO: 单笔最大 payload 49KB, sim 验证最小=单笔; 攒批靠主机写合并, 不靠大数组)
  + **MAC 热存储池 512KB(双缓冲微流水, 层内算子时分复用, 取个时最大占用):**
       · GEMM 段: A-tile 双缓冲 2×224KB(16token×7168×2B), MAC 扫 96 输出块不重读
         激活 → 隐藏态读 96×14MB/层 降到 14MB/层; prefill 层内 DDR3 读 2.27GB→0.93GB,
         层时 0.43s→0.18s ≈ NVMe 0.18s —— **DDR3 贴墙(否则反成 2.4× 新墙), P1 验收项**
       · attn 段: S 头窗 8头×32KB×2双缓冲 = 512KB(前块算完预取后块, S[L] 逐层流)
       · 两段先后错开(先 GEMM 后注意力), 池同时占用量 = max(448, 512) = 512KB
       · ⚠ 逆条件: 若层内需 GEMM+attn 并行持池 → 448+512=960KB > 765KB 装不下,
          **必须阶段串行**(single-core 语义, 与 §4 执行序一致)
  + scratch 96KB(router 排序 / softmax 分块 / ROPE·熵查表)
  + 余量 29KB(给综合器/时序余量, 别用满)
  铁律: SRAM 只放"单层一跳内、不随上下文/批次膨胀"的; 随流的(层切片/KV/重状态)全部走 bulk。
  重状态家族(RWKV-6 类, 单层态几十MB)天然不进 SRAM —— 换模型检查单: 单层delta/KV-per-token/scratch峰 三数对照槽位。

**家的两种形式(2026-09-09 修正: 状态不落盘):**
- **主机 DDR(主家)**: 运行时每序列 S+KV ≈ 236MB(S 208 + KV 28; S_b 在板上, 不挂主机);
  状态是运行时数据(RAM 命), 写 RAM 零秒零磨损
- **板上 M.2(只当冷会话换出仓)**: 不做每 token 的家 —— decode 每字落盘 279MB,
  sustained 0.15t/s → 3.6TB/天 → 600TBW 盘 ~166 天磨穿, 只配轻度聊天

**板上并发占用(单序列, 1K ctx):**

| 项 | 占用 | 性质 |
|---|---|---|
| 当前层 S(KDA, 96头×128×128×2B) | 3 MB | 逐层瞬读(主机/NVMe 为家) |
| 当前层 KV(v2@1K ctx) | ~1 MB | 逐层瞬读 |
| **S_b** 16-token 窗口(16×96×128×128×2B) | **48 MB** | **真常驻**(每层 K/V 投影都读, 无法按层分段) |
| v1 层切片(整层单槽) | 632 MB | 瞬态 |
| 本层 16 专家实体 | 281 MB | 瞬态 |
| 1K token 隐藏态(14.3KB/token) | 14 MB | 常驻/批 |
| **合计** | **~979 MB** | 97.8%, 贴边但站得住 |

⇒ 此前把 S/KV 标成"板上常驻 290MB 装不下"是**框架错误** → 它们按层流, 不占板。
⇒ 批量 N: 板上逐层状态槽 = N×4MB; home 侧撑 N×284MB(主机 64GB ≈ 200+ 序列)。

**尺寸下死核对(2026-09-09, 以 k3_head_dims_data.md 真形状为据):**
| 冻结口径 | 真形状为据 | 核对 |
|---|---|---|
| KDA 状态 96头×128×128 = 3.0MiB/层 | q/v_proj out 12288=96×128; A_log[128], o_norm[128], f_a_proj[128,·] | ✓ 3.145MB |
| KV 12.75KB/token | query=kv_a_proj_with_mqa [576,·] = latent 512 + mqa rope 64; 写回=512×1B INT8 + 64×0.5B rope4 = 544B×24层 = 12.75KB | ✓ 实证(2026-09-10) |
| 当前层 KV@1K ctx ~0.55MB | 1K × 544B = 0.52MB/层 | ✓ 实证 |
| S_b 16×96×128×128 = 48MiB | 25.17M 元素×2B = 48.0MiB | ✓ 几何闭合 |
| vocab ≈320K | 4.4GB embed ÷7168÷2B = **327,680 = 320K×1024** | ✓ 已下死 |
| 输出头 tied? | 需要全分片扫是否存在 output.weight | 仍开(待权重侧) |
| 93 层 = 69v1 + 24v2 | v1/v2 层号清单逐层对上(92 为最末 v2) | ✓ |

→ 结论: 冻结的板/主机字节账在真形状下**全部成立**, 无一处要改。

## 6. 吞吐墙与突破栈(冻结口径)

基准墙 = NVMe 3.5GB/s。
- 无批(batch1): 0.046 t/s = 21.9s/字
- 批 1K: 0.15 t/s ≈ 6.5s/字 (trunk 摊薄 55.6MB/token)
- 双缓冲不停顿(--stall 1.0) + 专家预取(h=0.5) + 草稿模型: ~4-5s/字(异步)
- 宿主微边(Gen5 64GB/s): ~0.8 t/s
- 教训: **1K 买的是「做得出来」+批次吞吐, 不买单人延迟**

## 7. 诚实修正(冻结)

- trunk 原生 = **BF16 108.8GB**。官方从不量化非专家成分 (ARCHITECTURE_BASELINE §2.1)。
  55.6 MXFP8 是**我们自制** 1.92× 熵压缩(引擎 rel<10%/argmax SAME 验证)。
- MXFP4 trunk(27.8GB) = 真有损研究步, 不是格式还原。已钉进 calc_k3_shared_pool.py 注释。
- **KDA 状态账(2026-09-09 三修)**: 69 层 × 3.01MB ≈ 208MB/序列 = **层流的一部分**(逐层读→写回),
  不是内存居民(第 1~89 层的 S 跑当前层时用不上, 只躺在家存储里); 板上活跃 = 当前层 3MB。
  两次配额表都错: 旧表 93%(没算) → 二修(误标"板上常驻 290MB 撞车")→ 三修(按层流, 家=主机/NVMe, §5).
- **输出头税(2026-09-09 补)**: decode 每字读全词表(4.4GB BF16 / 2.2GB MXFP8), 不随批摊薄,
  +0.63~1.26s/字; 词表剪枝 top-16K 可降到 +0.07s(带近似)。prefill 每次只读一次 → 可忽略。

## 8. 工具参数(已落地)

calc_k3_shared_pool.py 新增 `--batch N`(trunk 摊销 55.6/N) + `--stall F`(无停顿系数)
+ `--head none|bf16|mxfp8|prune`(decode 输出头税, 2026-09-09)。
默认 batch1/stall1/head none 与旧口径零回归。贯通 walls/逆推/场景A·B/tiers/柜子。

## 9. 待办(PC 上)

- [x] **拆 trunk**: `tools/trunk2layers.py` 把 MXFP8 trunk 按 93 层切成独立切片文件
      (v1 632MB / v2 419MB) + 每层清单(张量/形状/offset/路由头→专家实体 offset),
      供板子逐层流式取数; 顺带在 PC 上实测 93 层逐层字节, 核 632/419 与外推误差
      —— **PC 验收 2026-09-11 全过**:
      ① dry: 93 层、总字节 diff=0、每层 gaps=0;
      ② 93 切片字节 == sizes.tsv nbytes → PASS=93 FAIL=0;
      ③ 抽查 layer 0/15/42/67/92 md5 全匹配;
      实测: v1 615.7 MB/层(不含层0) / v2 411.9 MB/层;
      输出 `/mnt/nvme/trunk_layers_out/`(53GB, 93 切片 + trunk_layers.json + sizes.tsv)
- [x] **专家库侧索引/装配**: 1413GB 实体库按(层→offset)建索引 + 按 top-16 装配流, 与拆 trunk 配套
      —— **装配流核心 M18 已落地**(`rtl/34_assembler/`, top-T→实体块依序吐流 + 双向背压 + 层 barrier,
      FAST 全绿); 实体库索引(层→offset 规划)随 P1 搬运件
- [x] **router 先行**: 每层 gate(6.5MB)+e_score 装载 → top-16 选择必须先于专家抽取(读 12.8MB 后拉实体)
      —— **top-T 选择核心 M17 已落地**(`rtl/33_router_sel/`, 先选后抽时序 + 平局断序 + 双向背压,
      FAST 全绿); gate/e_score 实际装载读随 P1 搬运件
- [x] **embed/output 接入**: 输入 embed 每 token 只查一行(14KB, 无害); **输出头是 decode 每字全词表税**
      (BF16 4.4GB → +1.26s/字, MXFP8 2.2GB → +0.63s/字), 词表剪枝 top-16K → +0.07s 待验
      —— **输出头扫描核心 M19 已落地**(`rtl/35_output_head/`, 每词扫全词表取 top-K,
      平局 stable, 扫描断流+吐期慢取不丢不序, FAST 全绿); 词表剪枝候选集验证随 PC 数据
- [ ] **状态的家**: KDA S(69×3MB)+KV 落 主机DDR(§5: 状态不落盘, M.2 仅冷仓) —
      板子每层拉/写 ~3MB, 实测 PCIe 往返时序
- [ ] `--gen 32+` 真机 trace: 专家频率/union → 定 281MB 槽命中率与预取策略
- [ ] **尺寸下死(PC 扫)**: KDA 96×128×128、S_b 48MiB、KV 576×2B×24、vocab=327,680 ——
      **已用真形状核对通过(§5 表)**, 只剩"输出头是否 tied"待全分片扫 output.weight
- [ ] **词表剪枝质量**(`--head prune`): top-16K 保不保 argmax / PPL 不降
- [ ] **草稿模型(EAGLE-3 内置)接受率 λ 实测**: 2-3× 目标调用减少, 杠杆未验证
- [x] **层流协议 spec + 主机模拟器**: v0 spec 在 §5, sim 在 `tools/sim_layer_flow.py`
      —— 字节序对账(预填 3.2GB/decode 3.4MB 每字)与"批==生成"数学等价已 PASS;
      FIFO=128KB(≥单笔49KB)/主机写≥266MB/s 零停顿已实测; 输出喂 P2 RTL + P1 SDMA
      (V1 前缀含 69 层序) —— 2026-09-09 sim 落地
- [ ] **DDR3 控制器实测**: 高云 IP 1333MT/s 满带宽是否真达 5.3GB/s(P1 第一关, 卡住全吹)
- [ ] **M.2 NVMe 实测**: 槽是否真通 + 独立读带宽(3.5GB/s 目前是纸面)
- [ ] **端到端验收**: 板 vs PC 引擎 logits 对比(沿用 rel<10% / argmax SAME 基线)
- [x] calc 脚本补 `--head`(头税 per-token, 修所有 t/s 数字) —— 2026-09-09 已落地
- [ ] 书场景: KV 迁主机后的 PCIe 双流(权重+KV)吞吐实测

## 10. 工程阶段(缺口: 文档此前只有数据准备, 没写"算")

- **P0 数据**: 拆 trunk / 专家库索引 / PC trace —— 第 9 节全部
- **P1 搬运**: DDR3 控制器(高云 IP 1333MT/s) + M.2 NVMe 读引擎(按层流 + 张量微流水双缓冲);
  结构校验已落地 `tools/sim_prefill_pipe.py`(A-tile 复用 2.27→0.93GB、736≤765、NVMe 稳坐墙)
- **P2 算(最大头)**: 推理引擎 RTL —— 93 层循环 + 69 KDA/24 MLA + router + 采样; 138K LUT 预算(账: 图执行器~27%, 能装下)
- **P3 端到端**: tokenizer/embed 接入 + 状态的家落位(S 主机/NVMe, S_b 板上)+ 验收(第 9 节 logits 对比)