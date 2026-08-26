#include "arg.h"
#include "common.h"
#include "llama.h"
#include "sampling.h"
#include "ggml-backend.h"

extern "C" {
void ggml_chip_set_threads(int n);
int ggml_chip_get_threads(void);
void ggml_chip_get_stats(long long * flops, long long * bytes, long long * ops);
}

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <thread>
#include <chrono>
#include <unistd.h>
#include <dlfcn.h>

int main(int argc, char ** argv) {
    if (argc > 1 && strcmp(argv[1], "--chip-help") == 0) {
        fprintf(stderr,
            "research-cli 参数速查 (通用参数用 --help 查看)\n"
            "\n"
            "  -m <路径>          模型文件 (必填)\n"
            "  -i                 交互聊天模式\n"
            "  -t <N>             CPU线程数, 非MoE部分 (默认4)\n"
            "  --predict <N>      每次最多生成token数\n"
            "  --temp <X>         温度 (默认0.8)\n"
            "  --seed <N>         随机种子 (默认随机)\n"
            "  -p <文本>          单轮prompt\n"
            "  --sys <文本>       系统提示词\n"
            "\n"
            "芯片/模拟参数:\n"
            "  --traffic          打印每token内存流量账单\n"
            "  --chip-tok <N>     内置模拟器目标速度tok/s, 0=关 (默认13.9)\n"
            "  --stream-bw <N>    板子带宽上限GiB/s (默认22)\n"
            "  --chip-offload <N> 内置模拟器接管MoE的线程数, 0=关 (默认0)\n"
            "  --full-recompute   全量重算模式\n"
            "  --sram             SRAM常驻模式\n"
            "  --chip on|off|<so> 加载芯片插件后端 (默认on)\n"
            "\n"
            "环境变量:\n"
            "  CHIP_NWORKERS=<N>            插件后端worker数 (默认4)\n"
            "  CHIP_ZCOPY=0                 关闭零拷贝, 退回SRAM staging路径 (A/B用)\n"
            "  CHIP_LOG_LEVEL=<0|1|2>       插件日志级别\n");
        return 0;
    }
    double chip_tok = 13.9;
    double stream_bw = 22.0;
    bool full_recompute = false;
    bool sram_on = false;
    bool chip_traffic = false;
    int chip_offload = 0;
    bool chip_on = true;
    const char * chip_so = "/root/chipwork/libchip-backend.so";
    for (int i = 1; i < argc; ++i) {
        if (strcmp(argv[i], "--chip") == 0 && i + 1 < argc) {
            const char * v = argv[++i];
            if (strcmp(v, "off") == 0) {
                chip_on = false;
            } else if (strcmp(v, "on") != 0) {
                chip_so = v;
            }
            continue;
        }
    }
    if (chip_on && access(chip_so, R_OK) != 0) {
        fprintf(stderr, "[chip] 插件未找到: %s (退回纯CPU模式)\n", chip_so);
        chip_on = false;
    }
    unsetenv("GGML_BACKEND_PATH");
    if (chip_on) {
        ggml_backend_load(chip_so);
    }
    ggml_backend_load_all();
    std::vector<char *> carg;
    carg.reserve(argc);
    for (int i = 0; i < argc; ++i) {
        if (strcmp(argv[i], "--chip") == 0 && i + 1 < argc) {
            ++i;
            continue;
        }
        if (strcmp(argv[i], "--chip-tok") == 0 && i + 1 < argc) {
            chip_tok = atof(argv[++i]);
            continue;
        }
        if (strcmp(argv[i], "--stream-bw") == 0 && i + 1 < argc) {
            stream_bw = atof(argv[++i]);
            continue;
        }
        if (strcmp(argv[i], "--full-recompute") == 0) {
            full_recompute = true;
            continue;
        }
        if (strcmp(argv[i], "--sram") == 0) {
            sram_on = true;
            continue;
        }
        if (strcmp(argv[i], "--traffic") == 0) {
            chip_traffic = true;
            continue;
        }
        if (strcmp(argv[i], "--chip-offload") == 0 && i + 1 < argc) {
            chip_offload = atoi(argv[++i]);
            continue;
        }
        carg.push_back(argv[i]);
    }
    if (chip_offload > 0) {
        ggml_chip_set_threads(chip_offload);
        fprintf(stderr, "chip-sim: offload ON, %d chip threads take over MoE expert matmuls\n", ggml_chip_get_threads());
    }

    common_params params;
    if (!common_params_parse((int) carg.size(), carg.data(), params, LLAMA_EXAMPLE_COMPLETION, nullptr)) {
        return 1;
    }
    if (params.n_predict < 0) {
        params.n_predict = 512;
    }
    auto init = common_init_from_params(params);
    if (!init || init->model() == nullptr || init->context() == nullptr) {
        fprintf(stderr, "research-cli: model/context init failed\n");
        return 1;
    }

    llama_model * model = init->model();
    llama_context * ctx = init->context();
    common_sampler * smpl = init->sampler(0);
    const llama_vocab * vocab = llama_model_get_vocab(model);
    const llama_token eos = llama_vocab_eos(vocab);

    char mbuf[64];
    if (llama_model_meta_val_str(model, "qwen3.expert_count", mbuf, sizeof mbuf) >= 0) {
        fprintf(stderr, "chip-sim: n_expert=%s\n", mbuf);
    }
    if (llama_model_meta_val_str(model, "qwen3.expert_used_count", mbuf, sizeof mbuf) >= 0) {
        fprintf(stderr, "chip-sim: n_expert_used=%s\n", mbuf);
    }
    const int32_t n_expert = llama_model_n_expert(model);
    const int32_t n_expert_used = llama_model_n_expert_used(model);
    const int64_t w_total = llama_model_weight_nbytes(model);
    const int64_t w_expert = llama_model_expert_weight_nbytes(model);
    const int64_t w_shared = w_total - w_expert;
    const int64_t w_active = w_shared + w_expert * n_expert_used / n_expert;
    int64_t sram_bytes = 0;
    if (sram_on) {
        fprintf(stderr, "chip-sim: copying weights into SRAM region...\n");
        sram_bytes = llama_model_sram_resident(model);
        fprintf(stderr, "chip-sim: SRAM resident %lld MB / %lld MB\n",
            (long long) (sram_bytes / (1024 * 1024)),
            (long long) (w_total / (1024 * 1024)));
    }
    long long vmlck_kb = 0;
    {
        FILE * f = fopen("/proc/self/status", "r");
        if (f) {
            char line[256];
            while (fgets(line, sizeof(line), f)) {
                if (strncmp(line, "VmLck:", 6) == 0) {
                    sscanf(line + 6, "%lld", &vmlck_kb);
                    break;
                }
            }
            fclose(f);
        }
    }
    if (vmlck_kb > 0) {
        fprintf(stderr, "chip-sim: mlock resident %lld MB (zero-copy, page-cache pinned)\n",
            vmlck_kb / 1024);
    }
    long long chip_flops_base = 0;
    if (chip_offload > 0) {
        long long b0 = 0, b1 = 0;
        ggml_chip_get_stats(&chip_flops_base, &b0, &b1);
    }
    typedef void (*chip_stats5_fn)(long long *, long long *, long long *, long long *, int *);
    chip_stats5_fn chip_stats_plugin = NULL;
    long long chip_flops_base_p = 0;
    if (chip_on) {
        void * h = dlopen(chip_so, RTLD_NOW | RTLD_GLOBAL);
        if (h) {
            chip_stats_plugin = (chip_stats5_fn)dlsym(h, "ggml_backend_chip_get_stats");
            if (chip_stats_plugin) {
                long long b0 = 0, b1 = 0, b2 = 0, b3 = 0;
                int b4 = 0;
                chip_stats_plugin(&chip_flops_base_p, &b0, &b1, &b2, &b4);
                (void) b4;
            }
        }
    }
    fprintf(stderr, "chip-sim: weights total=%lld MB expert=%lld MB shared=%lld MB per-token-active=%lld MB (expert %d/%d)\\n",
        (long long) (w_total / (1024 * 1024)),
        (long long) (w_expert / (1024 * 1024)),
        (long long) (w_shared / (1024 * 1024)),
        (long long) (w_active / (1024 * 1024)),
        n_expert_used, n_expert);

    llama_token im_end = -1;
    llama_token eot = -1;
    for (const char * s : {"<|im_end|>", "<|endoftext|>"}) {
        std::vector<llama_token> tb(8);
        const int32_t n = llama_tokenize(vocab, s, (int32_t) std::strlen(s), tb.data(), 8, false, true);
        if (n == 1) {
            if (im_end < 0) {
                im_end = tb[0];
            } else {
                eot = tb[0];
            }
        }
    }
    fprintf(stderr, "research-cli: chip-sim %.1f tok/s  eos=%d im_end=%d eot=%d  (--chip-help 查看全部参数)\n", chip_tok, (int) eos, (int) im_end, (int) eot);

    auto pace = [&](std::chrono::steady_clock::time_point t0) {
        if (chip_tok <= 0.0) {
            return;
        }
        auto dt = std::chrono::duration<double>(1.0 / chip_tok);
        auto el = std::chrono::steady_clock::now() - t0;
        if (el < dt) {
            std::this_thread::sleep_for(dt - el);
        }
    };

    auto generate = [&](const std::vector<llama_token> & prefill, std::string & out, bool show_ids, int & n_gen, int & n_decoded) {
        std::vector<llama_token> toks = prefill;
        n_gen = 0;
        n_decoded = 0;
        std::string pending;
        const int64_t act_per_tok = (int64_t) llama_model_n_embd(model) * 2 + (int64_t) llama_vocab_n_tokens(vocab) * 2;
        int64_t cum_w = 0, cum_act = 0;
        double t_prefill = 0.0;
        double t_decode = 0.0;
        double t_wall = 0.0;
        auto t_start = std::chrono::steady_clock::now();
        bool first_batch = true;
        while (!toks.empty()) {
            n_decoded += (int) toks.size();
            auto t0 = std::chrono::steady_clock::now();
            const llama_batch batch = llama_batch_get_one(toks.data(), (int32_t) toks.size());
            if (llama_decode(ctx, batch) != 0) {
                fprintf(stderr, "research-cli: decode failed\n");
                return false;
            }
            const int64_t w_bytes = (int64_t) toks.size() * w_active;
            const int64_t a_bytes = (int64_t) toks.size() * act_per_tok;
            cum_w += w_bytes;
            cum_act += a_bytes;
            if (chip_traffic)
                fprintf(stderr, "[chip] t=%7.1fms %s n=%d w=%.1fMB act=%.3fMB cumW=%.0fMB\n",
                std::chrono::duration<double>(std::chrono::steady_clock::now() - t_start).count() * 1000.0,
                first_batch ? "prefill" : "decode", (int) toks.size(),
                w_bytes / 1048576.0, a_bytes / 1048576.0, cum_w / 1048576.0);
            const llama_token tok = common_sampler_sample(smpl, ctx, -1);
            common_sampler_accept(smpl, tok, true);
            const std::string piece = common_token_to_piece(vocab, tok, true);
            if (show_ids) {
                fprintf(stderr, "tok[%d] = %d piece=[%s]\n", n_gen, (int) tok, piece.c_str());
            }
            pending += piece;
            if (first_batch) {
                t_prefill = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
                first_batch = false;
            } else {
                t_decode += std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
            }
            if (tok == eos || tok == im_end || tok == eot || llama_vocab_is_eog(vocab, tok)) {
                break;
            }
            for (const char * mark : {"<|im_end|>", "<|endoftext|>", "<|im_start|>"}) {
                size_t p = pending.find(mark);
                if (p != std::string::npos) {
                    pending.resize(p);
                    if (!pending.empty()) {
                        fwrite(pending.data(), 1, pending.size(), stdout);
                        fflush(stdout);
                        out += pending;
                    }
                    pending.clear();
                    goto gen_done;
                }
            }
            size_t hold = 0;
            for (const char * mark : {"<|im_end|>", "<|endoftext|>", "<|im_start|>"}) {
                size_t mlen = std::strlen(mark);
                size_t upto = (pending.size() < mlen - 1) ? pending.size() : mlen - 1;
                for (size_t k = upto; k >= 1; --k) {
                    if (pending.compare(pending.size() - k, k, mark, k) == 0) {
                        if (k > hold) {
                            hold = k;
                        }
                        break;
                    }
                }
            }
            size_t flush = pending.size() - hold;
            if (flush > 0) {
                fwrite(pending.data(), 1, flush, stdout);
                fflush(stdout);
                out += pending.substr(0, flush);
                pending.erase(0, flush);
            }
            toks.assign(1, tok);
            pace(t0);
            ++n_gen;
            if (n_gen >= params.n_predict) {
                break;
            }
        }
        gen_done:;
        auto t_end = std::chrono::steady_clock::now();
        double secs = std::chrono::duration<double>(t_end - t_start).count();
        const llama_pos kv_max = llama_memory_seq_pos_max(llama_get_memory(ctx), 0);
        if (secs > 0) {
            const int n_decode = n_gen > 0 ? n_gen - 1 : 0;
            fprintf(stderr, "\n[gen] %d tok in %.2fs -> %.2f tok/s | prefill %zu tok %.3fs | decode %d tok %.3fs (%.3fs/tok) | kv_len=%d\n",
                n_gen, secs, n_gen / secs, prefill.size(), t_prefill,
                n_decode, t_decode,
                n_decode > 0 ? t_decode / n_decode : 0.0,
                (int) kv_max + 1);
        }
        if (n_gen > 1) {
            const int n_decode = n_gen - 1;
            const double cpu_spt = t_decode / n_decode;
            const double cpu_tps = 1.0 / cpu_spt;
            const double cpu_bw = cpu_tps * w_active / (1024.0 * 1024.0 * 1024.0);
            const double flop_tok = 2.0 * 3.06e9;
            const double cpu_gflops = cpu_tps * flop_tok / 1e9;
            const double peak_gflops = 300.0;
            const double u_bw = stream_bw > 0 ? cpu_bw / stream_bw : 0.0;
            const double u_flops = cpu_gflops / peak_gflops;
            long long chip_flops = 0, chip_bytes = 0, chip_ops = 0;
            int chip_cores = ggml_chip_get_threads();
            long long resident_chip = 0;
            if (chip_stats_plugin) {
                long long pf = 0, pb = 0, po = 0, psb = 0;
                int pw = 0;
                chip_stats_plugin(&pf, &pb, &po, &psb, &pw);
                chip_flops = pf - chip_flops_base_p;
                chip_cores = pw > 0 ? pw : chip_cores;
                resident_chip = psb;
            } else {
                ggml_chip_get_stats(&chip_flops, &chip_bytes, &chip_ops);
                chip_flops -= chip_flops_base;
            }
            const int64_t resident_bytes = resident_chip > 0 ? resident_chip :
                (sram_bytes > 0 ? sram_bytes : (int64_t) vmlck_kb * 1024);
            const double u_takeover = w_total > 0 ? (double) resident_bytes / (double) w_total : 0.0;
            const double total_flops = flop_tok * (n_decode + (double) prefill.size());
            const double chip_share = total_flops > 0 ? chip_flops / total_flops : 0.0;
            const double chip_gflops = t_decode > 0 ? chip_flops / (t_decode + t_prefill) / 1e9 : 0.0;
            auto bar = [](double frac) {
                static char buf[24];
                const int W = 20;
                int f = (int) (frac * W + 0.5);
                if (f < 0) f = 0;
                if (f > W) f = W;
                int p = 0;
                buf[p++] = '[';
                for (int i = 0; i < W; i++) buf[p++] = i < f ? '#' : '.';
                buf[p++] = ']';
                buf[p] = 0;
                return buf;
            };
            fprintf(stderr, "\n[board] ====== 设备工作状态 ======\n");
            fprintf(stderr, "[board] 内存供数 %s %3.0f%%  实测 %.1f / 上限 %.1f GiB/s\n",
                bar(u_bw), u_bw * 100.0, cpu_bw, stream_bw);
            fprintf(stderr, "[board] CPU算力  %s %3.0f%%  有效 %.1f GFLOPS\n",
                bar(u_flops), u_flops * 100.0, cpu_gflops);
            fprintf(stderr, "[board] 芯片算力 %s %3.0f%%  MoE卸载 %.0f%%FLOPs %.1f GFLOPS @%d核\n",
                bar(chip_share), chip_share * 100.0, chip_share * 100.0, chip_gflops, chip_cores);
            fprintf(stderr, "[board] 芯片接管 %s %3.0f%%  权重驻留 %.0f / %.0f MB\n",
                bar(u_takeover), u_takeover * 100.0, resident_bytes / 1048576.0, w_total / 1048576.0);
            if (chip_tok > 0)
                fprintf(stderr, "[board] 吞吐     %.2f tok/s (目标 %.1f, 差 %.1f 倍)\n",
                    cpu_tps, chip_tok, chip_tok / cpu_tps);
            else
                fprintf(stderr, "[board] 吞吐     %.2f tok/s\n", cpu_tps);
            if (u_takeover >= 0.99 && chip_share > 0.5) {
                fprintf(stderr, "[board] 判定: 权重片上驻留 + MoE计算芯片承担 -> 芯片接管生效\n");
            } else if (u_takeover >= 0.99) {
                fprintf(stderr, "[board] 判定: 权重已片上驻留, CPU经手权重归零 (计算仍由CPU代算)\n");
            } else if (u_bw >= 0.8) {
                fprintf(stderr, "[board] 判定: 内存接近打满 -> 物理带宽墙\n");
            } else if (u_bw < 0.5 && u_flops < 0.3) {
                fprintf(stderr, "[board] 判定: 无一打满 -> 卡在kernel效率(dequant/访存模式), 软件可优化\n");
            } else {
                fprintf(stderr, "[board] 判定: 混合瓶颈\n");
            }
        }
        llama_moe_paging_stats stats;
        if (llama_context_moe_paging_get_stats(ctx, &stats)) {
            fprintf(stderr, "moe_stats: hits=%llu misses=%llu bytes_read=%llu MB read_cnt=%llu latency=%llu ms evict=%llu wait=%llu dup=%llu\n",
                (unsigned long long) stats.cache_hits,
                (unsigned long long) stats.cache_misses,
                (unsigned long long) stats.bytes_read / (1024 * 1024),
                (unsigned long long) stats.read_count,
                (unsigned long long) stats.read_latency_us / 1000,
                (unsigned long long) stats.evictions,
                (unsigned long long) stats.waits,
                (unsigned long long) stats.duplicate_requests);
        }
        return true;
    };

    if (!params.interactive) {
        const std::string prompt = params.prompt.empty() ? "Hello." : params.prompt;
        std::vector<llama_token> toks(prompt.size() + 64);
        const int32_t ntok = llama_tokenize(
            vocab, prompt.data(), (int32_t) prompt.size(), toks.data(), (int32_t) toks.size(), true, false);
        if (ntok < 0) {
            fprintf(stderr, "research-cli: tokenize buffer too small\n");
            return 1;
        }
        toks.resize((size_t) ntok);
        std::string out;
        int n_gen = 0, n_decoded = 0;
        generate(toks, out, true, n_gen, n_decoded);
        fflush(stdout);
    } else {
        const std::string sys = params.prompt.empty()
            ? "You are Qwen, a helpful assistant created by Alibaba." : params.prompt;
        std::vector<std::string> contents;
        std::vector<llama_chat_message> chat;
        contents.push_back(sys);
        chat.push_back({"system", contents.back().c_str()});

        bool first_turn = true;
        char line[8192];
        for (;;) {
            fprintf(stderr, "\n>>> ");
            fflush(stderr);
            if (!fgets(line, sizeof line, stdin)) {
                break;
            }
            std::string in(line);
            while (!in.empty() && (in.back() == '\n' || in.back() == '\r')) {
                in.pop_back();
            }
            if (in == "exit" || in == "/exit" || in == "quit" || in == "/quit") {
                break;
            }
            if (in.empty()) {
                continue;
            }
            contents.push_back(in);
            chat.push_back({"user", contents.back().c_str()});

            std::vector<llama_token> toks;
            if (full_recompute) {
                int32_t len = llama_chat_apply_template(nullptr, chat.data(), chat.size(), true, nullptr, 0);
                if (len < 0) {
                    fprintf(stderr, "research-cli: template failed\n");
                    return 1;
                }
                std::string fmt((size_t) len, '\0');
                llama_chat_apply_template(nullptr, chat.data(), chat.size(), true, fmt.data(), len);
                toks.resize(fmt.size() + 64);
                const int32_t ntok = llama_tokenize(
                    vocab, fmt.data(), (int32_t) fmt.size(), toks.data(), (int32_t) toks.size(), true, false);
                if (ntok < 0) {
                    fprintf(stderr, "research-cli: tokenize buffer too small\n");
                    return 1;
                }
                toks.resize((size_t) ntok);
                llama_memory_clear(llama_get_memory(ctx), true);
            } else {
                std::string frag = first_turn
                    ? "<|im_start|>system\n" + sys + "<|im_end|>\n"
                    : "\n";
                frag += "<|im_start|>user\n" + in + "<|im_end|>\n<|im_start|>assistant\n";
                first_turn = false;

                toks.resize(frag.size() + 64);
                const int32_t ntok = llama_tokenize(
                    vocab, frag.data(), (int32_t) frag.size(), toks.data(), (int32_t) toks.size(), true, false);
                if (ntok < 0) {
                    fprintf(stderr, "research-cli: tokenize buffer too small\n");
                    return 1;
                }
                toks.resize((size_t) ntok);
            }

            std::string out;
            int n_gen = 0, n_decoded = 0;
            if (generate(toks, out, false, n_gen, n_decoded)) {
                contents.push_back(out);
                chat.push_back({"assistant", contents.back().c_str()});
            }
            fflush(stdout);
        }
    }

    return 0;
}