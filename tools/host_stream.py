#!/usr/bin/env python3
"""
host_stream.py — Tang Mega 138K 流式推理 · 主机侧控制/测速工具

功能：
  1. 枚举 FPGA PCIe 设备（Gowin DMA demo 默认 VID/DID 1d25:1001*）
  2. 通过 sysfs/uio 或自定义驱动下发权重流
  3. 统计吞吐：tokens/s、有效带宽利用率

用法：
  python3 host_stream.py --probe              # 只探测设备
  python3 host_stream.py --bench --batch 128  # 吞吐基准

* 具体 BDF/VID 以 pcie_dma_demo 的 Gowin_linux_driver_app 为准，
  本脚本 v0.1 先做探测与协议打包，读写路径留 TODO 接 uio。
"""

import argparse
import os
import struct
import time

# ── 协议常量（与 pcie_dma_engine.v 对齐）──────────────────────
CMD_PUSH_X     = 0x01
CMD_RUN_WEIGHT = 0x02

AXIS_BYTES = 16          # AXIS_WIDTH=128bit → 拍大小
X_BEATS    = 8           # 128 lane × int8 / 16B per beat


def probe() -> list[str]:
    """扫描 sysfs 找 Gowin FPGA 设备"""
    hits = []
    base = "/sys/bus/pci/devices"
    if not os.path.isdir(base):
        return hits
    for bdf in os.listdir(base):
        try:
            vendor = open(f"{base}/{bdf}/vendor").read().strip()
            device = open(f"{base}/{bdf}/device").read().strip()
            cls = open(f"{base}/{bdf}/class").read().strip()
        except OSError:
            continue
        # 处理器桥/未识别设备都报出来，人工确认
        if vendor in ("0x1d25",):          # WCH/Gowin 常见 VID
            hits.append((bdf, vendor, device, cls))
    return hits


def pack_activation_frame(lane_bytes: bytes) -> bytes:
    """激活向量 → CMD_PUSH_X 帧（帧头 + X_BEATS 载荷）"""
    assert len(lane_bytes) == 128, "需要 128 lane × int8"
    out = bytearray()
    hdr = struct.pack("<BB", CMD_PUSH_X, 0x00) + b"\x00" * (AXIS_BYTES - 2)
    out += hdr
    for b in range(X_BEATS):
        chunk = lane_bytes[b * 16:(b + 1) * 16]
        out += chunk.ljust(AXIS_BYTES, b"\x00")
    return bytes(out)


def pack_weight_frame(lane_codes: bytes) -> bytes:
    """一帧权重码 → CMD_RUN_WEIGHT 帧"""
    assert len(lane_codes) == 64, "需要 128 lane × 4bit = 64B"
    hdr = struct.pack("<BB", CMD_RUN_WEIGHT, 0x01)
    payload = lane_codes[:AXIS_BYTES - 2]      # v0.1：单拍透传
    return hdr + payload.ljust(AXIS_BYTES - 2, b"\x00")


def bench(n_frames: int, batch: int) -> None:
    """
    纯软件侧基准：
      - 生成 batch 组随机权重帧，计算理论传输时间
      - 实际 PCIe 写路径 TODO: uio mmap + write()
    """
    frame = pack_weight_frame(bytes(range(64)))
    total_bytes = len(frame) * n_frames * batch
    gen3_x4_gbps = 3.5                          # GB/s 有效
    t_ideal = total_bytes / (gen3_x4_gbps * 1e9)

    print(f"帧数       : {n_frames} × batch {batch}")
    print(f"总流量     : {total_bytes/1e6:.1f} MB")
    print(f"理想耗时   : {t_ideal*1e3:.2f} ms @ Gen3 x4")
    print(f"[TODO] 实测路径：uio 映射 BAR0 → 循环 write 权重帧")

    t0 = time.perf_counter()
    _ = [pack_weight_frame(os.urandom(64)) for _ in range(n_frames)]
    dt = time.perf_counter() - t0
    print(f"本机打包   : {dt*1e3:.2f} ms（{n_frames/dt:.0f} 帧/s 软件上限）")


def main():
    ap = argparse.ArgumentParser(description="Tang Mega 138K stream host tool")
    ap.add_argument("--probe", action="store_true")
    ap.add_argument("--bench", action="store_true")
    ap.add_argument("--frames", type=int, default=1024)
    ap.add_argument("--batch", type=int, default=32)
    args = ap.parse_args()

    if args.probe:
        found = probe()
        if not found:
            print("未发现 Gowin VID 设备。检查 lspci -nn | grep -i 1d25")
            os.system("lspci -nn 2>/dev/null | head -20 || true")
        for bdf, v, d, c in found:
            print(f"{bdf}: vendor={v} device={d} class={c}")
    elif args.bench:
        bench(args.frames, args.batch)
    else:
        ap.print_help()


if __name__ == "__main__":
    main()
