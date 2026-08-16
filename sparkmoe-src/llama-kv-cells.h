#pragma once

#include "llama.h"
#include "llama-cparams.h"

#include <bitset>
#include <cassert>
#include <cstring>
#include <map>
#include <set>
#include <vector>

struct llama_kv_cell_ext {
    // 2D spatial positions, typically used for M-RoPE
    llama_pos x = 0;
    llama_pos y = 0;

    // return true if the current 2D spatial position is greater than other
    bool is_2d_gt(llama_pos ox, llama_pos oy) const {
        return (y > oy) || (y == oy && x > ox);
    }

    void reset() {
        static_assert(std::is_trivially_copyable_v<llama_kv_cell_ext>);

        memset(this, 0, sizeof(*this));
    }
};

// meta information about KV cells that can be part of multiple sequences at the same time
// TODO: add unit tests
class llama_kv_cells {
public:
    void reset() {
        for (uint32_t i = 0; i < pos.size(); ++i) {
            pos[i]   = -1;
            ext[i].reset();
            shift[i] =  0;
            seq[i].reset();
        }

        has_shift = false;

        used.clear();

        for (uint32_t s = 0; s < LLAMA_MAX_SEQ; ++s) {
            seq_pos[s].clear();
        }
    }

    void reset_shift() {
        has_shift = false;

        for (uint32_t i = 0; i < shift.size(); ++i) {
            shift[i] = 0;
        }
    }

    uint32_t size() const {
        return pos.size();
    }

    void resize(uint32_t n) {
        pos.resize(n);
        ext.resize(n);
        shift.resize(n);
        seq.resize(n);

        reset();
    }

    bool is_empty(uint32_t i) const {
        assert(i < pos.size());
        assert((pos[i] < 0 && pos[i] == -1) || pos[i] >= 0);

        return pos[i] == -1;
    }

    uint32_t get_used() const {
        return used.size();
    }

    // the index of the first cell that is used
    // return 0 if no cells are used
    uint32_t used_min() const {
        return used.empty() ? 0 : *used.begin();
    }

    // the index of the last cell that is used + 1
    // return 0 if no cells are used
    uint32_t used_max_p1() const {
        return used.empty() ? 0 : *used.rbegin() + 1;
    }

    bool get_has_shift() const {
        return has_shift;
    }

    // move cell isrc to idst (used during defrag)
    //void mv(uint32_t isrc, uint32_t idst) {
    //    assert(isrc < pos.size());
    //    assert(idst < pos.size());

    //    assert(pos[idst] == -1);
    //    assert(pos[isrc] != -1);

    //    pos  [idst] = pos  [isrc];
    //    shift[idst] = shift[isrc];
    //    seq  [idst] = seq  [isrc];

    //    pos  [isrc] = -1;
    //    shift[isrc] =  0;
    //    seq  [isrc].reset();