# MoE expert paging

## Configuration

`--moe-paging explicit` enables the subsystem. Set `--moe-cache-mib N`, `--moe-slots N`, or both. If both are present, both limits apply. The cache rejects a byte budget too small to hold at least the model's active-expert count per paged layer.

Additional options:

- `--moe-io-threads N`: file-read worker count.
- `--moe-io-mode buffered`: the implemented I/O path.
- `--moe-cache-policy predictive`: the implemented policy (cumulative per-expert use-count eviction; see note below).

> **Eviction policy note.** `layer_cache::choose_victim` evicts the entry with the lowest
> cumulative `use_count` (a per-expert heat counter that persists for the cache lifetime),
> not the least-recently-used slot. For monotone-superset MoE sessions (e.g. kimi-k3's
> pass-by-pass expert growth, where pass_v ⊆ pass_v+1) this cumulative-heat policy keeps the
> frequently-reused expert working set resident across passes and cuts HDD→SSD re-reads from
> the LRU baseline (sim_cache predictive ≈ 88% hit vs LRU ≈ 36% on the k3 trace).

Direct I/O is rejected because correct cross-platform alignment and tail handling are not implemented.

Explicit mode discovers standard routed expert weights by tensor role and layout instead of a model-name allowlist. Qwen3.5/Qwen3.6 MoE and Gemma 4 26B-A4B use this layout. Unknown or incompatible layouts fail during model loading. See [supported models](SUPPORTED_MODELS.md).

MTP draft contexts can use explicit paging. The target and draft contexts own separate bounded cache managers so their slot lifetimes cannot overwrite each other.

## Memory accounting

Each indexed layer allocates compact three-dimensional tensor pools whose third dimension is the slot count. The byte budget is divided across indexed layer positions and converted using the exact tensor strides reported by GGML. Metadata, fixed weights, compute buffers, KV cache, and OS/runtime overhead are separate from this budget.

## Large microbatches

If the configured physical microbatch could request more active experts than the available slots, SparkMoE reduces the effective microbatch before graph allocation. A single routing operation that still exceeds capacity fails with the requested and available counts.

## Split GGUF

Descriptors retain the upstream shard index and a duplicated read handle for each opened GGUF. Bounds are checked against each shard before inference begins.
