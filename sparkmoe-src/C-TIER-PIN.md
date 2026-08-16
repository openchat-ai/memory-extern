# C 档（静态热表）接线补丁 —— `patches/c-tier-pin.patch`

> 目标：给 SparkMoE 加 `--moe-pin-file <path>`，把离线生成的 L0 静态热表
> （`profile_trace.py` 输出的 `hot_list.txt`）在启动时置为 pinned，实现白皮书 §3 L0+L1 档。
> **`resolve()` 与 `choose_victim()` 零改动**——只复用已内建但零调用方的
> `set_expert_pinned`/`layer_cache::set_pinned`（`moe-paging.cpp:102`、`moe-cache.cpp:230`）。

## 补丁内容

- `moe-paging.h`：新增私有成员 `pins_loaded`/`pins`（`<string>`、`<vector>` include）+ 方法 `load_pins()`。
- `moe-paging.cpp`：
  - `get_or_create_layer()`：首次调用时 `load_pins()` 解析一次；每层缓存创建后立即把该层
    pinned 专家 `set_pinned(expert, true)`。
  - `load_pins()`：解析 `<layer>: <e1>,<e2>,...` 格式（`#` 注释行忽略），校验
    `index.has_layer(layer)` 与 `expert < expert_count(layer)`，越界跳过并计数。
- **为什么懒加载**：`io_executor` 构造时就急建全部线程（`moe-io-common.cpp:22-24`），若在
  paging_manager 构造函数里给 60 层一次置 pin，会瞬间创建 60×io_threads 个线程。

应用：

```bash
patch -p1 < patches/c-tier-pin.patch   # 从 SparkMoE 仓库根目录
```

## 两个外部接缝（补丁未覆盖，需手动加）

1. `llama.h` 的 `llama_moe_paging_params` 增加字段：

```cpp
    std::string pin_file;   // 静态热表文件路径（--moe-pin-file），空则不启用
```

2. CLI 参数解析（`main.cpp` / llama-cli）增加：

```cpp
    opts.add_option("--moe-pin-file", "-moe-pin",
        "load static hot-table (hot_list.txt) and pin those experts per layer",
        params.moe_paging.pin_file);
```

## 用法

```bash
# 1) 离线生成热表（合成 demo 或真实 trace）
python3 tools/profile_trace.py --demo --n-layers 60 --n-experts 384 --topk 8 \
    --manifest case-k25/k25-manifest.json --tier-budget-gib 4.51 \
    --outdir case-k25/out-topk8
#    → 产出 case-k25/out-topk8/hot_list.txt（4.51 GiB 预算下每层 ~7 个 pinned 专家）

# 2) 真机跑 C 档
./llama-cli -m model.gguf --moe-paging explicit --moe-cache-mib 4618 \
    --moe-pin-file case-k25/out-topk8/hot_list.txt ...
```

启动日志应看到每层一条 `MoE paging: layer N pinned M experts`。

## 验证计划（真机，对照白皮书 §5）

- 同一 seed/temp/prompt/-n，先跑 B 档（不加 `--moe-pin-file`），再跑 C 档，比较
  `tok/s`、`misses/token`、`waits`（stats 快照 `moe-paging.cpp:162-177`）。
- 期望：§5.5 离线预估在 4.51 GiB（7 槽/层）下 C/B ≈ 3.4x 命中率提升，tok/s 提升幅度受
  磁盘延迟与带宽约束，需实测。

## 诚实说明

- 本补丁为**研究用途**：SparkMoE 是 PolyForm-Noncommercial 许可，勿合入任何商业发布。
- `hot_list.txt` 目前可由合成 demo 生成；真实负载请先用 `TRACE-COLLECTION.md` 钩子采集
  trace 重跑 `profile_trace.py` 再生成热表（各层热集不一定是旋转同构的）。
- 若 pin 文件里的专家数接近/超过槽位预算，pinned 会挤占 LRU 池——由
  `profile_trace.py` 的档位仿真（C 档用 `lru_budget = budget - pinned_bytes`）预先评估。
