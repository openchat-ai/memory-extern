// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Required Notice: Copyright (c) 2026 SparkMoE contributors.

#pragma once

#include "ggml.h"
#include "moe-io.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

struct llama_file;

namespace llama_moe {

bool is_pageable_expert_weight(const std::string & name);
int32_t expert_tensor_layer(const std::string & name);

enum class tensor_role {
    gate,
    up,
    down,
    gate_up,
    unknown,
};

struct tensor_descriptor {
    std::string name;
    int32_t layer = -1;
    tensor_role role = tensor_role::unknown;
    uint16_t shard = 0;
    uint64_t file_offset = 0;
    uint64_t length = 0;
    enum ggml_type type = GGML_TYPE_COUNT;
    std::array<int64_t, GGML_MAX_DIMS> shape{};
    std::array<size_t, GGML_MAX_DIMS> stride{};
    uint64_t alignment = 32;
    uint64_t expert_stride = 0;
    int64_t expert_count = 0;
};

class model_index {
public:
    void add_tensor(const std::string & name, uint16_t shard, uint64_t file_offset, const ggml_tensor * tensor);
    void open_files(const std::vector<std::unique_ptr<llama_file>> & files);

    const tensor_descriptor * find(const std::string & name) const;
    const std::shared_ptr<file_reader> & reader(uint16_t shard) const;

    size_t tensor_count() const;
    size_t layer_count() const;
    bool has_layer(int32_t layer) const;
    uint64_t bytes_per_expert(int32_t layer) const;
    int64_t expert_count(int32_t layer) const;

private:
    std::vector<tensor_descriptor> descriptors;
    std::unordered_map<std::string, size_t> by_name;
    std::vector<std::shared_ptr<file_reader>> readers;
};

}
