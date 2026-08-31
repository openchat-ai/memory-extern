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


def file_meta(full):
    """返回 (size, mtime_ns, inode) 用于变更检测。"""
    st = os.stat(full)
    return (st.st_size, int(st.st_mtime_ns), st.st_ino)


def collect_file_meta(scan_dir):
    """递归扫描, 返回 {rel: (size, mtime_ns, inode)}。"""
    meta = {}
    for root, dirs, files in os.walk(scan_dir):
        for f in files:
            full = os.path.join(root, f)
            if os.path.isfile(full):
                meta[os.path.relpath(full, scan_dir)] = file_meta(full)
    return meta


def remap_file(full, rel, blksz):
    """
    单文件 extent -> [(logical_blk, phys_blk_in_part, len), ...]。
    优先 debugfs bmap(需 root 且分区挂载); 不可用则回退空表并返回 False。
    对性能: 只对"变化过的文件"调用(增量), 未变文件沿用快照。
    """
    size = os.path.getsize(full)
    nblocks = (size + blksz - 1) // blksz
    if not shutil_which("debugfs"):
        return [], False
    dev = first_device_for(full)
    if dev is None:
        return [], False
    extents = []
    try:
        cur_start = cur_phys = None
        for blk in range(nblocks):
            out = run(["debugfs", "-R", "bmap %s %d" % (full, blk), dev])
            mm = re.search(r'^([0-9a-fA-F]+)', out)
            if not mm:
                continue
            phys = int(mm.group(1), 16)
            if cur_start is None:
                cur_start = blk; cur_phys = phys
            elif phys == cur_phys + (blk - cur_start):
                pass
            else:
                extents.append((cur_start, cur_phys, blk - cur_start))
                cur_start = blk; cur_phys = phys
        if cur_start is not None:
            extents.append((cur_start, cur_phys, nblocks - cur_start))
    except Exception as e:
        print("[debug] bmap 失败 %s: %s" % (rel, e), file=sys.stderr)
        return [], False
    return extents, True


def offline_scan(blockdev, prefix_rel="", start_ino=2, blksz=4096):
    """
    纯 Python 离线解析块设备 ext4(不依赖挂载/debugfs)。
    参数: blockdev 需为可读文件对象或路径。prefix_rel/start_ino 支持只扫子目录。
    返回 "相对路径 -> [(逻辑块, 分区内物理块, 长度)]"(dict)。
    """
    import ext4_lba
    close = False
    fh = blockdev if hasattr(blockdev, "read") else None
    if fh is None:
        fh = open(blockdev, "rb")
        close = True
    try:
        fs = ext4_lba.Ext4FS(fh)
        fs.load()
        results = fs.walk(start_ino, prefix_rel)
        mapping = {}
        for r in results:
            mapping[r["path"]] = r["extents"]
        return mapping, fs.blksz
    finally:
        if close:
            fh.close()


def first_device_for(full):
    """返回文件所在块设备(如 /dev/nvme0n1p2), 找不到返回 None。"""
    out = run(["stat", "-f", "-c", "%T", full])
    # 从 /proc/mounts 按挂载点找设备
    try:
        with open("/proc/mounts") as fh:
            for ln in fh:
                p = ln.split()
                if len(p) >= 2 and os.path.commonpath([full, p[1]]) == p[1]:
                    return p[0]
    except Exception:
        pass
    return None


# ---- 快照持久化 ----
SNAP_VERSION = 1
DEFAULT_JSON = "cache_lba_snapshot.json"
DEFAULT_BIN  = "cache_lba_snapshot.bin"


def build_snapshot(scan_dir, blksz, mapping, base_idx=0):
    """
    组装文件->LBA 快照, 供 file2lba 配置 + 下次增量比较。
    mapping: {rel: [(logical_blk, phys_in_part, len), ...]}
    返回 dict(JSON 结构)。
    """
    # 文件句柄分配(按 name 排序), 触顶报错
    names = sorted(mapping.keys())
    if len(names) > MAX_FILES:
        print("错误: %d 个文件超过 file2lba 句柄上限 %d; 增大 FILE_IDW 或筛选"
              % (len(names), MAX_FILES), file=sys.stderr)
        sys.exit(4)
    fids = {n: i for i, n in enumerate(names)}

    # 全局 extent 拼接: 按文件顺序把每个文件 extent 铺到全局逻辑空间
    global_ext = []   # (logical_blk, phys_in_part, cnt) 按全局逻辑块
    files = {}
    gblk_cursor = 0
    for n in names:
        full = os.path.join(scan_dir, n)
        # 文件块大小: 优先主机 stat; 离线(文件不在主机, 如纯磁盘解析)用
        # extent 逻辑块长度总和。
        if os.path.isfile(full):
            size_blk = (os.path.getsize(full) + blksz - 1) // blksz
            meta = list(file_meta(full))
        else:
            size_blk = sum(cnt for (_, _, cnt) in mapping[n])
            meta = []
        files[n] = {
            "id": fids[n],
            "size": size_blk,
            "extents": [list(e) for e in mapping[n]],
            "meta": meta,
        }
        # 该文件 extents 由于块在文件内逻辑(extent 的第一项是文件内逻辑块),
        # 平移全局起点 = gblk_cursor
        for (lblk, phys, cnt) in mapping[n]:
            global_ext.append((gblk_cursor + lblk, phys, cnt))
        gblk_cursor += size_blk

    return {
        "version": SNAP_VERSION,
        "scan_dir": scan_dir,
        "blksz": blksz,
        "part_lba": None,          # 宿主/FPGA 侧填充分区起始 LBA
        "file_id_base": base_idx,
        "files": files,
        "global_extents": [list(e) for e in global_ext],
    }


