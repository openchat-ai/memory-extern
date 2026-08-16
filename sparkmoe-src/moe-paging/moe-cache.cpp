// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Required Notice: Copyright (c) 2026 SparkMoE contributors.

#include "moe-cache.h"

#include <algorithm>
#include <future>
#include <stdexcept>
#include <unordered_map>

namespace llama_moe {

layer_cache::layer_cache(
        int32_t layer,
        int64_t expert_count,
        int64_t slot_count,
        uint32_t io_threads,
        uint32_t io_timeout_ms,
        const model_index & index,
        ggml_backend_t backend) :
    layer(layer),
    n_experts(expert_count),
    n_slots(slot_count),
    io_timeout_ms(io_timeout_ms),
    index(index),
    backend(backend),
    executor(io_threads) {
    if (n_experts <= 0 || n_slots <= 0 || n_slots > n_experts) {
        throw std::runtime_error("invalid MoE cache dimensions");
    }
    entries.resize(static_cast<size_t>(n_slots));
    expert_to_slot.assign(static_cast<size_t>(n_experts), -1);
    pin_requested.assign(static_cast<size_t>(n_experts), false);
    for (int32_t slot = 0; slot < n_slots; ++slot) {
        entries[slot].slot_id = slot;
    }
}

ggml_tensor * layer_cache::bind_tensor(const ggml_tensor * original, const tensor_descriptor & descriptor) {
    std::lock_guard<std::mutex> lock(mutex);
    const auto existing = pool_by_name.find(descriptor.name);
    if (existing != pool_by_name.end()) {
        return pools[existing->second].tensor;
    }
    if (!original || descriptor.layer != layer || descriptor.expert_count != n_experts) {
        throw std::runtime_error("expert tensor does not match its paging layer: " + descriptor.name);
    }

    tensor_pool pool;
    ggml_init_params params{};
    params.mem_size = ggml_tensor_overhead() * 2;
    params.no_alloc = true;
    pool.context.reset(ggml_init(params));
    if (!pool.context) {
        throw std::runtime_error("failed to allocate MoE tensor metadata");
    }

    pool.tensor = ggml_new_tensor_3d(
        pool.context.get(), original->type, original->ne[0], original->ne[1], n_slots);
    ggml_set_name(pool.tensor, (descriptor.name + "_slots").c_str());
    if (pool.tensor->nb[2] != descriptor.expert_stride) {
        throw std::runtime_error("slot layout differs from GGUF expert layout: " + descriptor.name);
    }

    pool.buffer.reset(ggml_backend_alloc_ctx_tensors(pool.context.get(), backend));
    if (!pool.buffer || !pool.tensor->data) {
        throw std::runtime_error("failed to allocate MoE expert slot pool: " + descriptor.name);
    }
    pool.descriptor = &descriptor;

    const size_t pool_index = pools.size();
    pool_by_name.emplace(descriptor.name, pool_index);
    pools.push_back(std::move(pool));
    return pools.back().tensor;
}

int32_t layer_cache::choose_victim(const std::vector<bool> & reserved) const {
    int32_t victim = -1;
    uint64_t oldest = UINT64_MAX;
    for (int32_t slot = 0; slot < n_slots; ++slot) {
        const auto & entry = entries[slot];
        if (reserved[slot] || entry.pinned || entry.active_refs != 0 || entry.state == entry_state::loading) {
            continue;
        }
        if (entry.state == entry_state::empty || entry.state == entry_state::error) {
            return slot;
        }
        if (entry.last_use < oldest) {
            oldest = entry.last_use;
            victim = slot;
        }
    }
    return victim;
}

void layer_cache::resolve(const int32_t * expert_ids, size_t count, int32_t * slot_ids) {
    if (!expert_ids || !slot_ids || count == 0) {
        throw std::runtime_error("empty MoE routing request");
    }

    std::unique_lock<std::mutex> lock(mutex, std::defer_lock);
    if (!lock.try_lock()) {
        counters.add_wait();
        lock.lock();
    }
    if (pools.empty()) {
        throw std::runtime_error("MoE layer has no bound expert tensors");
    }

    std::vector<int32_t> unique_ids;
    std::unordered_map<int32_t, int32_t> request_slots;
    unique_ids.reserve(count);
    for (size_t i = 0; i < count; ++i) {
        const int32_t expert = expert_ids[i];
        if (expert < 0 || expert >= n_experts) {
            throw std::runtime_error("router returned an invalid expert ID");
        }
        if (request_slots.emplace(expert, -1).second) {
            unique_ids.push_back(expert);
        } else {
            counters.add_duplicate();
        }
    }
    if (unique_ids.size() > static_cast<size_t>(n_slots)) {
        throw std::runtime_error(
            "MoE slot count is too small for this microbatch: requested " +
            std::to_string(unique_ids.size()) + " unique experts, available " + std::to_string(n_slots));
    }

    struct miss_assignment {
        int32_t expert;
        int32_t slot;
        int32_t old_expert;
    };
    std::vector<miss_assignment> misses;
    std::vector<bool> reserved(static_cast<size_t>(n_slots), false);

    for (int32_t expert : unique_ids) {
        int32_t slot = expert_to_slot[expert];
        if (slot >= 0 && entries[slot].state == entry_state::ready) {
            entries[slot].last_use = ++clock;
            entries[slot].active_refs++;
            reserved[slot] = true;
            request_slots[expert] = slot;
            counters.add_hit();
            continue;
        }

        slot = choose_victim(reserved);
        if (slot < 0) {
            throw std::runtime_error("no evictable MoE expert slot is available");
        }
        auto & entry = entries[slot];
        const int32_t old_expert = entry.expert_id;
        if (old_expert >= 0) {
            expert_to_slot[old_expert] = -1;
            counters.add_eviction();
        }
        entry.expert_id = expert;
        entry.pinned = pin_requested[expert];
        entry.state = entry_state::loading;
        entry.active_refs = 1;
        entry.generation++;
        entry.last_use = ++clock;
        reserved[slot] = true;
        request_slots[expert] = slot;
        misses.push_back({expert, slot, old_expert});
        counters.add_miss();
    }

    std::vector<std::future<io_result>> futures;
    for (const auto & miss : misses) {
        for (auto & pool : pools) {
            const auto * descriptor = pool.descriptor;
            const uint64_t source_offset = descriptor->file_offset +
                static_cast<uint64_t>(miss.expert) * descriptor->expert_stride;
            auto * destination = static_cast<uint8_t *>(pool.tensor->data) +
                static_cast<size_t>(miss.slot) * descriptor->expert_stride;
            const size_t length = static_cast<size_t>(descriptor->expert_stride);
            const auto reader = index.reader(descriptor->shard);
            const uint32_t timeout = io_timeout_ms;
            futures.push_back(executor.submit([reader, source_offset, destination, length, timeout] {
                return reader->read_exact(source_offset, destination, length, timeout);
            }));
        }
    }

    std::string read_error;
    for (auto & future : futures) {
        const io_result result = future.get();
        if (result.ok) {
            counters.add_read(result.bytes, result.latency_us);
        } else if (read_error.empty()) {
            read_error = result.error;
        }
    }

    if (!read_error.empty()) {
        for (const auto & miss : misses) {
            auto & entry = entries[miss.slot];
            entry.expert_id = -1;
            entry.state = entry_state::error;
            entry.active_refs = 0;
            request_slots[miss.expert] = -1;
        }
        throw std::runtime_error("MoE expert read failed in layer " + std::to_string(layer) + ": " + read_error);
    }

    for (const auto & miss : misses) {
        auto & entry = entries[miss.slot];
        entry.state = entry_state::ready;
        expert_to_slot[miss.expert] = miss.slot;
    }

    for (size_t i = 0; i < count; ++i) {
        const int32_t slot = request_slots.at(expert_ids[i]);
        if (slot < 0) {
            throw std::runtime_error("MoE expert mapping failed");
        }
        slot_ids[i] = slot;
    }
    for (int32_t expert : unique_ids) {
        auto & entry = entries[request_slots.at(expert)];
        if (entry.active_refs > 0) {
            entry.active_refs--;
        }
    }
}

bool layer_cache::set_pinned(int32_t expert, bool pinned) {
    std::lock_guard<std::mutex> lock(mutex);
    if (expert < 0 || expert >= n_experts) {
        return false;
    }
    pin_requested[expert] = pinned;
    const int32_t slot = expert_to_slot[expert];
    if (slot >= 0) {
        entries[slot].pinned = pinned;
    }
    return true;
}

int64_t layer_cache::slots() const { return n_slots; }
const stats & layer_cache::get_stats() const { return counters; }
void layer_cache::reset_stats() { counters.reset(); }

}
