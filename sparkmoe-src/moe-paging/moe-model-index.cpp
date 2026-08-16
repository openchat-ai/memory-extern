// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Required Notice: Copyright (c) 2026 SparkMoE contributors.

#include "moe-model-index.h"

#include "llama-mmap.h"

#include <algorithm>
#include <limits>
#include <stdexcept>

namespace llama_moe {

static tensor_role role_from_name(const std::string & name) {
    const size_t role_offset = name.find('.', 4);
    if (role_offset == std::string::npos) {
        return tensor_role::unknown;
    }
    const std::string role = name.substr(role_offset + 1);
    if (role == "ffn_gate_up_exps.weight") {
        return tensor_role::gate_up;
    }
    if (role == "ffn_gate_exps.weight") {
        return tensor_role::gate;
    }
    if (role == "ffn_up_exps.weight") {
        return tensor_role::up;
    }
    if (role == "ffn_down_exps.weight") {
        return tensor_role::down;
    }
    return tensor_role::unknown;
}

bool is_pageable_expert_weight(const std::string & name) {
    return name.size() > 7 && name.compare(name.size() - 7, 7, ".weight") == 0 &&
        role_from_name(name) != tensor_role::unknown && expert_tensor_layer(name) >= 0;
}

int32_t expert_tensor_layer(const std::string & name) {
    if (name.compare(0, 4, "blk.") != 0) {
        return -1;
    }
    const size_t end = name.find('.', 4);
    if (end == std::string::npos || end == 4) {
        return -1;
    }
    int64_t layer = 0;
    for (size_t i = 4; i < end; ++i) {
        const char digit = name[i];
        if (digit < '0' || digit > '9') {
            return -1;
        }
        layer = layer * 10 + (digit - '0');
        if (layer > std::numeric_limits<int32_t>::max()) {
            return -1;
        }
    }
    return static_cast<int32_t>(layer);
}

void model_index::add_tensor(
        const std::string & name,
        uint16_t shard,
        uint64_t file_offset,
        const ggml_tensor * tensor) {
    if (!tensor || tensor->ne[2] <= 0) {
        throw std::runtime_error("invalid paged expert tensor: " + name);
    }
    if (by_name.count(name) != 0) {
        return;
    }

    tensor_descriptor descriptor;
    descriptor.name = name;
    descriptor.shard = shard;
    descriptor.file_offset = file_offset;
    descriptor.length = ggml_nbytes(tensor);
    descriptor.type = tensor->type;
    descriptor.role = role_from_name(name);
    descriptor.expert_stride = tensor->nb[2];
    descriptor.expert_count = tensor->ne[2];

    if (descriptor.role == tensor_role::unknown) {
        throw std::runtime_error("unsupported paged tensor role: " + name);
    }
    descriptor.layer = expert_tensor_layer(name);
    if (descriptor.layer < 0) {
        throw std::runtime_error("cannot determine layer for paged tensor: " + name);
    }
    if (descriptor.expert_stride == 0 || descriptor.expert_stride * descriptor.expert_count > descriptor.length) {
        throw std::runtime_error("invalid expert layout for paged tensor: " + name);
    }

    for (int i = 0; i < GGML_MAX_DIMS; ++i) {
        descriptor.shape[i] = tensor->ne[i];
        descriptor.stride[i] = tensor->nb[i];
    }

    by_name.emplace(name, descriptors.size());
    descriptors.push_back(std::move(descriptor));
}

void model_index::open_files(const std::vector<std::unique_ptr<llama_file>> & files) {
    readers.clear();
    readers.reserve(files.size());
    for (const auto & file : files) {
        readers.push_back(make_file_reader(file->file_id(), file->size()));
    }

    for (const auto & descriptor : descriptors) {
        if (descriptor.shard >= readers.size()) {
            throw std::runtime_error("paged tensor refers to a missing GGUF shard: " + descriptor.name);
        }
        const uint64_t file_size = readers[descriptor.shard]->size();
        if (descriptor.file_offset > file_size || descriptor.length > file_size - descriptor.file_offset) {
            throw std::runtime_error("paged tensor is outside its GGUF shard: " + descriptor.name);
        }
    }
}

const tensor_descriptor * model_index::find(const std::string & name) const {
    const auto it = by_name.find(name);
    return it == by_name.end() ? nullptr : &descriptors[it->second];
}

const std::shared_ptr<file_reader> & model_index::reader(uint16_t shard) const {
    if (shard >= readers.size()) {
        throw std::runtime_error("invalid GGUF shard index");
    }
    return readers[shard];
}

size_t model_index::tensor_count() const { return descriptors.size(); }

size_t model_index::layer_count() const {
    int32_t highest = -1;
    for (const auto & descriptor : descriptors) {
        highest = std::max(highest, descriptor.layer);
    }
    return highest < 0 ? 0 : static_cast<size_t>(highest + 1);
}

bool model_index::has_layer(int32_t layer) const {
    return std::any_of(descriptors.begin(), descriptors.end(), [layer](const tensor_descriptor & descriptor) {
        return descriptor.layer == layer;
    });
}

uint64_t model_index::bytes_per_expert(int32_t layer) const {
    uint64_t total = 0;
    for (const auto & descriptor : descriptors) {
        if (descriptor.layer == layer) {
            total += descriptor.expert_stride;
        }
    }
    return total;
}

int64_t model_index::expert_count(int32_t layer) const {
    int64_t count = 0;
    for (const auto & descriptor : descriptors) {
        if (descriptor.layer == layer) {
            if (count != 0 && count != descriptor.expert_count) {
                throw std::runtime_error("inconsistent expert count in layer " + std::to_string(layer));
            }
            count = descriptor.expert_count;
        }
    }
    return count;
}

}
