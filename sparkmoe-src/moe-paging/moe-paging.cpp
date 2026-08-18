// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Required Notice: Copyright (c) 2026 SparkMoE contributors.

#include "moe-paging.h"

#include "llama-impl.h"

#include <algorithm>
#include <cstdio>
#include <exception>
#include <limits>
#include <stdexcept>

// 研究补丁（TRACE-COLLECTION.md）：真实路由 trace 采集，勿合入主线。
namespace {
std::mutex g_trace_mutex;
FILE * g_trace_file = nullptr;
}

namespace llama_moe {

void llama_moe_set_trace_file(const char * path) {
    std::lock_guard<std::mutex> lock(g_trace_mutex);
    if (g_trace_file != nullptr) {
        std::fclose(g_trace_file);
        g_trace_file = nullptr;
    }
    if (path != nullptr) {
        g_trace_file = std::fopen(path, "w");
    }
}

bool mode_uses_explicit_paging(enum llama_moe_paging_mode mode) {
    return mode == LLAMA_MOE_PAGING_MODE_EXPLICIT;
}

paging_manager::paging_manager(
        ggml_backend_t backend,
        const llama_moe_paging_params & params,
        const model_index & index,
        int64_t minimum_slots) :
    backend(backend), params(params), index(index), minimum_slots(minimum_slots) {
    if (!backend || !mode_uses_explicit_paging(params.mode)) {
        throw std::runtime_error("explicit MoE paging requires a CPU backend");
    }
    if (index.tensor_count() == 0 || index.layer_count() == 0) {
        throw std::runtime_error("the model does not contain a usable MoE paging index");
    }
    if (minimum_slots <= 0) {
        throw std::runtime_error("invalid active expert count for MoE paging");
    }
    if (params.n_slots <= 0 && params.cache_bytes == 0) {
        throw std::runtime_error("explicit MoE paging requires a slot count or cache byte budget");
    }
}

paging_manager::~paging_manager() = default;

int64_t paging_manager::slots_for_layer(int32_t layer) const {
    const int64_t experts = index.expert_count(layer);
    if (experts <= 0) {
        throw std::runtime_error("missing expert metadata for layer " + std::to_string(layer));
    }

    const uint64_t layer_bytes = index.bytes_per_expert(layer);
    const uint64_t layers_count = std::max<size_t>(1, index.layer_count());
    int64_t budget_slots = experts;
    if (params.cache_bytes > 0) {
        if (layer_bytes == 0) {
            throw std::runtime_error("invalid zero-sized expert layout");
        }
        budget_slots = static_cast<int64_t>((params.cache_bytes / layers_count) / layer_bytes);
        if (budget_slots < minimum_slots) {
            const uint64_t required = layer_bytes * static_cast<uint64_t>(minimum_slots) * layers_count;
            throw std::runtime_error(
                "MoE cache budget is too small for the active experts; at least " +
                std::to_string(required) + " bytes are required");
        }
    }

    int64_t slots = params.n_slots > 0 ? params.n_slots : budget_slots;
    slots = std::min(slots, budget_slots);
    slots = std::max(slots, minimum_slots);
    return std::min(slots, experts);
}

layer_cache & paging_manager::get_or_create_layer(int32_t layer) {
    std::lock_guard<std::mutex> lock(mutex);
    auto & cache = layers[layer];
    if (!cache) {
        cache = std::make_unique<layer_cache>(
            layer,
            index.expert_count(layer),
            slots_for_layer(layer),
            params.io_threads > 0 ? static_cast<uint32_t>(params.io_threads) : 1,
            params.io_timeout_ms,
            index,
            backend);
        LLAMA_LOG_INFO("MoE paging: layer %d uses %lld expert slots\n", layer, static_cast<long long>(cache->slots()));
    }
    return *cache;
}

ggml_tensor * paging_manager::bind_pool(int32_t layer, const ggml_tensor * original) {
    if (!original) {
        return nullptr;
    }
    const auto * descriptor = index.find(original->name);
    if (!descriptor) {
        throw std::runtime_error("expert tensor is absent from the paging index: " + std::string(original->name));
    }
    return get_or_create_layer(layer).bind_tensor(original, *descriptor);
}

bool paging_manager::handles_layer(int32_t layer) const {
    return index.has_layer(layer);
}

bool paging_manager::set_expert_pinned(int32_t layer, int32_t expert, bool pinned) {
    if (!index.has_layer(layer)) {
        return false;
    }
    return get_or_create_layer(layer).set_pinned(expert, pinned);
}

uint32_t paging_manager::max_safe_ubatch() const {
    uint64_t result = std::numeric_limits<uint32_t>::max();
    bool found_layer = false;
    for (size_t layer = 0; layer < index.layer_count(); ++layer) {
        if (!index.has_layer(static_cast<int32_t>(layer))) {
            continue;
        }
        found_layer = true;
        const int64_t slots = slots_for_layer(static_cast<int32_t>(layer));
        result = std::min(result, static_cast<uint64_t>(slots / minimum_slots));
    }
    if (!found_layer || result == 0) {
        throw std::runtime_error("MoE paging cannot form a safe microbatch with the configured slots");
    }
    return static_cast<uint32_t>(result);
}

void paging_manager::remap_callback(
        ggml_tensor * destination,
        const ggml_tensor * source,
        int thread_index,
        int thread_count,
        void * user_data) {
    GGML_UNUSED(thread_count);
    if (thread_index != 0) {
        return;
    }
    auto * cache = static_cast<layer_cache *>(user_data);
    if (!cache || source->type != GGML_TYPE_I32 || destination->type != GGML_TYPE_I32 ||
            !ggml_is_contiguous(source) || !ggml_is_contiguous(destination)) {
        GGML_ABORT("invalid MoE paging remap operation");
    }
    try {
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
        cache->resolve(
            static_cast<const int32_t *>(source->data),
            static_cast<size_t>(ggml_nelements(source)),
            static_cast<int32_t *>(destination->data));
    } catch (const std::exception & error) {
        std::fprintf(stderr, "MoE paging failed: %s\n", error.what());
        GGML_ABORT("MoE paging I/O or cache failure");
    }
}

ggml_tensor * paging_manager::remap_ids(
        ggml_context * ctx,
        ggml_tensor * selected_experts,
        int32_t layer) {
    auto & cache = get_or_create_layer(layer);
    auto * remapped = ggml_map_custom1(ctx, selected_experts, remap_callback, 1, &cache);
    ggml_set_name(remapped, ("moe_slot_ids_" + std::to_string(layer)).c_str());
    return remapped;
}

stats_snapshot paging_manager::snapshot() const {
    stats_snapshot total;
    std::lock_guard<std::mutex> lock(mutex);
    for (const auto & item : layers) {
        const auto value = item.second->get_stats().snapshot();
        total.cache_hits += value.cache_hits;
        total.cache_misses += value.cache_misses;
        total.bytes_read += value.bytes_read;
        total.read_count += value.read_count;
        total.read_latency_us += value.read_latency_us;
        total.evictions += value.evictions;
        total.waits += value.waits;
        total.duplicate_requests += value.duplicate_requests;
    }
    return total;
}

void paging_manager::reset_stats() {
    std::lock_guard<std::mutex> lock(mutex);
    for (auto & item : layers) {
        item.second->reset_stats();
    }
}

}
