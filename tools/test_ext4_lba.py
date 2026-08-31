#!/usr/bin/env python3
"""
test_ext4_lba.py — 用合成 ext4 镜像验证纯 Python 解析器
(无第三方依赖; 验证 superblock/inode/extent 树深递/目录遍历/物理块输出)

构造一个最小 ext4 布局(块大小 4096):
  /a.bin  : 文件内联单片 extent(逻辑0..3 -> 物理 P_a 连续4块)         深度0
  /d1/b.w : 跨两片 extent(逻辑0..1->P_b0, 2..4->P_b1)                深度0
  /deep.bin: 内联索引根(深度1) -> 索引块 -> 叶块(逻辑0..7->P_leaf)    深度1递归
运行后断言物理块映射正确。
"""

import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ext4_lba import Ext4FS

BLKSZ = 4096
INODE_SIZE = 256
INODES_PER_GRP = 64
BLOCKS_PER_GRP = 128
EXT4_MAGIC = 0xF30A

FT_REG, FT_DIR = 1, 2

# 分区内物理块布局
SB_BLK = 0
GD_BLK = 1
BLK_BITMAP = 2
INO_BITMAP = 3
INODE_TABLE = 4
INODE_TABLE_END = INODE_TABLE + (INODES_PER_GRP * INODE_SIZE // BLKSZ)  # =8
DATA_START = INODE_TABLE_END


def put(b, off, fmt, val):
    struct.pack_into("<" + fmt, b, off, val)


def extent_header(depth, n):
    h = bytearray(12)
    put(h, 0, "H", EXT4_MAGIC)
    put(h, 2, "H", n)
    put(h, 4, "H", n)
    put(h, 6, "H", depth)
    return bytes(h)


def i_block_inline_leaf(entries):
    """内联 leaf: 头 + entries((lblk,phys,len)), 60字节。
    extent 项 = ee_block(I) + ee_len(H) + ee_start_hi(H) + ee_start_lo(I) = 12B"""
    b = bytearray(extent_header(0, len(entries)))
    for (blk, phys, ln) in entries:
        b += struct.pack("<IHHI", blk, ln, 0, phys)
    return bytes(b[:60].ljust(60, b'\x00'))


def i_block_inline_index(entries):
    """内联索引根: entries((lblk,child_phys))。索引项=ei_block(I)+ei_leaf_lo(I)+ei_leaf_hi(H)+ei_unused(H)=12B"""
    b = bytearray(extent_header(1, len(entries)))
    for (blk, child) in entries:
        b += struct.pack("<IIHH", blk, child, 0, 0)
    return bytes(b[:60].ljust(60, b'\x00'))


def index_block_leaf(entries):
    """一个完整 leaf 块: entries((lblk,phys,len))。"""
    b = bytearray(BLKSZ)
    put(b, 0, "H", EXT4_MAGIC)
    put(b, 2, "H", len(entries))
    put(b, 4, "H", len(entries))
    put(b, 6, "H", 0)
    pos = 12
    for (blk, phys, ln) in entries:
        put(b, pos, "I", blk)
        put(b, pos + 4, "H", ln)
        put(b, pos + 6, "H", 0)
        put(b, pos + 8, "I", phys)
        pos += 12
    return bytes(b)


def dir_block(entries):
    b = bytearray(BLKSZ)
    pos = 0
    for (ino, name, ft) in entries:
        namelen = len(name.encode())
        reclen = ((8 + namelen) + 3) & ~3
        put(b, pos, "I", ino)
        put(b, pos + 4, "H", reclen)
        put(b, pos + 6, "B", namelen)
        put(b, pos + 7, "B", ft)
        b[pos + 8: pos + 8 + namelen] = name.encode()
        pos += reclen
    return bytes(b)


def write_inode(blocks, ino, mode, size, iblock60):
    per_block = BLKSZ // INODE_SIZE
    blk = INODE_TABLE + (ino - 1) // per_block
    off = ((ino - 1) % per_block) * INODE_SIZE
    ib = blocks[blk]
    put(ib, off + 0x00, "H", mode)
    put(ib, off + 0x04, "I", size & 0xFFFFFFFF)
    put(ib, off + 0x6C, "I", size >> 32)
    ib[off + 0x28: off + 0x28 + 60] = iblock60[:60]


def build_image():
    nblk = 64
    blocks = [bytearray(BLKSZ) for _ in range(nblk)]

    # superblock(置于块0 偏移1024, 符合真实 ext4 布局; 覆盖到 s_desc_size)
    sb = bytearray(512)
    put(sb, 0x38, "I", 0xEF53)                 # s_magic
    put(sb, 0x18, "I", 2)                      # log_block_size=2 -> 4096
    put(sb, 0x28, "I", BLOCKS_PER_GRP)         # s_blocks_per_group
    put(sb, 0x2C, "I", INODES_PER_GRP)         # s_inodes_per_group
    put(sb, 0x34, "I", nblk)                   # s_blocks_count_lo
    put(sb, 0x58, "H", INODE_SIZE)             # s_inode_size
    put(sb, 0x14, "I", 0)                      # s_first_data_block
    put(sb, 0xFE, "H", 32)                     # s_desc_size
    blocks[0][1024:1024 + len(sb)] = sb

    # 组0 desc
    gd = blocks[GD_BLK]
    put(gd, 0x00, "I", BLK_BITMAP)
    put(gd, 0x04, "I", INO_BITMAP)
    put(gd, 0x08, "I", INODE_TABLE)

    ino_root, ino_a, ino_d1, ino_b, ino_deep = 2, 12, 13, 14, 15

    next_data = DATA_START

    def alloc(cnt=1):
        nonlocal next_data
        b = next_data
        next_data += cnt
        return b

    # 数据块
    P_root = alloc()
    P_d1 = alloc()
    P_a = alloc(4)
    P_b0 = alloc(2)
    P_b1 = alloc(3)
    P_leaf = alloc(8)
    P_idxblk = alloc(1)

    blocks[P_root][:] = dir_block([
        (ino_root, ".", FT_DIR), (ino_root, "..", FT_DIR),
        (ino_a, "a.bin", FT_REG), (ino_d1, "d1", FT_DIR),
        (ino_deep, "deep.bin", FT_REG),
    ])
    blocks[P_d1][:] = dir_block([
        (ino_d1, ".", FT_DIR), (ino_root, "..", FT_DIR),
        (ino_b, "b.w", FT_REG),
    ])

    # a.bin: 内联单片 extent
    write_inode(blocks, ino_a, 0o100644, 4 * BLKSZ,
                i_block_inline_leaf([(0, P_a, 4)]))
    # b.w: 内联两片
    write_inode(blocks, ino_b, 0o100644, 5 * BLKSZ,
                i_block_inline_leaf([(0, P_b0, 2), (2, P_b1, 3)]))
    # d1 目录
    write_inode(blocks, ino_d1, 0o040755, BLKSZ,
                i_block_inline_leaf([(0, P_d1, 1)]))
    # root 目录
    write_inode(blocks, ino_root, 0o040755, BLKSZ,
                i_block_inline_leaf([(0, P_root, 1)]))
    # deep.bin: 内联索引根(深度1) -> P_idxblk(索引块) -> P_leaf(叶)
    #   P_idxblk 内容 = 指向叶的索引项; 但为了让递归走到叶, 我们把它写成
    #   "索引块" 需占用一个含叶子指针的块。这里简化: P_idxblk 直接放 leaf
    #   (即把"索引块"当作 leaf), 索引根指向它, 递归到它当 depth0 → 取叶。
    #   这样 deep 那条路径 = 内联根(深度1) → 索引块(当作叶) → 叶extent。
    blocks[P_idxblk][:] = index_block_leaf([(0, P_leaf, 8)])
    write_inode(blocks, ino_deep, 0o100644, 8 * BLKSZ,
                i_block_inline_index([(0, P_idxblk)]))

    img = b"".join(bytes(b) for b in blocks)
    phys = {"a": (P_a, 4), "b0": (P_b0, 2), "b1": (P_b1, 3), "leaf": (P_leaf, 8)}
    return img, phys


def run():
    img, phys = build_image()
    tmp = os.path.join(tempfile_gettempdir(), "ext4_test.img")
    open(tmp, "wb").write(img)
    try:
        fs = Ext4FS(open(tmp, "rb"))
        fs.load()
        files = fs.walk(2, "")
        bypath = {f["path"]: f for f in files}
    finally:
        os.unlink(tmp)

    ok = True
    def chk(name, cond, detail=""):
        nonlocal ok
        print("%s %s %s" % ("PASS" if cond else "FAIL", name, detail))
        if not cond:
            ok = False

    chk("找到3文件", set(bypath) == {"a.bin", "deep.bin", "d1/b.w"},
        str(sorted(bypath)))
    chk("a.bin 单extent", bypath["a.bin"]["extents"] == [(0, phys["a"][0], 4)],
        str(bypath["a.bin"]["extents"]))
    chk("b.w 跨extent", bypath["d1/b.w"]["extents"]
        == [(0, phys["b0"][0], 2), (2, phys["b1"][0], 3)],
        str(bypath["d1/b.w"]["extents"]))
    chk("deep.bin 索引递归", bypath["deep.bin"]["extents"]
        == [(0, phys["leaf"][0], 8)],
        str(bypath["deep.bin"]["extents"]))
    chk("deep.bin size", bypath["deep.bin"]["size"] == 8 * BLKSZ)

    print("\n结果:", "ALL PASS" if ok else "HAS FAIL")
    return ok


def tempfile_gettempdir():
    import tempfile
    return tempfile.gettempdir()


if __name__ == "__main__":
    sys.exit(0 if run() else 1)
