// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Required Notice: Copyright (c) 2026 SparkMoE contributors.

#include "moe-stats.h"

namespace llama_moe {

void stats::add_hit(uint64_t n) { cache_hits.fetch_add(n, std::memory_order_relaxed); }
void stats::add_miss(uint64_t n) { cache_misses.fetch_add(n, std::memory_order_relaxed); }
void stats::add_eviction(uint64_t n) { evictions.fetch_add(n, std::memory_order_relaxed); }
void stats::add_wait(uint64_t n) { waits.fetch_add(n, std::memory_order_relaxed); }
void stats::add_duplicate(uint64_t n) { duplicate_requests.fetch_add(n, std::memory_order_relaxed); }

void stats::add_read(uint64_t bytes, uint64_t latency_us) {
    bytes_read.fetch_add(bytes, std::memory_order_relaxed);
    read_count.fetch_add(1, std::memory_order_relaxed);
    read_latency_us.fetch_add(latency_us, std::memory_order_relaxed);
}

stats_snapshot stats::snapshot() const {
    return {
        cache_hits.load(std::memory_order_relaxed),
        cache_misses.load(std::memory_order_relaxed),
        bytes_read.load(std::memory_order_relaxed),
        read_count.load(std::memory_order_relaxed),
        read_latency_us.load(std::memory_order_relaxed),
        evictions.load(std::memory_order_relaxed),
        waits.load(std::memory_order_relaxed),
        duplicate_requests.load(std::memory_order_relaxed),
    };
}

void stats::reset() {
    cache_hits.store(0, std::memory_order_relaxed);
    cache_misses.store(0, std::memory_order_relaxed);
    bytes_read.store(0, std::memory_order_relaxed);
    read_count.store(0, std::memory_order_relaxed);
    read_latency_us.store(0, std::memory_order_relaxed);
    evictions.store(0, std::memory_order_relaxed);
    waits.store(0, std::memory_order_relaxed);
    duplicate_requests.store(0, std::memory_order_relaxed);
}

}
