#include "arg.h"
#include "common.h"
#include "llama.h"
#include "sampling.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <thread>
#include <chrono>

int main(int argc, char ** argv) {
    double chip_tok = 13.9;
    bool full_recompute = false;
    std::vector<char *> carg;
    carg.reserve(argc);
    for (int i = 0; i < argc; ++i) {
        if (strcmp(argv[i], "--chip-tok") == 0 && i + 1 < argc) {
            chip_tok = atof(argv[++i]);
            continue;
        }
        if (strcmp(argv[i], "--full-recompute") == 0) {
            full_recompute = true;
            continue;
        }
        carg.push_back(argv[i]);
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
    fprintf(stderr, "research-cli: chip-sim %.1f tok/s  eos=%d im_end=%d eot=%d\n", chip_tok, (int) eos, (int) im_end, (int) eot);

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
            if (tok == eos || tok == im_end || tok == eot) {
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