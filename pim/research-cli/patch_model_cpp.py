path = '/root/sparkmoe-fork/src/llama-model.cpp'
s = open(path).read()
anchor = '''int32_t llama_model_n_expert(const struct llama_model * model) {
    return model->hparams.n_expert;
}
'''
add = '''int32_t llama_model_n_expert(const struct llama_model * model) {
    return model->hparams.n_expert;
}

int32_t llama_model_n_expert_used(const struct llama_model * model) {
    return model->hparams.n_expert_used;
}

static bool tensor_is_expert(const char * name) {
    return strstr(name, "ffn_gate_exps") || strstr(name, "ffn_up_exps") || strstr(name, "ffn_down_exps");
}

int64_t llama_model_weight_nbytes(const struct llama_model * model) {
    if (!model) {
        return 0;
    }
    int64_t total = 0;
    for (const auto & kv : model->tensors_by_name) {
        total += ggml_nbytes(kv.second);
    }
    return total;
}

int64_t llama_model_expert_weight_nbytes(const struct llama_model * model) {
    if (!model) {
        return 0;
    }
    int64_t total = 0;
    for (const auto & kv : model->tensors_by_name) {
        if (tensor_is_expert(kv.first.c_str())) {
            total += ggml_nbytes(kv.second);
        }
    }
    return total;
}
'''
assert s.count(anchor) == 1
s = s.replace(anchor, add, 1)
open(path, 'w').write(s)
print('ok')