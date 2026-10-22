#!/usr/bin/env python3
# board_uart_cli.py — 板载 UART 通道的 PC 侧工具 (读行 + 发命令)
#
# 用法:
#   python3 tools/board_uart_cli.py                # 自动扫 COM3/COM4, 打印板子吐的行
#   python3 tools/board_uart_cli.py --port COM4    # 指定串口
#   python3 tools/board_uart_cli.py --send 0x12    # 发一个命令字节 (低4位=xext, bit4=手动触发一帧)
#   python3 tools/board_uart_cli.py --send 0x12 --watch 20
#
# 行格式: F=<帧号> W=<词量> H=<帧哈希> A=<attn内积> L=<引擎层数> R=<rail帧> C=<末次命令>
# 注意: 板子这版是 SRAM 装载, 断电即失; 波特率若总差 4 倍或乱码, 是调试器固件的事
#       (见 notes/PC-BURN-M25.md), 可试 --baud 460800。
import argparse
import sys
import time

try:
    import serial
except ImportError:
    print("需要 pyserial: pip install pyserial", file=sys.stderr)
    sys.exit(2)


def open_port(port, baud, timeout=0.2):
    s = serial.Serial(port, baud, timeout=timeout, xonxoff=False, rtscts=False)
    return s


def try_ports(baud):
    import serial.tools.list_ports
    cands = [p.device for p in serial.tools.list_ports.comports()]
    print(f"可用串口: {cands}", file=sys.stderr)
    for c in cands:
        try:
            s = open_port(c, baud)
            print(f"打开 {c} @ {baud} 成功", file=sys.stderr)
            return s
        except Exception as e:
            print(f"  {c} 打开失败: {e}", file=sys.stderr)
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default=None)
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--send", default=None, help="要发的命令字节 (十六进制, 如 0x12)")
    ap.add_argument("--watch", type=float, default=0.0, help="发完后再看 N 秒")
    ap.add_argument("--raw", action="store_true", help="按字节打印 (不按行)")
    args = ap.parse_args()

    if args.port:
        s = open_port(args.port, args.baud)
    else:
        s = try_ports(args.baud)
        if s is None:
            print("没找到能打开的串口", file=sys.stderr)
            sys.exit(1)

    if args.send is not None:
        b = int(args.send, 0) & 0xFF
        s.write(bytes([b]))
        s.flush()
        print(f"--> 已发命令字节 0x{b:02x} (低4位=xext, bit4=手动触发一帧)", file=sys.stderr)

    t_end = time.time() + (args.watch if args.watch else 3600)
    buf = bytearray()
    while time.time() < t_end:
        chunk = s.read(256)
        if not chunk:
            continue
        if args.raw:
            print(" ".join(f"{b:02x}" for b in chunk))
            continue
        buf += chunk
        while b"\n" in buf:
            line, _, rest = buf.partition(b"\n")
            buf = bytearray(rest)
            try:
                print(line.decode("ascii", "replace").rstrip())
            except Exception:
                print(repr(line))
    s.close()


if __name__ == "__main__":
    main()
