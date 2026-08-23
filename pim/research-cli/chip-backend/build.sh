#!/bin/bash
set -e
cd "$(dirname "$0")"

SRC=/tmp/llama-src
if [ ! -f "$SRC/ggml/src/ggml-backend-impl.h" ]; then
    echo "ERROR: $SRC missing. Re-download b10549 source first."
    exit 1
fi

mkdir -p /tmp/chipbuild
gcc -shared -fPIC -O2 -mavx2 -mfma -std=c11 \
    -fvisibility=hidden -D_GNU_SOURCE \
    -I"$SRC/ggml/include" -I"$SRC/ggml/src" \
    chip_backend.c chip_core.c \
    -o /tmp/chipbuild/libchip-backend.so \
    -lpthread -ldl -lm

echo "OK: $(ls -la /tmp/chipbuild/libchip-backend.so)"
nm -D --defined-only /tmp/chipbuild/libchip-backend.so | grep -v " _" || true