import re, shutil

h_path = "/root/sparkmoe-fork/include/llama.h"
cpp_path = "/root/sparkmoe-fork/src/llama-model.cpp"

shutil.copy(h_path, h_path + ".bak2")
shutil.copy(cpp_path, cpp_path + ".bak2")

with open(h_path) as f:
    h = f.read()

if "llama_model_sram_resident" not in h:
    anchor = "LLAMA_API int64_t llama_model_expert_weight_nbytes(const struct llama_model * model);"
    assert anchor in h, "llama.h anchor not found"
    decl = anchor + "\n\n    // Copy all weight tensors into a resident SRAM region (simulated on-chip memory)\n    // and repoint tensor data at it. Returns bytes resident.\n    LLAMA_API int64_t llama_model_sram_resident(const struct llama_model * model);"
    h = h.replace(anchor, decl)
    with open(h_path, "w") as f:
        f.write(h)
    print("llama.h patched")
else:
    print("llama.h already has sram api")

with open(cpp_path) as f:
    cpp = f.read()

if "llama_model_sram_resident" not in cpp:
    anchor = "int64_t llama_model_expert_weight_nbytes(const struct llama_model * model) {"
    assert anchor in cpp, "cpp anchor not found"
    impl = """int64_t llama_model_sram_resident(const struct llama_model * model) {
    if (!model) {
        return 0;
    }
    int64_t total = 0;
    for (const auto & kv : model->tensors_by_name) {
        ggml_tensor * t = kv.second;
        if (!t || !t->data || t->type == GGML_TYPE_NONE) {
            continue;
        }
        const size_t nbytes = ggml_nbytes(t);
        void * sram = nullptr;
        if (posix_memalign(&sram, 64, nbytes) != 0) {
            break;
        }
        memcpy(sram, t->data, nbytes);
        t->data = sram;
        total += nbytes;
    }
    return total;
}

"""
    idx = cpp.index(anchor)
    cpp = cpp[:idx] + impl + cpp[idx:]
    with open(cpp_path, "w") as f:
        f.write(cpp)
    print("llama-model.cpp patched")
else:
    print("llama-model.cpp already has sram impl")
