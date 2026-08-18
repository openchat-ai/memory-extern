// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Required Notice: Copyright (c) 2026 SparkMoE contributors.

#pragma once

#include "ggml-backend.h"
#include "ggml.h"
#include "llama.h"
#include "moe-cache.h"
#include "moe-model-index.h"
#include "moe-stats.h"

#include <cstdint>
#include <memory>
#include <mutex>
#include <unordered_map>

namespace llama_moe {

class paging_manager {
public:
    paging_manager(
        ggml_backend_t backend,
        const llama_moe_paging_params & params,
        const model_index & index,
        int64_t minimum_slots);
    ~paging_manager();

    ggml_tensor * bind_pool(int32_t layer, const ggml_tensor * original);
    ggml_tensor * remap_ids(ggml_context * ctx, ggml_tensor * selected_experts, int32_t layer);
    bool handles_layer(int32_t layer) const;
    bool set_expert_pinned(int32_t layer, int32_t expert, bool pinned);
    uint32_t max_safe_ubatch() const;

    stats_snapshot snapshot() const;
    void reset_stats();

private:
    layer_cache & get_or_create_layer(int32_t layer);
    int64_t slots_for_layer(int32_t layer) const;
    static void remap_callback(
        ggml_tensor * destination,
        const ggml_tensor * source,
        int thread_index,
        int thread_count,
        void * user_data);

    ggml_backend_t backend;
    llama_moe_paging_params params;
    const model_index & index;
    int64_t minimum_slots;

    mutable std::mutex mutex;
    std::unordered_map<int32_t, std::unique_ptr<layer_cache>> layers;
};

bool mode_uses_explicit_paging(enum llama_moe_paging_mode mode);

// 研究：真实路由 trace 采集（TRACE-COLLECTION.md），path 为 NULL 时关闭
void llama_moe_set_trace_file(const char * path);

}
