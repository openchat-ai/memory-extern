// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Required Notice: Copyright (c) 2026 SparkMoE contributors.

#include "moe-io.h"

#include <condition_variable>
#include <deque>
#include <mutex>
#include <stdexcept>
#include <thread>
#include <utility>
#include <vector>

namespace llama_moe {

struct io_executor::impl {
    explicit impl(uint32_t thread_count) {
        if (thread_count == 0) {
            thread_count = 1;
        }
        workers.reserve(thread_count);
        for (uint32_t i = 0; i < thread_count; ++i) {
            workers.emplace_back([this] { worker_loop(); });
        }
    }

    ~impl() {
        {
            std::lock_guard<std::mutex> lock(mutex);
            stopping = true;
        }
        condition.notify_all();
        for (auto & worker : workers) {
            if (worker.joinable()) {
                worker.join();
            }
        }
    }

    std::future<io_result> submit(std::function<io_result()> task) {
        auto packaged = std::make_shared<std::packaged_task<io_result()>>(std::move(task));
        auto future = packaged->get_future();
        {
            std::lock_guard<std::mutex> lock(mutex);
            if (stopping) {
                throw std::runtime_error("MoE I/O executor is stopping");
            }
            tasks.emplace_back([packaged] { (*packaged)(); });
        }
        condition.notify_one();
        return future;
    }

    void worker_loop() {
        while (true) {
            std::function<void()> task;
            {
                std::unique_lock<std::mutex> lock(mutex);
                condition.wait(lock, [this] { return stopping || !tasks.empty(); });
                if (stopping && tasks.empty()) {
                    return;
                }
                task = std::move(tasks.front());
                tasks.pop_front();
            }
            task();
        }
    }

    std::mutex mutex;
    std::condition_variable condition;
    std::deque<std::function<void()>> tasks;
    std::vector<std::thread> workers;
    bool stopping = false;
};

io_executor::io_executor(uint32_t thread_count) : pimpl(std::make_unique<impl>(thread_count)) {}
io_executor::~io_executor() = default;

std::future<io_result> io_executor::submit(std::function<io_result()> task) {
    return pimpl->submit(std::move(task));
}

}
