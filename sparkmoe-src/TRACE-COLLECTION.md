# SparkMoE 路由 trace 采集钩子

> 目标：在真实推理中把每步的路由决策 dump 成 `profile_trace.py` 可直接消费的 JSONL。
> 适用于你拿到真实机器（§7 行动 1/2）后采集 B 档基线的 trace。

## 为什么必须挂在 remap_callback

- 路由决策（expert IDs）在 `llama-graph.cpp:1992` 由 `ggml_cont(ctx0, selected_experts)` 得到
  **contiguous_ids**，但此时是图构建期，`->data` 为 NULL——**图构建期拿不到值**。
- 真正的专家 ID 数组在**图计算期**由 `remap_callback` 消费：它收到
  `source = contiguous_ids`（数据已填满）与 `user_data = layer_cache`（含 `cache->layer`）。
- 结论：唯一可靠的采集点是 `moe-paging.cpp:126-150` 的 `remap_callback`，在调用
  `cache->resolve(...)`（第 142 行）之前 dump `source->data`。

## 补丁（研究用，约 15 行）

在 `moe-paging.cpp` 中：

```cpp
// moe-paging.cpp —— 文件顶部，namespace llama_moe 前
namespace {
std::mutex g_trace_mutex;
FILE * g_trace_file = nullptr;
}

// 在 remap_callback（moe-paging.cpp:126）内、cache->resolve(...) 调用之前插入：
if (g_trace_file != nullptr) {
    const int32_t * ids = static_cast<const int32_t *>(source->data);
    const size_t n = static_cast<size_t>(ggml_nelements(source));
    std::lock_guard<std::mutex> lock(g_trace_mutex);
    std::fprintf(g_trace_file, "{\"layer\":%d,\"experts\":[", cache->layer);
    for (size_t i = 0; i < n; ++i) {
        std::fprintf(g_trace_file, "%s%d", i ? "," : "", ids[i]);
    }
    std::fprintf(g_trace_file, "]}\n");
}
```

在 paging_manager 构造处（`moe-paging.cpp:20-38`）按 flag 打开文件：

```cpp
// 研究模式：g_trace_file = fopen(trace_path, "w");  // trace_path 来自 --moe-trace 参数
```

## 输出格式与消费

- 每行：`{"layer":L,"experts":[e0,e1,...]}`，**没有 token 字段**。
- `profile_trace.py` 会自动进入流式模式：layer 回绕即视为新 token（已实现并验证）。
- decode（ubatch=1）时每行 K 个 ID；prompt 处理（ubatch=B）时每行 B×K 个 ID，
  分析器按"一次图执行 = 一个 step"处理——这正是预取建模的粒度。

用法：

```bash
python3 tools/profile_trace.py --trace capture.jsonl --manifest manifest.json --outdir out/
```

## 诚实警告

1. **每层 fprintf 会扰动时序**：不要边开 trace 边测 tok/s。正确做法：先开 trace 跑一次
   短生成拿 trace，关掉 trace 再跑基准（B/C/D 档），把 trace 只用于离线估算。
2. 这是**研究补丁**，不要合入 SparkMoE 主线（PolyForm-Noncommercial 许可仅允许分析用途）。
3. 若想少扰动，可在 resolve() 的 miss 分支里对 "miss 的专家" 计数（`moe-paging.cpp:168`），
   拿到 misses/token 的真值，但那就没有完整路由信息，热表/转移表仍需要完整 dump。
