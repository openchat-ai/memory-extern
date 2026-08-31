#!/usr/bin/env python3
"""
ext4_lba.py — 纯 Python ext4 解析器(无第三方依赖, 不依赖 debugfs/挂载)

用途: 从**块设备/镜像文件**直读 ext4, 递归解析目录树 + 每个常规文件的
      extent 树, 输出"文件相对路径 -> [(文件内逻辑块, 分区内物理块, 长度)]"。
      供 locate_cache_lbas.py 离线生成 LBA 快照, 与 file2lba 的全局拼接对齐。

仅实现读所需最小子集:
  - superblock: 块大小/每块组 inode 数/每组块数/每组 inode 表起始/inode 大小
  - 块组描述符表 → inode 表位置
  - inode: i_block(60B) 的 extent 根 + 完整 extent 树递归(深度任意)
  - 目录项: dir_entry2(2.0+) 递归遍历
  - 常规文件(FT_REG) vs 目录(FT_DIR) 区分

布局宏(ext4 struct)见代码注释。单位说明:
  - 所有"块号"均为"分区内从块0 起的块号"(不含磁盘起始偏移; 磁盘起始由调用方
    用 part_lba 叠加)。
  - 512 字节扇区早已废弃; 本实现按 superblock 的块大小(通常 4096)解释。

用法:
  fs = Ext4FS(open("/dev/nvme0n1p2","rb"))
  fs.load()
  entries = fs.walk("/")        # [{path, ino, size, extents:[(lblk,phys,len)]}]
"""

import struct

EXT4_EXT_MAGIC = 0xF30A

# 文件类型(用于 dir_entry2 过滤常规文件)
FT_UNKNOWN, FT_REG, FT_DIR, FT_CHRDEV, FT_BLKDEV, FT_FIFO, FT_SOCK, FT_SYMLINK = \
    range(0, 8)


def _le(data, off, fmt):
    """按小端读结构; fmt 单字符, 返回数值。"""
    n = struct.calcsize(fmt)
    return struct.unpack_from("<" + fmt, data, off)[0]


