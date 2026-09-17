# ρ1 激活存活率测量（权重机启动手册）

> 版本 0.1 · 2026-09-17 · 目标：在权重机 kimi-k3-in-c 引擎上测 **MXFP8 激活存活率 ρ1**
> （SiTU-GLU 输出向量在 8-bit 量化后非零占比），回传几 KB 文本即可。
> 动机：把"只读需要的数据"（数据库列存 + 激活掩码）落到 K3 专家权重上时，字节账
> `R_j = ρ0·(|w1|+|w3|) + ρ1·|w2|` 的胜负 100% 押在 ρ1 上。trace 层已测（ρ=0.28，
> 专家粒度无便宜可占），本步测 **专家内部激活维度** 的存活率。
> ⚠️ 必须统计 **MXFP8 量化后** 的位级存活，不是 float 存活。

## 前置（30 min）

1. 权重机已有 `kimi-k3-in-c` 源码与权重（safetensors 96 分片，`H:\k3`）。
   仓库：https://github.com/openchat-ai/kimi-k3-in-c
2. 通关一次：
   ```bash
   ./main -m <model> -n 16 -p "hello"
   ```
   build 成功后记下可执行入口与权重路径。

## 探针（30 min）

在 **专家 GEMV 路径**、**SiTU-GLU 输出 h 的 MXFP8 量化之后** 插入累计计数器。
最小侵入，只加不影响流水：

```c
/* k3_ops.c —— 路由专家激活量化点之后 */
static uint64_t s_cnt = 0, s_nz = 0;      /* 全局累计 */
/* h8[] = MXFP8 量化后的激活向量（真实字节，压缩后） */
for (int i = 0; i < H_DIM; i++) {          /* H_DIM 用实际循环上界 */
    s_cnt += 1;
    s_nz  += (h8[i] != 0);                 /* 位级存活 = 量化后非零 */
}
/* 每 32 token 打印一行（避免刷屏, 亦可结尾统一 dump） */
if ((token & 31) == 0)
    fprintf(stderr, "RHO1 layer=%d exp=%d t=%d rho1=%.4f\n",
            layer, expert_id, token, (double)s_nz / s_cnt);
```

要点：
- **插在量化之后**，不是 GEMM 之后 float 处。找 `quantize`/`q8`/MXFP8 打包函数，插在其 return 位置。
- 附带同样统计 **输入激活 x 的存活率 ρ0**（专家入口处，量化后非零比）——同一循环改向量即可。
- `H_DIM` 不要硬编码：从解码循环实际上界读（`k3.h` 里 `hidden_size`/`routed_expert_hidden_size` 宏）。
- 形状参考（article_v2 :27，仅供对号入座，以代码实际为准）：单专家 w1/w3 `[3072,7168]`、w2 `[3584,6144]`，MXFP4 量化态 17.55MB/层；打包格式见 k3_pack_format.md（nibble 序/scale/group=32）。

## 采样（数分钟）

```bash
./main -m <model> -n 128 -p "<你的日常提示词>"
```

产出量级：92 层 × 16 专家 × 128 token。日志里 grep：
```bash
grep RHO1 run.log | head -40
```

## 回传（几 KB）

把 `RHO1 ...` 原始行（或每层汇总 `layer ρ1_mean ρ0_mean tokens`）发回。
手机侧做分布统计、Zipf/邻接相关、字节收益曲线 `R_j = ρ0(|w1|+|w3|) + ρ1|w2|`。

## 备选（不想碰引擎 C 代码时）

python/numpy 读 safetensors 某层前几个专家 w1/w3 + 从 `data/traces/*.jsonl` 合成输入 x，
近似算 SiTU 后存活率。⚠️ 这是 **近似**（合成激活 ≠ 真量化路径），只作 sanity check，
不替代探针真值。

## 验收标准

- ρ1 有值且对同一 layer 多次运行稳定（±0.02 内）
- 与 t4_code_freq.json 的权重零码比例（~4%）方向自洽可解释（激活存活率应远高于权重零码率，
  因 SiTU 输出稠密、MXFP8 量化只吃掉接近 0 的小值）
- 记录：样本量、模型量化态、测试 prompt

## 变更

| 版本 | 日期 | 变更 |
|---|---|---|
| 0.1 | 2026-09-17 | 初稿：探针插点、采样、回传规范 |