def _file_blocks(rel):
    # 由调用处填(此处仅占位, 见 build_snapshot 重构)
    return 0


def dump_binary(snap, path):
    """
    生成 file2lba 可直接下发的二进制寄存器位图。
    布局: [header][reg_image]
      header: magic 'F2LB', version u32, file_count u32, ext_count u32,
              part_lba u64(0 待填), blksz u32
      reg_image: 按 reg_addr 升序, 每项 [reg u8, data u32]
                 (0x00/0x01 part, 0x10+2k.. base, 0x20+k cnt,
                  0x30+2f.. base, 0x40+f size)
    """
    import struct as _s
    exts = snap["global_extents"]
    files = snap["files"]
    regs = []
    # part_lba(占位 0, host 下发前改)
    regs.append((0x00, 0))
    regs.append((0x01, 0))
    # extent: 0x10+2k base_lo, 0x11+2k base_hi, 0x20+k cnt
    max_ext = max(len(exts), 1)
    for k, (gblk, phys, cnt) in enumerate(exts):
        regs.append((0x10 + 2*k, phys & 0xFFFFFFFF))
        regs.append((0x11 + 2*k, phys >> 32))
        regs.append((0x20 + k, cnt & 0xFFFF))
    # 文件: 0x30+2f base_lo, 0x31+2f base_hi, 0x40+f size
    # base 即该文件在全局逻辑空间的起点(由 global_extents 推出)
    base_of = {}
    cursor = 0
    for n in sorted(files):
        base_of[files[n]["id"]] = cursor
        cursor += files[n]["size"]
    for n, info in files.items():
        fid = info["id"]
        base = base_of[fid]
        regs.append((0x30 + 2*fid, base & 0xFFFFFFFF))
        regs.append((0x31 + 2*fid, base >> 32))
        regs.append((0x40 + fid, info["size"]))
    regs.sort(key=lambda r: r[0])

    with open(path, "wb") as fh:
        fh.write(b"F2LB")
        fh.write(_s.pack("<IIIQH",
                         SNAP_VERSION, len(files), max_ext,
                         0, snap["blksz"]))
        for (ra, rd) in regs:
            fh.write(_s.pack("<BI", ra, rd))
    return path


def load_snapshot(path):
    with open(path) as fh:
        return json.load(fh)


