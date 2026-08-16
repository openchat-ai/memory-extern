# pim/ — PIM 旁边的参考内核（专家 matmul 边界规格）

> 内存计算侧的第一步落地：把"PIM 只算专家 matmul，其余全在 CPU"这个边界做成
> 一个**独立、无引擎依赖、逐位可验证**的参考内核。硬件（C500 张量核 / PIM /
> crossbar）没到之前，它就是那块"摆在 PIM 旁边"的黄金参考：新硬件的去量化与
> 累加顺序对它逐位对齐。

## 1. 边界：PIM 算什么，host 留什么

PIM 设备**只算一件事**：

```
y[out] = Σ_{in} dequant(W[out][in]) · x[in]
```

即"一个专家的权重 GEMV"。`W` 是 MXFP4 打包字节 + E8M0 scale 字节，
`x` 是激活（latent 空间），`y` 是该专家的部分和（fp32，长度 = 专家输出行数）。

Host（CPU 侧）**保留全部其它环节**，一次推理的数据流为：

| 环节 | 位置 | 理由 |
|---|---|---|
| 路由（gate 线性 + sigmoid + top-k + routed_scale） | host | 需要偏置与 softmax/sigmoid 语义，且输出只有 k 个索引 |
| 专家权重 GEMV（MXFP4 去量化 + 乘累加） | **PIM** | 唯一搬不动/最贵的数据：17.5MB/专家 |
| 部分和按 top-k 加权累加 | host | 只有 k 个 fp32 向量跨设备 |
| RMSNorm / 残差 / SiTU-GLU / 共享专家 / 注意力 / KDA | host | 与权重驻留问题无关 |
| scale 应用（E8M0→倍率） | 见 §3 | 契约里唯一可在设备侧完成也可在 host 侧的环节 |

跨设备边界传输量：每个 token 每层只进出 **k 个 fp32 向量**（partial sums），
不搬 17.5MB 的权重字节。这正是内存计算的卖点：**字节数省不掉，省的是搬运能耗。**

## 2. 接口契约

```c
/* y[out] = W[out][in] · x[in]；W = (packed, scales)，MXFP4 打包，见 §4 */
void pim_mxfp4_gemv(float *y, const float *x,
                    const uint8_t *packed, const uint8_t *scales,
                    int in, int rows, int group);

/* 去量化（仅用于对照/调试）：out[rows][width] = 解出的 fp32 权重 */
void pim_mxfp4_dequant(float *out,
                       const uint8_t *packed, const uint8_t *scales,
                       int rows, int pcols, int group);
```

`pim/mxfp4_gemv.c` 无任何引擎依赖（不 include k3.h），自带 E2M1 表与 E8M0 表。

## 3. 精度契约（实测）

基准：真实 checkpoint 字节（`tests/fixtures/mxfp4.json`），对照 CPU 参考
`k3_matmul_mxfp4`（double 累加，逐位精准）。

**两条路径的算法必须分开，不能互相冒充**（这是历史教训：曾用"CPU 算法 + float 累加"
冒充设备路径，造成模拟污染）：

| 差异 | CPU 参考（引擎在算的） | C500 硬件路径（设备在算的） |
|---|---|---|
| 累加 | 8 累加器残差分区 + 树状归约 + **double** | 整条 in 维**顺序 fp32**（每 MMA k=0..15，跨 ktile 携带 C） |
| scale 位置 | group 内点积**后**乘（每 32 宽 group） | B fragment 加载**时**乘（每 16 宽 k-tile） |
| 激活 | fp32 | **bf16**（A fragment 收不了 fp32） |
| 验收标准 | 逐位 | 误差落在容忍内（不逐位） |

实测（`make measure`，忠实行为模拟 `sim_c500.c`，真实字节，3 种子取最差）：

- C500 真实路径（scale@load + bf16 激活 + fp32 顺序累加）：
  **maxrel=1.4e-1**（近零点积放大，分母→0 假象）、**p99.9=2.0e-2**、
  **max\|err\|/RMS=4.1e-3**（信号归一，下游真实代价）
- 判决：bf16 激活舍入（~4e-3 信号归一）主导误差，与 MXFP4 权重量化噪声同量级，
  fp32 累加结构差异（~1e-6）被完全淹没 → 设备路径预算 **~1e-3 信号归一**。
- **c500-kernel.md 声称的 1.16e-6 / 1.82e-3 来自 mma_sim.c——该实验从未入库，
  无法复现，不能引用。** 本模块的信号归一口径 ~4e-3 与声称的 1.82e-3 同量级但不
  一致，待忠实重建 mma_sim.c 后核对。
- **权重侧无损**：E2M1 值域 {0, ±0.5, ±1, ±1.5, ±2, ±3, ±4, ±6} 每个只需 ≤1 个
  存储尾数位；乘以 2 的幂（E8M0 scale）只移指数 → 去量化到 bf16/fp32 不损失任何
  信息。scale 在硬件里于加载时乘一次，不必逐元素乘。
- **sb=255（NaN scale）贡献 0**，与参考一致：一个坏字节不能毒化整行。
- 本模块的 `pim_mxfp4_gemv` 是 **CPU 侧的逐位参考**（double 累加、按参考的求和
  顺序）——它约束引擎 CPU 路径的正确性，以及验证任何"设备是否逐位复刻 CPU"的
  声称；**它不是硬件的算法**。硬件按上表的结构实现，契约 = 误差落在容忍内。

## 4. MXFP4 布局（OCP MX E2M1，group=32）

- `packed[r][i>>1]`：低 nibble = **偶数**元素，高 nibble = 奇数元素（反了就是
  "统计相同、位置全错"，fixture 有专门对抗）。
- nibble → `K3_E2M1[16]`（bit3 = 符号），值域见 §3。
- 每 32 个元素一个 E8M0 scale 字节：`mult = (sb==255) ? 0 : ldexpf(1, sb-127)`。
- 元素值 = `K3_E2M1[nibble] * mult`。

## 5. 验证（`make verify`）

`verify.c` 从 `make_fixture.py` 生成的二进制 fixture 验证三件事：

1. **去量化逐位**：`pim_mxfp4_dequant` == fixture `expected`（参考实现逐位）。
2. **GEMV 逐位**：`pim_mxfp4_gemv` == 参考核（`k3_ops.c:1243` 语义逐字保留的
   副本），激活含零/全一/特殊值/固定种子伪随机。
3. **nibble 对抗**：交换低高 nibble 后结果必须**不同**（证明 nibble 顺序是
   载重语义，不是无关字节）。

## 6. 与现有资产的关系

- `k3_ops.c:1243` `k3_matmul_mxfp4` —— 生产参考，本模块的求和顺序来源。
- `c500-kernel.md`（kimi-k3 fork 内）—— C500 张量核融合去量化设计，§3 的
  测量来自它的 `mma_sim.c`。本模块是它的 **CPU 侧黄金参考**。
- 后续 RTL 第 4 课（Verilog MXFP4 去量化）以本模块为对照物。
