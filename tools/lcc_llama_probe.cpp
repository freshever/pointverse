// Read-only diagnostic runner using the exact bundled macOS llama framework.
// stdin: byte length newline, then raw UTF-8 ChatML prompt. stdout: TSV + hex.
#include "llama.h"
#include <algorithm>
#include <chrono>
#include <iostream>
#include <iomanip>
#include <sstream>
#include <string>
#include <vector>
#include <thread>

int main(int argc, char **argv) {
    if (argc != 2 && argc != 3) return 2;
    const int maximum_tokens = argc == 3 ? std::stoi(argv[2]) : 360;
    if (maximum_tokens <= 0 || maximum_tokens > 512) return 2;
    llama_backend_init();
    auto mp = llama_model_default_params();
    auto *model = llama_model_load_from_file(argv[1], mp);
    if (!model) return 3;
    auto cp = llama_context_default_params();
    cp.n_ctx = 4096; cp.n_batch = 128; cp.n_ubatch = 128;
    cp.n_threads = cp.n_threads_batch = std::max(1, std::min(8, int(std::thread::hardware_concurrency()) - 2));
    auto *ctx = llama_init_from_model(model, cp);
    if (!ctx) return 4;
    auto *vocab = llama_model_get_vocab(model);
    auto batch = llama_batch_init(128, 0, 1);
    std::string line;
    while (std::getline(std::cin, line)) {
        int bytes = std::stoi(line);
        if (bytes <= 0 || bytes > 100000) return 5;
        std::string prompt(bytes, '\0'); std::cin.read(prompt.data(), bytes);
        const auto started = std::chrono::steady_clock::now();
        std::vector<llama_token> tokens(bytes + 16);
        int n = llama_tokenize(vocab, prompt.data(), bytes, tokens.data(), tokens.size(), true, true);
        if (n <= 0 || n + maximum_tokens >= int(llama_n_ctx(ctx))) {
            std::cout << "ERROR\tbudget\t" << n << std::endl; continue;
        }
        llama_memory_clear(llama_get_memory(ctx), true);
        auto add = [&](llama_token token, int pos, bool logits) {
            int i = batch.n_tokens++;
            batch.token[i] = token; batch.pos[i] = pos;
            batch.n_seq_id[i] = 1; batch.seq_id[i][0] = 0; batch.logits[i] = logits;
        };
        bool ok = true;
        for (int start = 0; start < n; start += 128) {
            batch.n_tokens = 0;
            for (int i = start; i < std::min(n, start + 128); ++i) add(tokens[i], i, i == n - 1);
            if (llama_decode(ctx, batch) != 0) { ok = false; break; }
        }
        auto *sampler = llama_sampler_chain_init(llama_sampler_chain_default_params());
        llama_sampler_chain_add(sampler, llama_sampler_init_temp(0.6f));
        // Fixed seed for reproducible comparisons; app uses a random seed.
        llama_sampler_chain_add(sampler, llama_sampler_init_dist(42));
        std::string output; int produced = 0;
        for (; ok && produced < maximum_tokens; ++produced) {
            auto token = llama_sampler_sample(sampler, ctx, -1);
            if (llama_vocab_is_eog(vocab, token)) break;
            std::vector<char> piece(256);
            int count = llama_token_to_piece(vocab, token, piece.data(), piece.size(), 0, false);
            if (count < 0) { piece.resize(-count); count = llama_token_to_piece(vocab, token, piece.data(), piece.size(), 0, false); }
            if (count > 0) output.append(piece.data(), count);
            batch.n_tokens = 0; add(token, n + produced, true);
            if (llama_decode(ctx, batch) != 0) ok = false;
        }
        llama_sampler_free(sampler);
        auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - started).count();
        std::ostringstream hex;
        for (unsigned char ch : output) hex << std::hex << std::setw(2) << std::setfill('0') << int(ch);
        std::cout << (ok ? "OK" : "ERROR") << '\t' << n << '\t' << produced << '\t' << ms << '\t' << hex.str() << std::endl;
    }
    llama_batch_free(batch); llama_free(ctx); llama_model_free(model); llama_backend_free();
}
