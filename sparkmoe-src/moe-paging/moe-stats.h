// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Required Notice: Copyright (c) 2026 SparkMoE contributors.

#pragma once

#include <atomic>
#include <cstdint>

namespace llama_moe {

struct stats_snapshot {
    uint64_t cache_hits = 0;
    uint64_t cache_misses = 0;
    uint64_t bytes_read = 0;
    uint64_t read_count = 0;
    uint64_t read_latency_us = 0;
    uint64_t evictions = 0;
    uint64_t waits = 0;
    uint64_t duplicate_requests = 0;
};

class stats {
public:
    void add_hit(uint64_t n = 1);
    void add_miss(uint64_t n = 1);
    void add_read(uint64_t bytes, uint64_t latency_us);
    void add_eviction(uint64_t n = 1);
    void add_wait(uint64_t n = 1);
    void add_duplicate(uint64_t n = 1);

    stats_snapshot snapshot() const;
    void reset();

private:
    std::atomic<uint64_t> cache_hits{0};
    std::atomic<uint64_t> cache_misses{0};
    std::atomic<uint64_t> bytes_read{0};
    std::atomic<uint64_t> read_count{0};
    std::atomic<uint64_t> read_latency_us{0};
    std::atomic<uint64_t> evictions{0};
    std::atomic<uint64_t> waits{0};
    std::atomic<uint64_t> duplicate_requests{0};
};

}
