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
`k3_matmul_mxfp4`（double 累加，`test_expert.c` 的 1e-6 权威门限）。

| 情形 | 激活 | 累加 | vs double 参考的 maxrel | 结论 |
|---|---|---|---|---|
| CPU 参考（基准） | fp32 | double | 0（逐位） | 现有 1e-6 门限的成立前提 |
| 张量核/PIM + fp32 激活 | fp32 | fp32 | 1.16e-6（实测） | 布局/顺序/去量化正确，仅 fp32 累加误差 |
| 张量核/PIM 真实路径 | bf16 | fp32 | 1.82e-3（实测） | bf16 激活舍入主导 |

判决：

- **权重侧无损**：E2M1 值域 {0, ±0.5, ±1, ±1.5, ±2, ±3, ±4, ±6} 每个只需 ≤1 个
  存储尾数位；乘以 2 的幂（E8M0 scale）只移指数 → **去量化到 bf16/fp32 不损失
  任何信息**。硬件里 scale 可以只在取数时乘一次，不必逐元素乘。
- **fp32 累加** 在 3584 项点积上 maxrel=1.16e-6，略超 1e-6 门限但比权重量化噪声
  低三个量级 → 可接受的设备侧实现。
- **bf16 激活** 是真实路径的主导误差（1.82e-3），与 MXFP4 权重量化噪声同量级 →
  **工程上正确选择，不要用 1e-6 门限框住张量核**。
- **sb=255（NaN scale）贡献 0**，与参考一致：一个坏字节不能毒化整行。
- 本模块的 `pim_mxfp4_gemv` 是 **CPU 侧的逐位参考**（double 累加、按参考的求和
  顺序），不是设备侧的松弛实现——设备侧对齐它的"求和顺序 + 去量化语义"，
  并按上表接受 fp32 累加 / bf16 激活的松弛。

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
