#!/usr/bin/env python3
"""
gguf_to_frames.py — K3 GGUF (MXFP4) 权重 → PCIe 帧协议流

功能：
  1. 解析 GGUF 容器与 MXFP4 张量（block: 32 元素 × 4bit + E8M0 scale）
  2. 重排为引擎 lane 序（128 lane 分组）
  3. 输出 CMD_RUN_WEIGHT 帧序列（可直接喂 host_stream / uio）

v0.1 说明：
  - 不依赖 gguf 库时可用 --synthetic 自造数据验证打包链路
  - 真实 GGUF 解析在装了 gguf/gguf-py 的机器上启用 --gguf path

协议对齐：
  rtl/13_mega138k/pcie_dma_engine.v
    CMD_PUSH_X     = 0x01, 激活帧 = 帧头 + 8拍×16B
    CMD_RUN_WEIGHT = 0x02, 单拍帧, byte2 起 lane 码（≤28 lanes/拍）
"""

import argparse
import struct
import os

CMD_PUSH_X     = 0x01
CMD_RUN_WEIGHT = 0x02
AXIS_BYTES     = 16
LANES          = 128


# ── E2M1 解码表（验证用）──────────────────────────────────────
E2M1 = [0.0, 0.5, 1.0, 1.5, 2.0, 3.0, 4.0, 6.0]


def e2m1_decode(code: int) -> float:
    v = E2M1[code & 7]
    return -v if code & 8 else v


def mxfp4_block_dequant(block: bytes) -> list[float]:
    """GGUF MXFP4 block: 16B 码 + 1B E8M0 scale → 32 个 fp32 值"""
    assert len(block) == 17, f"block 应 17B，得到 {len(block)}"
    codes = block[:16]
    scale_exp = struct.unpack("<B", block[16:17])[0]
    scale = 2.0 ** (scale_exp - 127)          # E8M0
    out = []
    for i in range(16):
        c_lo = codes[i] & 0xF
        c_hi = codes[i] >> 4
        out.append(e2m1_decode(c_lo) * scale)
        out.append(e2m1_decode(c_hi) * scale)
    return out


