# 开放项 A:SparkMoE → Qwen3.6 真机 trace 采集·合体清单

> 目标:把 `sparkmoe-src/` 片段合进完整 llama.cpp 工程,编译出能采集
> Qwen3.6-35B-A3B 真实路由 trace 的工具,供 `tools/profile_trace.py` 离线分析。
> 依据:WHITEPAPER §7 行动 1/2、`sparkmoe-src/anemll/FLASHMOE_FORK_SETUP.md`、
>   `sparkmoe-src/TRACE-COLLECTION.md`。所有改动均为研究用途,勿合入主线。

## 0. 确认现有资产(先做完这步再动代码)

- [ ] SparkMoE 片段目录:`sparkmoe-src/`(含 moe-paging/, patches/, anemll/docs)
- [ ] 模型:Qwen3.6-35B-A3B Q3 gguf 已下载(`llama-bench` 已测 5.58 t/s)
- [ ] 电脑有:git + cmake + 编译器(MSVC 或 MinGW;WSL 的 gcc 最省心)

## 1. 拉取完整 llama.cpp(合体的基础)

```bash
# 用 WSL(推荐)或 git-bash
git clone https://github.com/ggml-org/llama.cpp.git ~/llama-src
cd ~/llama-src
git status   # 确认干净
```

## 2. 对位合入 SparkMoE 改动件

按 FLASHMOE_FORK_SETUP.md 的清单,把 `sparkmoe-src/` 文件对位拷进 llama.cpp:

| 片段文件 | 放入位置 |
|---|---|
| `llama-graph.cpp` | `src/llama-graph.cpp`(覆盖前先 diff) |
| `llama-kv-cache.cpp` / `.h` | `src/llama-kv-cache.cpp` / `include/` |
| `llama-kv-cells.h` | `src/` |
| `moe-paging/*.cpp` `*.h` | 新建 `src/moe-paging/` |
| `patches/c-tier-pin.patch` | 合入后 apply(见 §3) |

```bash
# 每件都先看差异量,别盲覆盖:
diff llama-graph.cpp src/llama-graph.cpp | head -30
```

⚠️ 片段基于作者的 llama.cpp snapshot(FLASHMOE_VENDOR_COMMIT),**上游可能已前进**。
   diff 若大面积冲突 → 先 `git log` 找到作者版本再基于它 clone 或 rebase。

## 3. apply 两份补丁

```bash
cd ~/llama-src
# 补丁1: C-Tier pin(c-tier-pin.patch, 改 moe-paging.cpp)
git apply ~/sram/sparkmoe-src/patches/c-tier-pin.patch

# 补丁2: trace 采集钩子(TRACE-COLLECTION.md 里的 remap_callback + --moe-trace)
#   —— 手动按文档第 20-60 行插入,或写成 .patch 再 git apply
```

## 4. 编译(优先 CPU-only,能跑就行)

```bash
cmake -B build -DCMAKE_BUILD_TYPE=Release -DLLAMA_CURL=OFF -DLLAMA_CUDA=OFF -DGGML_OPENMP=ON
cmake --build build -j$(nproc) --target llama-cli
```

- Windows/WSL 用 `-j$(nproc)`;MSVC 用 `-- -m`
- 若报缺文件 → 回 §2 漏合了
- 编译出 `build/bin/llama-cli` 即成功

## 5. 冒烟测试(不动 trace,先确认能跑)

```bash
build/bin/llama-cli -m /path/qwen3.6-35b-a3b-q3.gguf -p "hello" -n 32 -ngl 0
```
看到正常输出即可。⚠️ 此刻**不要**边测速边开 trace(会扰动)。

## 6. 采集 2 条独立 trace(阶段 1)

```bash
mkdir -p ~/traces
build/bin/llama-cli -m /path/qwen3.6.gguf -p "<代码prompt>" -n 256 \
    --moe-trace ~/traces/trace_code.jsonl -ngl 0
build/bin/llama-cli -m /path/qwen3.6.gguf -p "<对话prompt>" -n 256 \
    --moe-trace ~/traces/trace_chat.jsonl -ngl 0
```

⚠️ 若 `--moe-trace` 未生效 → 补丁2 没插到位,回去看 moe-paging.cpp 的
   remap_callback 是否在 `cache->resolve(...)` 之前 dump,且构造处开了文件。

## 7. 回传 trace + 离线分析(阶段 2/3)

```bash
# 把 ~/traces/*.jsonl 推到仓库或暂存,回传我
python3 tools/profile_trace.py --trace trace_code.jsonl --manifest manifest.json --outdir out_code/
python3 tools/sram_stats.py   --trace trace_code.jsonl ...   # 复用距离/容量曲线
```

→ 产出:Qwen 版每层热表、复用距离形状(平滑 vs 双簇)、槽数、命中曲线。
   我据此判决开放项 A。

## 里程碑

| 阶段 | 出口 | 预计 |
|---|---|---|
| 0-1 合体 | llama.cpp 编译过 | 1-2 小时 |
| 2-3 补丁 | trace 采集可用 | 30 分钟 |
| 4 冒烟 | llama-cli 能跑模型 | 30 分钟 |
| 5 trace | 2 条 jsonl | 30 分钟 |
| 6 分析 | 复用距离判决 | 半天 |