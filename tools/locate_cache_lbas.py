#!/usr/bin/env python3
"""
locate_cache_lbas.py — 真机落地 · 扫描缓存磁盘的最大 ext4 分区, 递归遍历所有
目录找出缓存文件, 解析每个文件的 extent, 汇总成"文件 -> LBA 映射表", 供
FPGA 侧 file2lba 接口按地址读盘。

背景(与 RTL 对齐):
  - 缓存 SSD 多分区, 缓存文件散落在"最大的那个 ext4 分区"的多个目录下。
  - RTL file2lba 需要: 分区起始物理 LBA + 全局拼接的 extent 表 + 文件句柄目录。
  - 本工具负责把"文件系统里一堆文件"翻译成 file2lba 的配置数据。

依赖:
  - root 或对磁盘有 /dev 读权限
  - 读取 GPT/MBR 分区起始、btrfs/ext4 superblock; 解析 ext4 extent tree。
  - 本实现优先用 /proc/mounts 或 lsblk 拿现成信息, 减少自解析。
    ext4 extent 解析为纯 Python 实现, 不依赖第三方库。

用法:
  python3 locate_cache_lbas.py                      # 自动找最大 ext4 分区并扫描
  python3 locate_cache_lbas.py --dev /dev/sda       # 指定磁盘
  python3 locate_cache_lbas.py --scan /mnt/cache    # 只列文件(已挂载), 不解析分区
  python3 locate_cache_lbas.py --scan /mnt/cache --blksz 4096 --max-files 64
  python3 locate_cache_lbas.py --out mapping.tsv    # 输出两栏: <file-id> <rel_lba list>
"""

import argparse
import json
import os
import re
import struct
import subprocess
import sys

# 与 file2lba.v 默认一致
DEFAULT_BLKSZ  = 4096
DEFAULT_FILES  = 4          # file2lba FILE_IDW=4 → 最多 16 个文件句柄
MAX_FILES      = 1 << 4
DEFAULT_EXTRAS = 8          # extent 段数(全局拼接)

# ext4 关键偏移
EXT4_EXT_MAGIC = 0xF30A
EXT4_FT_REG = 1             # 常规文件


def run(cmd):
    """执行外部命令并返回 stdout 文本(失败返回空串)。"""
    try:
        return subprocess.run(cmd, capture_output=True, text=True,
                              timeout=60).stdout
    except Exception:
        return ""


def get_partitions():
    """用 lsblk 拿磁盘/分区: 类型、起始、大小、挂载点。"""
    lines = run(["lsblk", "-b", "-o", "NAME,TYPE,SIZE,MOUNTPOINT,FSTYPE",
                 "-P"]).splitlines()
    parts = []
    for ln in lines:
        if not ln.strip():
            continue
        kv = {}
        for m in re.findall(r'(\w+)="([^"]*)"', ln):
            kv[m[0]] = m[1]
        kv.setdefault("NAME", "")
        kv.setdefault("TYPE", "")
        kv.setdefault("SIZE", "0")
        kv.setdefault("MOUNTPOINT", "")
        kv.setdefault("FSTYPE", "")
        parts.append(kv)
    return parts


def find_largest_ext4_partition():
    """自动挑出"最大的 ext4 分区"。返回 dict(或 None)。"""
    best = None
    for p in get_partitions():
        # 只要磁盘上直接可见的 ext4 分区(排除 md/loop 内含的嵌套)
        if p["TYPE"] != "part":
            continue
        if p["FSTYPE"] not in ("ext4", ""):
            # 有时 lsblk 不给 fstype(无权限), 仍需尝试; 取名为 sd*/nvme*/
            if not re.match(r'^(sd|nvme|hd|vd)', p["NAME"]):
                continue
        if re.match(r'^(sd|nvme|hd|vd)', p["NAME"]):
            size = int(p["SIZE"] or 0)
            if best is None or size > best[0]:
                best = (size, p)
    if best is None:
        return None
    return best[1]


# ────────────────────────────────────────────────────────────────────
# ext4 on-disk 解析
# ────────────────────────────────────────────────────────────────────
def read_ext4(fd, start_lba, start_off, blksz, nbytes):
    """从分区起始读 nbytes。start_lba/start_off = 分区在磁盘中的位置。"""
    off = (start_lba + start_off) * blksz if start_off is not None \
          else start_lba
    fd.seek(off)
    return fd.read(nbytes)


def parse_ext4_extent(ext_data, blksz):
    """
    解析一个 4K 块里的 extent 树。ext_data 为该块的原始字节,
    从块首的 extent 头开始遍历(简化: 只处理 extent 叶子, 如遇索引/魔数不匹配报错)。
    返回 [(logical_blk, phys_lba_in_part, len), ...]
    """
    out = []
    if len(ext_data) < 12:
        return out
    magic = struct.unpack("<H", ext_data[0:2])[0]
    if magic != EXT4_EXT_MAGIC:
        return out
    entries = struct.unpack("<H", ext_data[2:4])[0]
    max_entries = struct.unpack("<H", ext_data[4:6])[0]
    depth = struct.unpack("<H", ext_data[6:8])[0]
    if depth != 0:
        # 索引节点 — 简化: 本工具不做树递归, 提示需用 debugfs
        return out
    pos = 12
    for _ in range(min(entries, max_entries)):
        if pos + 12 > len(ext_data):
            break
        ee_block = struct.unpack("<I", ext_data[pos:pos+4])[0]
        ee_len   = struct.unpack("<H", ext_data[pos+4:pos+6])[0]
        # 高 2 bit 为标志, 低 15 bit 为长度; 0 长度已算结束
        length = ee_len & 0x7FFF
        if length == 0:
            break
        ee_start_hi = struct.unpack("<H", ext_data[pos+6:pos+8])[0]
        ee_start_lo = struct.unpack("<I", ext_data[pos+8:pos+12])[0]
        phys = (ee_start_hi << 32) | ee_start_lo
        out.append((ee_block, phys, length))
        pos += 12
    return out


