#!/usr/bin/env python3
"""make_fixture.py — 把 kimi-k3 fork 的 mxfp4.json 转成 C 验证器用的紧凑二进制。

输入：<kimi-k3 repo>/tests/fixtures/mxfp4.json（真实 checkpoint 字节）
输出：pim/fixture_mxfp4.bin

二进制布局（全部小端）：
  header: rows i32, packed_cols i32, scale_cols i32, logical_width i32, group i32
  packed: rows*packed_cols 字节
  scales: rows*scale_cols 字节
  expected: rows*logical_width float32（参考去量化输出）

用法：
  python3 make_fixture.py [kimi-k3 repo 路径] [输出路径]
"""
import json
import struct
import sys

DEFAULT_SRC = "/data/data/com.termux/files/usr/tmp/opencode/kimi-k3-in-c-main"
DEFAULT_OUT = "/data/data/com.termux/files/home/sram/pim/fixture_mxfp4.bin"


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_SRC
    out = sys.argv[2] if len(sys.argv) > 2 else DEFAULT_OUT
    with open(f"{src}/tests/fixtures/mxfp4.json") as f:
        d = json.load(f)

    rows = d["rows"]
    pc = d["packed_cols"]
    sc = d["scale_cols"]
    width = d["logical_width"]
    group = d["group_size"]
    assert d["packed"]["shape"] == [rows, pc]
    assert d["scales"]["shape"] == [rows, sc]
    assert d["expected"]["shape"] == [rows, width]
    assert len(d["packed"]["data"]) == rows * pc
    assert len(d["scales"]["data"]) == rows * sc
    assert len(d["expected"]["data"]) == rows * width

    with open(out, "wb") as f:
        f.write(struct.pack("<iiiii", rows, pc, sc, width, group))
        f.write(bytes(d["packed"]["data"]))
        f.write(bytes(d["scales"]["data"]))
        f.write(struct.pack(f"<{rows * width}f", *d["expected"]["data"]))
    print(f"wrote {out}: rows={rows} packed={pc}x{rows} scales={sc}x{rows} "
          f"width={width} group={group} ({rows*pc + rows*sc + rows*width*4} bytes)")


if __name__ == "__main__":
    main()