class Ext4FS:
    def __init__(self, fh, offset_bytes=0):
        """
        fh: 文件对象(块设备或镜像)。
        offset_bytes: 本分区在其中的字节偏移(非 4096 对齐时)。默认 0=自块0。
        """
        self.fh = fh
        self.offset = offset_bytes
        self.blksz = None
        self.inode_size = 256
        self.inodes_per_grp = None
        self.blocks_per_grp = None
        self.desc_blksz = None
        self.gd_start_blk = None      # 块组描述符第一块的块号
        self.inode_table_blk = None   # 组0 inode 表起始块号(以块为单位)
        self.groups = []

    # ---- 低层读 ----
    def _read_blk(self, blk):
        """读一个(块号从0起)完整块。"""
        pos = self.offset + blk * self.blksz
        self.fh.seek(pos)
        return self.fh.read(self.blksz)

    def _read_bytes(self, bpos, n):
        pos = self.offset + bpos
        self.fh.seek(pos)
        return self.fh.read(n)

    # ---- superblock ----
    def load(self):
        """读 superblock + 块组描述符, 建立 inode 表寻址。"""
        # superblock 位于块0 偏移1024(若块大小>1024)。取块0 前 2048 字节保守够
        sb = self._read_bytes(1024, 2048)
        if len(sb) < 1028:
            raise ValueError("读 superblock 失败")
        self.blocks_per_grp = _le(sb, 0x28, "I")   # s_blocks_per_group
        self.inodes_per_grp = _le(sb, 0x2C, "I")   # s_inodes_per_group
        # s_log_block_size = 块大小的 log2(以 1024 为底)
        log_bs = _le(sb, 0x18, "I")
        self.blksz = 1024 << log_bs
        # s_inode_size(若该字段=0 则取 128)
        self.inode_size = _le(sb, 0x58, "H") or 128
        first_data_blk = _le(sb, 0x14, "I")
        # s_desc_size(当 s_feature_incompat 含 64bit 时为 64, 否则 32)
        desc_size = _le(sb, 0xFE, "H") or 32
        # 块组描述符起始: 由于 superblock 备份, 从 first_data_blk 之后,
        # 组0 的 desc 自 first_data_blk+1? 实际: 块1 + res_gdt 偏移, 简化按标准
        # 布局: 块0 = 引导/superblock(块大小>1K), 组0 desc 自块1 起。
        self.gd_start_blk = first_data_blk + 1
        # 组0 inode 表起始: 属于块组描述符表之后, 用 blocks_per_grp 的位图布局。
        # 为稳健, 从组0 desc 读 bg_inode_table_lo。
        inodes_total = self.inodes_per_grp
        # 读组0 块组描述符(它给出 inode 表起始块号)
        gd_blk = self.gd_start_blk
        gd = self._read_blk(gd_blk)
        if len(gd) < desc_size:
            raise ValueError("读块组描述符失败 desc_size=%d" % desc_size)
        inode_table_lo = _le(gd, 0x08, "I")
        inode_table_hi = _le(gd, 0x20, "I") if desc_size >= 64 else 0
        self.inode_table_blk = (
            (inode_table_hi << 32) | inode_table_lo) if self.blksz < 0x1000000 \
            else (inode_table_lo | (inode_table_hi << 32))
        self.desc_size = desc_size
        return self

    # ---- inode 地址 ----
    def inode_blk_off(self, ino):
        """给定 inode 号(1-based), 返回其在 inode 表中的 [块内偏移, 全局块号]。"""
        # inode 号 -> 组内下标
        idx = ino - 1
        grp = idx // self.inodes_per_grp
        off_in_grp = idx % self.inodes_per_grp
        # inode 表中每 blksz/inode_size 个 inode 一块
        per_block = self.blksz // self.inode_size
        inode_table_start = self._group_inode_table(grp)
        blk = inode_table_start + off_in_grp // per_block
        off_in_blk = (off_in_grp % per_block) * self.inode_size
        return blk, off_in_blk

    def _group_inode_table(self, grp):
        """读取 grp 块组的 inode 表起始块号(读该组 desc)。"""
        # 组描述符连续存放: 每组一个 desc_size 字节, 自 gd_start_blk。
        per_blk = self.blksz // self.desc_size
        desc_blk = self.gd_start_blk + grp // per_blk
        off = (grp % per_blk) * self.desc_size
        gd = self._read_blk(desc_blk)
        if len(gd) < off + self.desc_size:
            raise ValueError("组 %d desc 越界" % grp)
        lo = _le(gd, off + 0x08, "I")
        hi = _le(gd, off + 0x20, "I") if self.desc_size >= 64 else 0
        return (hi << 32) | lo

    def read_inode(self, ino):
        """读一个 inode: i_block 区 + 文件大小 + 类型旗帜。"""
        blk, off = self.inode_blk_off(ino)
        blkdata = self._read_blk(blk)
        base = off
        i_mode = _le(blkdata, base + 0x00, "H")
        i_size = (
            _le(blkdata, base + 0x04, "I")
            | (_le(blkdata, base + 0x6C, "I") << 32)
        )
        i_block = blkdata[base + 0x28: base + 0x28 + 60]
        # POSIX S_IFMT: 0x8000=reg, 0x4000=dir, 0xA000=symlink
        fmt = i_mode & 0xF000
        return {"ino": ino, "mode": i_mode, "size": i_size,
                "i_block": i_block, "fmt": fmt,
                "is_dir": fmt == 0x4000, "is_reg": fmt == 0x8000}

    # ---- extent 树 ----
    def read_extent_block(self, phys_blk):
        """读一个 extent 块(可能同时是叶/索引), 返回原始字节。"""
        return self._read_blk(phys_blk)

    def parse_extent_block(self, data):
        """
        解析一个 extent 块(4K)。返回 (is_index, entries)。
          is_index=True:  entries=[(logical_blk, child_phys_blk)]
          is_index=False: entries=[(logical_blk, phys_blk, len)]
        """
        if len(data) < 12:
            return False, []
        magic = _le(data, 0, "H")
        if magic != EXT4_EXT_MAGIC:
            return False, []
        entries = _le(data, 2, "H")
        depth = _le(data, 6, "H")
        # 校验 entries 不越界
        pos = 12
        if depth == 0:
            out = []
            for _ in range(entries):
                if pos + 12 > len(data):
                    break
                ee_block = _le(data, pos, "I")
                ee_len = _le(data, pos + 4, "H")
                length = ee_len & 0x7FFF
                if length == 0:
                    break
                hi = _le(data, pos + 6, "H")
                lo = _le(data, pos + 8, "I")
                out.append((ee_block, (hi << 32) | lo, length))
                pos += 12
            return False, out
        else:
            out = []
            for _ in range(entries):
                if pos + 12 > len(data):
                    break
                ei_block = _le(data, pos, "I")
                ei_leaf = _le(data, pos + 4, "I")
                out.append((ei_block, ei_leaf))
                pos += 12
            return True, out

    def inode_extents(self, i_block):
        """
        解析 inode 中 60 字节 i_block 区: 前 12 字节为 extent 头, 之后内联
        leaf/index 项; 若是索引根, 递归下钻其抹树 child。
        返回 [(logical_blk, phys_blk_in_part, len), ...](升序, 无洞)。
        """
        if len(i_block) < 12:
            return []
        magic = _le(i_block, 0, "H")
        if magic != EXT4_EXT_MAGIC:
            return []      # 非 extent(块映射); 极罕见, 放弃
        entries = _le(i_block, 2, "H")
        depth = _le(i_block, 6, "H")
        out = []
        pos = 12
        if depth == 0:
            # 内联 leaf
            for _ in range(entries):
                if pos + 12 > len(i_block):
                    break
                ee_block = _le(i_block, pos, "I")
                ee_len = _le(i_block, pos + 4, "H")
                length = ee_len & 0x7FFF
                if length == 0:
                    break
                hi = _le(i_block, pos + 6, "H")
                lo = _le(i_block, pos + 8, "I")
                out.append((ee_block, (hi << 32) | lo, length))
                pos += 12
            out.sort()
            return out
        else:
            # 内联索引根 → 递归各 child
            for _ in range(entries):
                if pos + 12 > len(i_block):
                    break
                ei_block = _le(i_block, pos, "I")
                ei_leaf = _le(i_block, pos + 4, "I")
                self._collect_index_recursive(ei_leaf, out)
                pos += 12
            out.sort()
            return out

    def _collect_index_recursive(self, phys_blk, out):
        """把物理索引块 phys_blk 的子叶/孙索引全部收进 out。"""
        data = self.read_extent_block(phys_blk)
        is_idx, entries = self.parse_extent_block(data)
        if is_idx:
            for (_, child) in entries:
                self._collect_index_recursive(child, out)
        else:
            for e in entries:
                out.append(e)

    # ---- 目录遍历 ----
    def dir_entries(self, ino):
        """读目录 inode 的所有目录项(可能跨多个 extent)。返回 [(ino, name, ftype)]。"""
        inode = self.read_inode(ino)
        if not inode["is_dir"]:
            return []
        exts = self.inode_extents(inode["i_block"])
        entries = []
        for (_, phys, cnt) in sorted(exts):
            for b in range(cnt):
                data = self._read_blk(phys + b)
                entries.extend(self._parse_dir_block(data))
        return entries

    def _parse_dir_block(self, data):
        out = []
        pos = 0
        n = len(data)
        while pos + 8 <= n:
            ino = _le(data, pos, "I")
            rec_len = _le(data, pos + 4, "H")
            if rec_len < 8 or pos + rec_len > n:
                break
            name_len = _le(data, pos + 6, "B")
            ftype = _le(data, pos + 7, "B")
            if ino == 0:
                break
            name = data[pos + 8: pos + 8 + name_len].decode("utf-8", "replace")
            out.append((ino, name, ftype))
            pos += rec_len
        return out

    # ---- 顶层: 从某 inode 递归整树 ----
    def walk(self, start_ino, prefix=""):
        """
        从 start_ino(目录)开始深度优先, 返回
          [{path, ino, size, extents:[(lblk,phys,len)]}]
        仅含常规文件。
        """
        results = []
        stack = [(start_ino, prefix)]
        seen = set()
        while stack:
            ino, path = stack.pop()
            if ino in seen or ino < 1:
                continue
            seen.add(ino)
            inode = self.read_inode(ino)
            if inode["is_dir"]:
                try:
                    for (child_ino, name, ft) in self.dir_entries(ino):
                        if name in ("", ".", ".."):
                            continue
                        cp = (path + "/" + name) if path else name
                        stack.append((child_ino, cp))
                except Exception:
                    continue
            elif inode["is_reg"]:
                exts = self.inode_extents(inode["i_block"])
                results.append({
                    "path": path, "ino": ino, "size": inode["size"],
                    "extents": exts,
                })
        return results
