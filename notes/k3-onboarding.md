# K3 权重上手操作手册（另一台电脑 → 本项目）

> **版本 0.1** · 2026-08-22
> 目的：K3 权重已在另一台电脑下载完成。本手册定义如何用它**裁决性能模型的
> 关键争议**（每 token 激活流量：52GB vs 512GB，见 `pim/calc_performance.py`
> 与 `notes/architecture-decision.md`），并校准分层内存命中率。
>
> 原则：权重文件本身不搬运（手机跑不动也不需要）；只回传**几 KB 的元数据与结论**。

---

## 第一步：完整性体检（权重机）

```bash
# 清点：格式、总大小、分片
ls -la *.gguf            # 或 safetensors 格式
du -sh <模型目录>

# 完整性（如有官方 sha256）
sha256sum <主文件>
```

记录：总大小 TB 数、分片数、量化类型（Q4_K_M / bf16 / ...）。

## 第二步：提取四个裁决性参数

用仓库现成工具 `tools/gguf_dump.c`：

```bash
cd sram/tools
gcc -O2 -o gguf_dump gguf_dump.c
./gguf_dump <模型主文件> | head -40
```

| 参数 | 要拿的值 | 裁决什么 |
|---|---|---|
| `n_layer` | ？（文档假设 93） | 层数口径 |
| `n_expert` | ？（假设 896） | expert 总数 |
| `n_expert_used` | ？（假设 16） | 每 token 激活数 |
| `expert_feedforward_length` + `embedding_length` + 量化位宽 | ？ | **单 expert 真实大小** |

### 推导链（拿到参数后代入）

```
单 expert 全层字节 = ffn_len × hidden_len × 3 × bytes_per_weight × n_layer内该专家占比
    （精确公式以 GGUF 张量清单逐层求和为准：Σ 所有 ffna/ffnb/w2/w3 gate 张量）
每 token 激活流量   = n_expert_used × 单 expert 字节
整模型容量         = n_expert × 单 expert 字节 + attention/dense 部分
```

**裁决表**：
- 若 ≈ 52GB/token → 旧硬编码正确，脚本不用大改
- 若 ≈ 512GB/token → 存储反推正确，性能上限上修 ~9.4 倍
- 若都不是 → 以实测为准，更新全部下游文档

## 第三步：回传结论（几 KB）

只需把以下内容发回（微信/网盘文本均可）：

1. `gguf_dump` 的超参输出段（纯文本）
2. 总大小与分片文件名列表
3. 量化类型

随后本项目侧执行：
- [ ] `pim/calc_performance.py` 参数化改造（EXPERT_COUNT / EXPERT_GB 显式化，
      替换硬编码 `k3_activated_gb=52`，加一致性断言）——方案已评审待数据填入
- [ ] 重跑性能/成本表，更新 ADR 与研究文档 K3 章节

## 第四步（可选，权重机 RAM ≥ 模型体积时）：真实路由 trace

```bash
# SparkMoE fork 的 research-cli 已支持 trace 采集（见 data/traces/ 先例）
./research-cli --moe-paging explicit --moe-slots <N> --moe-trace k3_trace.jsonl \
               -m <gguf路径> -p "<提示词>" -n 300
```

产出用于：
- 校准 L1(GDDR6X 16GB) 命中率——分层内存方案的最后一块待验证拼图
- 验证"层热度预测 top150→88%+"在 K3 上是否复现

注意：`--moe-trace` 只在 `--moe-paging explicit` 下生效（moe-paging.cpp:60）。

## 变更历史

| 版本 | 日期 | 变更 |
|---|---|---|
| 0.1 | 2026-08-22 | 初稿：四步流程 + 四个裁决参数 + 回传规范 |