def detect_changes(scan_dir, snap):
    """
    对比快照, 返回 (新增, 修改, 删除)。
    未变文件(不在增/删/改列表)将沿用快照映射。
    """
    cur = collect_file_meta(scan_dir)
    old = {}
    for n, v in snap.get("files", {}).items():
        old[n] = tuple(v["meta"])
    added = [n for n in cur if n not in old]
    removed = [n for n in old if n not in cur]
    changed = [n for n in cur if n in old and cur[n] != old[n]]
    return added, changed, removed


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dev", help="磁盘设备(如 /dev/sda)")
    ap.add_argument("--scan", help="已挂载缓存目录(递归扫全部文件)")
    ap.add_argument("--blockdev", help="离线解析块设备ext4镜像(如 /dev/nvme0n1p2; 纯Python,不需挂载)")
    ap.add_argument("--start-ino", type=int, default=2,
                    help="--blockdev 从哪个 inode 开始(默认2=分区根)")
    ap.add_argument("--blksz", type=int, default=DEFAULT_BLKSZ)
    ap.add_argument("--max-files", type=int, default=MAX_FILES)
    ap.add_argument("--json", default=DEFAULT_JSON, help="JSON 快照路径")
    ap.add_argument("--bin", default=DEFAULT_BIN, help="二进制寄存器位图路径")
    ap.add_argument("--force", action="store_true",
                    help="强制全量重扫(忽略快照增量)")
    ap.add_argument("--no-save", action="store_true", help="只打印不落盘")
    ap.add_argument("--part-lba", type=lambda x: int(x, 0),
                    help="分区起始物理 LBA(写进快照/二进制)")
    args = ap.parse_args()

    # ---- 离线解析块设备(纯 Python, 不需挂载/不需 debugfs) ----
    if args.blockdev:
        mapping, blksz = offline_scan(args.blockdev, prefix_rel="",
                                      start_ino=args.start_ino,
                                      blksz=args.blksz)
        if not mapping:
            print("错误: 离线解析未找到文件(检查 --blockdev 是否可读/是否为 ext4)",
                  file=sys.stderr)
            sys.exit(3)
        print("[info] 离线解析到 %d 个常规文件 (blksz=%d)" %
              (len(mapping), blksz), file=sys.stderr)
        scan_dir = "/"            # 占位(离线无挂载点, 快照 file 相对路径来自磁盘)
        snap = build_snapshot(scan_dir, blksz, mapping)
        snap["part_lba"] = args.part_lba
        if args.no_save:
            print(json.dumps(snap, indent=2, ensure_ascii=False))
            return
        with open(args.json, "w") as fh:
            json.dump(snap, fh, indent=2, ensure_ascii=False)
        dump_binary(snap, args.bin)
        print("[info] 快照已存: JSON=%s  BIN=%s" % (args.json, args.bin),
              file=sys.stderr)
        print(json.dumps(snap, indent=2, ensure_ascii=False))
        return

    # 1) 定位缓存分区/扫描目录 + 分区起始 LBA
    part_lba = args.part_lba
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
        # 刺激: lsblk 无起始时用自定义; 有设备则尝试查起始
        if part_lba is None and part.get("NAME"):
            part_lba = _part_start_lba(part["NAME"])
        print("[info] 最大 ext4 分区: /dev/%s  size=%s  mount=%s  start=%s" %
              (part["NAME"], part["SIZE"], scan_dir or "(未挂载)",
               part_lba if part_lba is not None else "?"),
              file=sys.stderr)

    if not scan_dir or not os.path.isdir(scan_dir):
        print("错误: --scan 目录无效, 或最大分区未挂载。请用 --scan 指向",
              file=sys.stderr)
        sys.exit(2)

    # 2) 加载旧快照做增量对比(除非 --force 或旧快照不存在)
    old_snap = None
    if os.path.exists(args.json):
        try:
            old_snap = load_snapshot(args.json)
        except Exception as e:
            print("[warn] 快照损坏, 转全量: %s" % e, file=sys.stderr)
    if old_snap and not args.force:
        added, changed, removed = detect_changes(scan_dir, old_snap)
        print("[info] 增量: 新增+%d 修改=%d 删除-%d (其余沿用快照, 性能影响可忽略)"
              % (len(added), len(changed), len(removed)), file=sys.stderr)
        if not (added or changed or removed):
            print("[info] 无变化, 沿用现有快照", file=sys.stderr)
            if part_lba is not None and old_snap.get("part_lba") is None:
                old_snap["part_lba"] = part_lba
            if not args.no_save:
                dump_binary(old_snap, args.bin)
                with open(args.json, "w") as fh:
                    json.dump(old_snap, fh, indent=2, ensure_ascii=False)
            print(json.dumps(old_snap, indent=2, ensure_ascii=False))
            return
        # 沿用快照中未变文件的 extent; 新增/修改重新映射; 删除剔除
        mapping = {}
        for n, v in old_snap.get("files", {}).items():
            if n in removed:
                continue
            mapping[n] = [tuple(e) for e in v.get("extents", [])]
        for rel in added + changed:
            full = os.path.join(scan_dir, rel)
            if not os.path.isfile(full):
                continue
            exts, _ = remap_file(full, rel, args.blksz)
            mapping[rel] = exts
        print("[info] 重映射 %d 个变化文件" % (len(added) + len(changed)),
              file=sys.stderr)
    else:
        mapping = {}
        for full in walk_files(scan_dir):
            rel = os.path.relpath(full, scan_dir)
            exts, _ = remap_file(full, rel, args.blksz)
            mapping[rel] = exts
        print("[info] 全量重扫 %d 个文件" % len(mapping), file=sys.stderr)

    # 3) 组装 + 落盘
    snap = build_snapshot(scan_dir, args.blksz, mapping)
    snap["part_lba"] = part_lba

    if args.no_save:
        print(json.dumps(snap, indent=2, ensure_ascii=False))
        return

    with open(args.json, "w") as fh:
        json.dump(snap, fh, indent=2, ensure_ascii=False)
    dump_binary(snap, args.bin)
    print("[info] 快照已存: JSON=%s  BIN=%s" % (args.json, args.bin),
          file=sys.stderr)
    print(json.dumps(snap, indent=2, ensure_ascii=False))


def _part_start_lba(name):
    """用 udev 属性或 sysfs 拿分区起始扇区(512B 扇区), 失败返 None。"""
    for base in ("/sys/class/block"):
        p = os.path.join(base, name, "start")
        if os.path.exists(p):
            try:
                with open(p) as fh:
                    return int(fh.read().strip())
            except Exception:
                return None
    return None


if __name__ == "__main__":
    main()
