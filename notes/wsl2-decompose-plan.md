# WSL2 执行清单: 张量分解可行性实测 (§15 路径2)

**目标**: 在有权重 + torch 的机器上, 判定「张量分解能否无损压缩 KDA qkv」
        → 直接决定走 §15 路径2(成功) 还是路径3(失败, 训router)。

**前置**: WSL2/Ubuntu + 纯 CPU torch, 磁盘 >50GB。
(本机 Termux 无 torch/numpy/磁盘满; 21 的判定是矩阵谱运算, CPU 足够, 不需要 GPU)
本机无法跑真权重, 判定须在 PC/WSL2 执行。

---

## Phase 1 — 环境(纯 CPU)

```bash
sudo apt update && sudo apt install -y python3-pip git
python3 -m pip install torch            # CPU 版即可, 判定无需 GPU
python3 -m pip install safetensors numpy tqdm
python3 -c "import torch; print(torch.__version__)"
# 期望: 2.x (CPU 版也能跑 SVD/谱分析)
```

---

## Phase 2 — smol-kimi-k3(49M 已训练) 快速验证(推荐先做)

用真实训练出来的小 K3 权重先跑通判定, 几分钟得到结论, 再上真 K3。

```bash
# 2a. 拉源码 + 已训练权重(49M, GitHub Release)
git clone https://github.com/cneuralnetwork/smol-kimi-k3 && cd smol-kimi-k3
pip install -r requirements.txt            # torch>=2.5, fla-core, safetensors...
mkdir -p pretrained/smol-kimi-k3
gh release download v0.1.0-tinystories \
  --repo cneuralnetwork/smol-kimi-k3 --dir pretrained/smol-kimi-k3
# => pretrained/smol-kimi-k3/model.safetensors (49M BF16) + config.json + tokenizer.json

# 2b. 跑张量分解映射器(本仓库工具)
# 提示: 把工具拷进 WSL2 或记下路径
python3 /path/to/sram/tools/kda_tensor_decompose.py \
  --ckpt pretrained/smol-kimi-k3/model.safetensors \
  --arch smol --json map.json --csv map.csv
```

**判定标准(看输出):**

| 信号 | 值 | 结论 |
|---|---|---|
| `rank90_frac` (每矩阵) | < ~0.5 | 该矩阵低秩可压 |
| `head_err_R4` (qkv) | < ~0.1 | 头共享→→张量分解可行 |
| `head_err_R4` (qkv) | > ~0.3 | 头独立→→满秩墙 |

**纠错/注意**:
- smol 的 q_proj 是 `Linear(d,d)=[320,320]`, 输出 view 成 `H=5 × HD=64`。
  测绘器用 `do == H*HD`(320==320) 判定头结构, 会正确走 head 分析。
- 若 `--arch smol` 下 key 匹配少, 改 `--arch` 或确认 safetensors 内 key 前缀
  (形如 `layers.N.<attn>.q_proj.weight`)。
- 关键先看 **q_proj / k_proj / v_proj** 的 `head_err_R4`——这是整条线核心。

**2c (可选) 模型级验证**: 若 2b 判定可行, 用 kda_tensor_decompose 给出的
低秩因子替换原 qkv, 在 smol generate.py 上跑, 对比生成质量是否掉。
(纯 CPU 可跑, 慢而已; 判定本身 2b 已足够)

---

## Phase 3 — 真 K3 全量测绘 (最终, 需大内存)

真 K3 2.8T 权重太大, 建议**只加载前 ~20 层**做判定(每 KDA 层 ~0.95GB, 20层≈19GB),
或用 sglang 已加载权重时在内存直接抓张量。

```bash
# 方法A: safetensors 切片(只取 QKV 相关层)
python3 /path/to/sram/tools/kda_tensor_decompose.py \
  --ckpt <K3-layer-slice.safetensors> --arch k3 --json k3_map.json --csv k3_map.csv
```

**盯住**:
- `q_proj` [7168 → 12288] (96头×128) 的 `rank90_frac` 和 `head_err_R4`
- 若近无损可压 → **§17 张量分解产品可行**, 走 §15 路径1(全模型)
- 若满秩墙 → **§15 路径3**(训专用 router)

---

## 依赖说明

- `kda_tensor_decompose.py` — torch 版全模型映射器(判"哪些矩阵无损可压")
- `kda_head_sharing.py`   — 判定单层头结构共享度(早期判据)
- `kda_tensor_decompose_demo.py` — 本机纯Python演示(无torch可跑, 已跑通:
   低秩→余弦1.0无损 / 满秩→墙, 两极端实证)
- `wsl2_decompose_plan.sh` — 本清单的命令版

## 总判据: 决定 §15 走向

```
qkv head_err_R4 < ~0.1  (+ rank90<50%)
  └─ 成功 → 张量分解路径2, 再上路径1全模型 → 产品测绘(§17)
qkv head_err_R4 大 / rank90≈100%
  └─ 失败 → 路径3 训专用 router (需真数据+训练, 门槛高)
```
