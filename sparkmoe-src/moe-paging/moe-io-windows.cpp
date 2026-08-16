// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Required Notice: Copyright (c) 2026 SparkMoE contributors.

#include "moe-io.h"

#if defined(_WIN32)

#define WIN32_LEAN_AND_MEAN
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <io.h>

#include <algorithm>
#include <chrono>
#include <stdexcept>
#include <string>

namespace llama_moe {

static std::string windows_error(DWORD code) {
    char * buffer = nullptr;
    const DWORD count = FormatMessageA(
        FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
        nullptr, code, 0, reinterpret_cast<char *>(&buffer), 0, nullptr);
    std::string message = count > 0 ? std::string(buffer, count) : "Windows error " + std::to_string(code);
    if (buffer) {
        LocalFree(buffer);
    }
    return message;
}

class windows_file_reader final : public file_reader {
public:
    windows_file_reader(int native_fd, uint64_t file_size) : file_size(file_size) {
        const HANDLE source = reinterpret_cast<HANDLE>(_get_osfhandle(native_fd));
        if (source == INVALID_HANDLE_VALUE) {
            throw std::runtime_error("invalid GGUF file handle");
        }
        handle = ReOpenFile(
            source,
            GENERIC_READ,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            FILE_FLAG_OVERLAPPED | FILE_FLAG_RANDOM_ACCESS);
        if (handle == INVALID_HANDLE_VALUE) {
            throw std::runtime_error("ReOpenFile failed: " + windows_error(GetLastError()));
        }
    }

    ~windows_file_reader() override {
        if (handle != INVALID_HANDLE_VALUE) {
            CloseHandle(handle);
        }
    }

    io_result read_exact(uint64_t offset, void * destination, size_t length, uint32_t timeout_ms) override {
        io_result result;
        if (offset > file_size || length > file_size - offset) {
            result.error = "read range is outside the GGUF shard";
            return result;
        }

        const auto started = std::chrono::steady_clock::now();
        auto * output = static_cast<uint8_t *>(destination);
        size_t completed = 0;
        while (completed < length) {
            const DWORD chunk = static_cast<DWORD>(std::min<size_t>(length - completed, 64u * 1024u * 1024u));
            OVERLAPPED overlapped{};
            const uint64_t position = offset + completed;
            overlapped.Offset = static_cast<DWORD>(position);
            overlapped.OffsetHigh = static_cast<DWORD>(position >> 32);
            overlapped.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
            if (!overlapped.hEvent) {
                result.error = "CreateEventW failed: " + windows_error(GetLastError());
                return result;
            }

            DWORD transferred = 0;
            BOOL read_ok = ReadFile(handle, output + completed, chunk, nullptr, &overlapped);
            if (!read_ok && GetLastError() == ERROR_IO_PENDING) {
                const DWORD wait_ms = timeout_ms == 0 ? INFINITE : timeout_ms;
                const DWORD wait_result = WaitForSingleObject(overlapped.hEvent, wait_ms);
                if (wait_result != WAIT_OBJECT_0) {
                    CancelIoEx(handle, &overlapped);
                    WaitForSingleObject(overlapped.hEvent, INFINITE);
                    CloseHandle(overlapped.hEvent);
                    result.error = wait_result == WAIT_TIMEOUT ? "expert read timed out" : "expert read wait failed";
                    return result;
                }
                read_ok = GetOverlappedResult(handle, &overlapped, &transferred, FALSE);
            } else if (read_ok) {
                read_ok = GetOverlappedResult(handle, &overlapped, &transferred, TRUE);
            }

            const DWORD error = read_ok ? ERROR_SUCCESS : GetLastError();
            CloseHandle(overlapped.hEvent);
            if (!read_ok) {
                result.error = "ReadFile failed: " + windows_error(error);
                return result;
            }
            if (transferred == 0 || transferred > chunk) {
                result.error = "unexpected EOF while reading an expert tensor";
                return result;
            }
            completed += transferred;
        }

        result.ok = true;
        result.bytes = completed;
        result.latency_us = static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(
            std::chrono::steady_clock::now() - started).count());
        return result;
    }

    uint64_t size() const override { return file_size; }

private:
    HANDLE handle = INVALID_HANDLE_VALUE;
    uint64_t file_size = 0;
};

std::shared_ptr<file_reader> make_file_reader(int native_fd, uint64_t file_size) {
    return std::make_shared<windows_file_reader>(native_fd, file_size);
}

}

#endif
