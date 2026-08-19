#include <cstdio>
#include <cstring>
#include <cstdint>
#include <cstdlib>
#include <string>
#include <vector>

#include "gguf.h"
#include "llama.h"

static ggml_type resolve_type(const char * s) {
    struct { const char * n; ggml_type t; } const M[] = {
        { "f32",   GGML_TYPE_F32      }, { "f16",   GGML_TYPE_F16      }, { "bf16",  GGML_TYPE_BF16 },
        { "q4_0",  GGML_TYPE_Q4_0     }, { "q4_1",  GGML_TYPE_Q4_1     },
        { "q5_0",  GGML_TYPE_Q5_0     }, { "q5_1",  GGML_TYPE_Q5_1     },
        { "q8_0",  GGML_TYPE_Q8_0     }, { "q2_K",  GGML_TYPE_Q2_K     },
        { "q3_K",  GGML_TYPE_Q3_K     }, { "q4_K",  GGML_TYPE_Q4_K     },
        { "q5_K",  GGML_TYPE_Q5_K     }, { "q6_K",  GGML_TYPE_Q6_K     },
        { "iq2_xxs",GGML_TYPE_IQ2_XXS }, { "iq2_xs",GGML_TYPE_IQ2_XS   },
        { "iq3_xxs",GGML_TYPE_IQ3_XXS }, { "iq1_s", GGML_TYPE_IQ1_S    },
        { "iq1_m", GGML_TYPE_IQ1_M    }, { "iq4_nl",GGML_TYPE_IQ4_NL   },
        { "iq4_xs",GGML_TYPE_IQ4_XS   }, { "iq3_s", GGML_TYPE_IQ3_S    },
        { "iq2_s", GGML_TYPE_IQ2_S    },
    };
    for (const auto & e : M) if (strcmp(s, e.n) == 0) return e.t;
    fprintf(stderr, "error: unknown ggml type '%s'\n", s);
    exit(2);
}

static std::vector<ggml_type> parse_type_list(const char * s) {
    std::vector<ggml_type> out;
    for (char * tok = strtok((char *) s, ","); tok; tok = strtok(NULL, ",")) {
        out.push_back(resolve_type(tok));
    }
    return out;
}

static bool list_has(const std::vector<ggml_type> & v, ggml_type t) {
    for (ggml_type x : v) if (x == t) return true;
    return false;
}

// llama.cpp 用 std::regex_search 匹配 tensor 名（子串、`.`是通配符）。
// 所以精确名字必须转义特殊字符并用 ^$ 锚定，否则 "output.weight" 会误匹配
// "attn_output.weight"。
static std::string escape_exact_name(const char * s) {
    std::string o = "^";
    for (const char * p = s; *p; ++p) {
        if (strchr(".^$|()[]{}*+?\\", *p) != NULL) o += '\\';
        o += *p;
    }
    o += '$';
    return o;
}

int main(int argc, char ** argv) {
    if (argc < 4) {
        fprintf(stderr,
            "usage: %s <in.gguf> <out.gguf> --from T,T..T --to T [--dry-run] [-t N] [-f F]\n"
            "  --from      source ggml types to rewrite (comma list, e.g. iq3_xxs,iq3_s,iq4_xs)\n"
            "  --to        target ggml type (default q8_0)\n"
            "  --dry-run   only print what would change, do not write\n"
            "  -t N        threads for llama.cpp quantize (0 = auto)\n"
            "  -f F        llama_ftype used as quantized default so overrides take effect\n"
            "              (all tensors are overridden; default MOSTLY_Q3_K_S)\n",
            argv[0]);
        return 2;
    }

    const char * in  = argv[1];
    const char * out = argv[2];
    std::vector<ggml_type> from_types;
    ggml_type to_type = GGML_TYPE_Q8_0;
    bool dry_run = false;
    int  nthread = 0;
    int  ftype_i = LLAMA_FTYPE_MOSTLY_Q3_K_S;

    for (int i = 3; i < argc; i++) {
        if      (strcmp(argv[i], "--from")    == 0 && i + 1 < argc) from_types = parse_type_list(argv[++i]);
        else if (strcmp(argv[i], "--to")      == 0 && i + 1 < argc) to_type   = resolve_type(argv[++i]);
        else if (strcmp(argv[i], "--dry-run") == 0)                 dry_run   = true;
        else if ((strcmp(argv[i], "-t") == 0 || strcmp(argv[i], "--threads") == 0) && i + 1 < argc) nthread = atoi(argv[++i]);
        else if (strcmp(argv[i], "-f")        == 0 && i + 1 < argc) ftype_i   = atoi(argv[++i]);
        else { fprintf(stderr, "unknown arg: %s\n", argv[i]); return 2; }
    }
    if (from_types.empty()) {
        fprintf(stderr, "error: --from 至少指定一个类型\n");
        return 2;
    }

    // ---- 读 GGUF 元数据，自动推导 override 表（全部张量显式指定目标类型）----
    struct gguf_init_params gp = { /*no_alloc*/ true, /*ctx*/ NULL };
    gguf_context * ctx = gguf_init_from_file(in, gp);
    if (!ctx) { fprintf(stderr, "error: failed to read GGUF %s\n", in); return 2; }
    const int n = (int) gguf_get_n_tensors(ctx);

    std::vector<llama_model_tensor_override> ov;
    std::vector<std::string> patterns;          // owns the escaped pattern strings
    ov.reserve(n + 1);
    patterns.reserve(n + 1);
    int n_rewrite = 0, n_keep = 0;
    uint64_t sz_rewrite = 0, sz_keep = 0;
    for (int i = 0; i < n; i++) {
        const char *       name = gguf_get_tensor_name(ctx, i);
        const ggml_type    cur  = gguf_get_tensor_type(ctx, i);
        const ggml_type    tgt  = list_has(from_types, cur) ? to_type : cur;
        if (tgt != cur) { n_rewrite++; sz_rewrite += gguf_get_tensor_size(ctx, i); }
        else            { n_keep++;    sz_keep    += gguf_get_tensor_size(ctx, i); }
        patterns.push_back(escape_exact_name(name));
        ov.push_back({ patterns.back().c_str(), tgt });
    }
    ov.push_back({ nullptr, GGML_TYPE_COUNT });

    fprintf(stderr, "[%s] rewrite %d tensors (%.2f MiB src), keep %d tensors (%.2f MiB), total %d\n",
            dry_run ? "DRY-RUN" : "RUN", n_rewrite, sz_rewrite/1048576.0, n_keep, sz_keep/1048576.0, n);

    // ---- 交给 llama.cpp 官方 quantize 管线 ----
    llama_model_quantize_params params = llama_model_quantize_default_params();
    params.ftype            = (llama_ftype) ftype_i;
    params.nthread          = nthread;
    params.allow_requantize = true;   // 允许从已量化类型 (iq3/iq4) requantize
    params.dry_run          = dry_run;
    params.tt_overrides     = ov.data();

    const uint32_t rc = llama_model_quantize(in, out, &params);
    fprintf(stderr, "llama_model_quantize rc=%u\n", rc);
    return rc == 0 ? 0 : 2;
}