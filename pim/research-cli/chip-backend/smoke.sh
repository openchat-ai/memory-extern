#!/bin/bash
set -e
cd "$(dirname "$0")"

BIN=${BIN:-/tmp/llama-b10549}
MODEL=${MODEL:?set MODEL=/path/to/model.gguf}
PROMPT=${PROMPT:-"hello"}
NGC=${NGC:-4}

if [ ! -x "$BIN/llama-cli" ]; then
    echo "ERROR: $BIN/llama-cli missing. Re-download official b10549 release binaries."
    exit 1
fi

export LD_LIBRARY_PATH="$BIN:$LD_LIBRARY_PATH"
export GGML_BACKEND_PATH="$(pwd)/libchip-backend.so"
export CHIP_LOG_LEVEL=${CHIP_LOG_LEVEL:-2}

"$BIN/llama-cli" -m "$MODEL" -p "$PROMPT" -n "$NGC" --no-warmup 2>&1 | grep -E "chip|CHIP|load_backend|n_splits|copy" || true