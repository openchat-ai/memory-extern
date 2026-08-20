#!/usr/bin/env bash
set -e
SRC=/mnt/f/sram/sram/pim/research-cli
DST=/root/sparkmoe-fork/research-cli
BUILD=/root/sparkmoe-fork/build
if [ ! -f "$DST/main.cpp.bak" ]; then
    cp "$DST/main.cpp" "$DST/main.cpp.bak"
fi
cp "$SRC/main.cpp" "$DST/main.cpp"
cmake --build "$BUILD" --target research-cli -j8