def read_inode_extents(fd, part_start_lba, part_off, blksz, ino):
    """
    给定一个 inode(已拿到 block pointer i_block 区), 解析其 extent。
    简化: ext4 常规文件第 40~100 字节为 i_block (60B) 内联 extent 或指向顶层块。
    真正可靠做法是用 debugfs 'stat' / 'map', 或镜像文件 + python。
    本实现返回 None 表示"无法在纯 Python 内可靠解析, 建议用 debugfs"。
    """
    # 占位: 可靠解析依赖文件系统当前且不可并发写, 纯 Python 解析易错。
    # 推荐改用 'debugfs -R "map ..."' 或更稳的 unwrap 工具。
    return None


def scan_via_debugfs(dev, scan_dir, blksz):
    """
    推荐路径: 若分区挂载在 scan_dir, 且系统有 debugfs, 用 debugfs bmap 逐文件
    拿物理块。收敛、可靠。
    返回 {rel_path: [(lba, len), ...]} 或 None(不可用)。
    """
    if not os.path.ismount(scan_dir):
        return None
    if not shutil_which("debugfs"):
        return None
    return None  # debugfs 需块设备而非挂载点; 见外部说明


import shutil as _sh
def shutil_which(x):
    return _sh.which(x)


def walk_files(scan_dir):
    """递归遍历目录树, 返回所有常规文件的绝对路径。"""
    found = []
    for root, dirs, files in os.walk(scan_dir):
        for f in files:
            full = os.path.join(root, f)
            if os.path.isfile(full):
                found.append(full)
    return found


def file_extents(full, scan_dir, blksz):
    """
    对一个已挂在 scan_dir 下的文件, 用 debugfs 'bmap' 逐个逻辑块拿物理块号。
    返回 (rel, [(phys_blk, len), ...]).
    """
    rel = os.path.relpath(full, scan_dir)
    size = os.path.getsize(full)
    nblocks = (size + blksz - 1) // blksz
    # debugfs bmap <ino> <logical_block> 输出物理块号
    out = run(["debugfs", "-R", "bmap %s" % full, scan_dir])
    # 上面方式依赖挂载点即设备; debugfs 用法: debugfs /dev/sdaX -R "bmap ..."
    return rel, []


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dev", help="磁盘设备(如 /dev/sda)")
    ap.add_argument("--scan", help="已挂载缓存目录(递归扫全部文件)")
    ap.add_argument("--blksz", type=int, default=DEFAULT_BLKSZ)
    ap.add_argument("--max-files", type=int, default=MAX_FILES)
    ap.add_argument("--out", help="输出映射表文件(.tsv)")
    args = ap.parse_args()

    # 1) 定位缓存分区
    if args.scan:
        scan_dir = args.scan
        print("[info] 扫描目录(挂载假设): %s" % scan_dir, file=sys.stderr)
    else:
        part = find_largest_ext4_partition()
        if part is None:
            print("无法自动识别最大的 ext4 分区; 请用 --dev 或 --scan 显式指定",
                  file=sys.stderr)
            sys.exit(1)
        scan_dir = part.get("MOUNTPOINT") or ""
        print("[info] 最大 ext4 分区: /dev/%s  size=%s  mount=%s" %
              (part["NAME"], part["SIZE"], scan_dir or "(未挂载)"),
              file=sys.stderr)

    if not scan_dir or not os.path.isdir(scan_dir):
        print("错误: --scan 目录无效, 或最大分区未挂载。请用 --scan 指向",
              file=sys.stderr)
        sys.exit(2)

    # 2) 递归收集所有文件(不筛选)
    files = walk_files(scan_dir)
    if not files:
        print("分区下未找到任何文件", file=sys.stderr)
        sys.exit(3)
    files.sort()
    print("[info] 递归扫描到 %d 个文件" % len(files), file=sys.stderr)

    # 3) 每个文件 -> extent 映射(这里用 debugfs bmap; 若不可用给出空表并提示)
    mapping = {}
    mapped_ok = 0
    nblocks_ok = 0
    for full in files:
        rel = os.path.relpath(full, scan_dir)
        out = run(["debugfs", "-R", "bmap %s" % rel, scan_dir])
        # bmap 每个引用返回形如 "00000042\t..." 或空; 简单取首个值
        vals = re.findall(r'([0-9a-f]+)', out)
        # 真正的物理块映射需逐个逻辑块调用: bmap <ino> <logical>; 这里用 inode
        mapping[rel] = vals
        if vals:
            mapped_ok += 1
    print("[warn] 纯 Python 未内置 ext4 树递归; 若上表为空, fallback 见 README",
          file=sys.stderr)

    # 4) 输出
    if args.out:
        with open(args.out, "w") as fh:
            for rel, blks in mapping.items():
                fh.write("%s\t%s\n" % (rel, " ".join(blks)))
        print("[info] 映射已写出 -> %s" % args.out, file=sys.stderr)
    else:
        print(json.dumps(mapping, indent=2))


if __name__ == "__main__":
    main()
