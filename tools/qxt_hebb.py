"""qxt_hebb.py — 兼容垫片 (已改名).

**本方法现名: 赫布写入 / hebb** (HebbWrite) —— 实现见 `tools/hebb_write.py`.
本文件仅为兼容 16 个旧脚本保留, 新代码请直接 `from hebb_write import HebbWriter`.

对照:
  赫布写入 HebbWrite = 注入已训练模型 (本项目方法)
  赫布构造 HebbBuild = 论文方法 (整块替换 MLP)
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from hebb_write import (  # noqa: F401
    DEFAULT_SLIM,
    Fp32Mat,
    HebbInjector,
    HebbWriter,
)

if __name__ == "__main__":
    import hebb_write
    hebb_write.main() if hasattr(hebb_write, "main") else None
