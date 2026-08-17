# 04_dequant — 归档状态

本目录原为 MXFP4 去量化练习（OCP MX 标准），源与验证脚本已迁移：

- `../05_gemv/dequant.v` —— RTL 去量化器
- `../05_gemv/dequant_tb.v` + `../05_gemv/gen_dequant_tb.c` —— 边界验证（含次正规/溢出/NAN）
- 回归入口：`../05_gemv/check.sh [0/7]`

旧 fixture 保留在此作历史参照（`gen_hex.py` 生成失败后由 `gen_dequant_tb.c` 取代，
C 参考逐位比对已覆盖并超越原 22.9 万元素集），`tb` 为旧版编译产物，已删除。