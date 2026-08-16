// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Required Notice: Copyright (c) 2026 SparkMoE contributors.

#pragma once

#include "ggml-backend.h"
#include "ggml-cpp.h"
#include "moe-io.h"
#include "moe-model-index.h"
#include "moe-stats.h"

#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

namespace llama_moe {

enum class entry_state {
    empty,
    loading,
    ready,
    in_use,
    error,
};

struct cache_entry {
    int32_t expert_id = -1;
    int32_t slot_id = -1;
    entry_state state = entry_state::empty;
    uint64_t last_use = 0;
    bool pinned = false;
    uint32_t active_refs = 0;
    uint64_t generation = 0;
};

struct tensor_pool {
    ggml_tensor * tensor = nullptr;
    ggml_context_ptr context;
    ggml_backend_buffer_ptr buffer;
    const tensor_descriptor * descriptor = nullptr;
};

class layer_cache {
public:
    layer_cache(
        int32_t layer,
        int64_t expert_count,
        int64_t slot_count,
        uint32_t io_threads,
        uint32_t io_timeout_ms,
        const model_index & index,
        ggml_backend_t backend);

    ggml_tensor * bind_tensor(const ggml_tensor * original, const tensor_descriptor & descriptor);
    void resolve(const int32_t * expert_ids, size_t count, int32_t * slot_ids);
    bool set_pinned(int32_t expert, bool pinned);

    int64_t slots() const;
    const stats & get_stats() const;
    void reset_stats();

private:
    int32_t choose_victim(const std::vector<bool> & reserved) const;

    int32_t layer;
    int64_t n_experts;
    int64_t n_slots;
    uint32_t io_timeout_ms;
    const model_index & index;
    ggml_backend_t backend;
    io_executor executor;

    mutable std::mutex mutex;
    uint64_t clock = 0;
    std::vector<cache_entry> entries;
    std::vector<int32_t> expert_to_slot;
    std::vector<bool> pin_requested;
    std::vector<tensor_pool> pools;
    std::unordered_map<std::string, size_t> pool_by_name;
    stats counters;
};

}