def quantize_group_bf16(vals: list[float]) -> tuple[bytes, int]:
    """简化版 bf16→MXFP4：组内取最大幅值定标，返回 (16B码+1B scale)"""
    amax = max(abs(v) for v in vals) or 1e-30
    # E8M0 定标：最小 e 使 6·2^(e-127) >= amax（不削顶）
    import math as _m
    if amax <= 0:
        e = 0                      # 全零组，任意 scale
    else:
        e = _m.ceil(_m.log2(amax / 6.0)) + 127
        e = max(0, min(254, e))
        # 数值安全网：向上微调直到真正覆盖
        while e < 254 and 6.0 * (2.0 ** (e - 127)) < amax:
            e += 1
    scale = 2.0 ** (e - 127)
    codes = bytearray(16)
    levels = (0.0, 0.5, 1.0, 1.5, 2.0, 3.0, 4.0, 6.0)   # 合法幅值（非均匀）
    for idx, v in enumerate(vals):
        target = v / scale
        best = min(levels, key=lambda L: abs(L - abs(target)))
        code3 = {0.0: 0, 0.5: 1, 1.0: 2, 1.5: 3,
                 2.0: 4, 3.0: 5, 4.0: 6, 6.0: 7}[best]
        sign = 8 if ((target < 0) or (target == 0 and str(v)[0] == '-')) else 0
        nib = sign | code3
        if idx % 2 == 0:
            codes[idx // 2] |= nib            # 低半字节
        else:
            codes[idx // 2] |= nib << 4       # 高半字节
    return bytes(codes), e


def lanes_to_frames(lane_codes: bytes, seq: int = 1) -> bytes:
    """128×4bit(64B) → 一条 CMD_RUN_WEIGHT 帧（v0.1 单拍透传 28 lanes）"""
    hdr = struct.pack("<BB", CMD_RUN_WEIGHT, seq & 0xFF)
    payload = lane_codes[:AXIS_BYTES - 2]
    return hdr + payload.ljust(AXIS_BYTES - 2, b"\x00")


def activation_frame(x_int8: list[int]) -> bytes:
    """128 lane 激活 → CMD_PUSH_X 帧（头+8拍）"""
    out = struct.pack("<BB", CMD_PUSH_X, 0) + b"\x00" * (AXIS_BYTES - 2)
    raw = bytes(b & 0xFF for b in x_int8)
    for b in range(LANES * 1 // 16):
        out += raw[b * 16:(b + 1) * 16].ljust(AXIS_BYTES, b"\x00")
    return out


def selftest() -> None:
    print("== 自测 1：E2M1 编解码往返 ==")
    ok = True
    for code in range(16):
        val = e2m1_decode(code)
        # 反查
        half = abs(val)
        table = {0.0: 0, 0.5: 1, 1.0: 2, 1.5: 3,
                 2.0: 4, 3.0: 5, 4.0: 6, 6.0: 7}
        neg = (val < 0) or (val == 0 and (code & 8))   # 负零保留符号
        back = table[half] | (8 if neg else 0)
        if back != code:
            print(f"  ✗ code={code} → {val} → {back}")
            ok = False
    print("  ✓ 16/16 往返一致" if ok else "  ✗ 存在不一致")

    print("== 自测 2：量化误差（|err|/scale，界 1.0，最大格点隙 4↔6）==")
    import random
    random.seed(42)
    worst = 0.0
    for _ in range(200):
        group = [random.uniform(-6, 6) for _ in range(32)]
        codes, e = quantize_group_bf16(group)
        block = codes + bytes([e])
        rec = mxfp4_block_dequant(block)
        scale = 2.0 ** (e - 127)
        for orig, r in zip(group, rec):
            err = abs(orig - r) / scale
            worst = max(worst, err)
    print(f"  最大 |err|/scale = {worst:.3f}（最近邻吸附理论上限 1.0）")
    assert worst <= 1.0 + 1e-9, "超过最近邻吸附界"
    print("  ✓ 通过")

    print("== 自测 3：lane→帧 打包长度 ==")
    frames = lanes_to_frames(bytes(range(64)))
    assert len(frames) == AXIS_BYTES
    assert frames[0] == CMD_RUN_WEIGHT
    print(f"  ✓ 帧大小 {len(frames)}B, cmd=0x{frames[0]:02X}")

    print("\n✓✓ ALL SELFTESTS PASSED")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--gguf", type=str, help="K3 GGUF 文件路径")
    ap.add_argument("--out", type=str, default="weights.frames",
                    help="输出帧文件")
    ap.add_argument("--tensor", type=str, default=None,
                    help="只转换指定张量名（默认全部 MXFP4 张量）")
    args = ap.parse_args()

    if args.selftest or not args.gguf:
        selftest()
        return

    try:
        import gguf  # noqa
    except ImportError:
        print("需要 pip install gguf；或先用 --selftest 验证打包逻辑")
        return

    from gguf import GGUFReader
    reader = GGUFReader(args.gguf)
    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)

    total_frames = 0
    with open(args.out, "wb") as f:
        for t in reader.tensors:
            name = t.name.decode() if isinstance(t.name, bytes) else t.name
            if args.tensor and args.tensor not in name:
                continue
            data = bytes(t.data)
            n_blocks = len(data) // 17
            f.write(struct.pack("<I", len(name.encode())))
            f.write(name.encode())
            f.write(struct.pack("<I", n_blocks))
            for bi in range(n_blocks):
                vals = mxfp4_block_dequant(
                    data[bi * 17:(bi + 1) * 17])
                # 32 值 → 重排到 lane 组（v0.1 直通）
                codes, e = quantize_group_bf16(vals)
                frame = lanes_to_frames(codes, seq=bi & 0xFF)
                f.write(frame)
                total_frames += 1
    size_mb = os.path.getsize(args.out) / 1e6
    print(f"✓ 写出 {args.out}: {total_frames} 帧, {size_mb:.1f} MB")


if __name__ == "__main__":
    main()
