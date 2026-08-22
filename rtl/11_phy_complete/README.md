# rtl/11_phy_complete — 自研简化 DDR5 PHY（独立支线）

纯 Verilog-2001，iverilog 直接可跑；与 `rtl/10_phy_final`（Wavious 真 PHY）**互不依赖**。

## 跑法

```bash
cd rtl/11_phy_complete
iverilog -o sim/tb_ddr5_phy tb/tb_ddr5_phy.v ddr5_phy.v ddr5_tx.v ddr5_rx.v ddr5_calibration.v pll_stub.v
./sim/tb_ddr5_phy          # 期望输出 PASS: FSM reached READY
```

## 定位

- **不是**可流片的 DDR5 PHY：8-bit 单字节、TX 实为 SDR、RX 假 DDR、校准是盲计数、无命令总线(CA/CS/RAS/CAS/WE 全常量)
- **价值**：① iverilog 友好的骨架参考；② 已修复的两个握手 bug 有通用意义；③ 计划改造为 **mini DFI 控制器**给 Wavious PHY 的仿真供数（我们缺内存控制器）

## 已修复的 bug（2026-08-22）

1. `dfi_init_complete` 单周期脉冲被 100MHz 采样沿错过 → FSM 卡死 INIT。
   修复：DUT 加 2FF 同步器；TB 改为电平握手（拉高直到 FSM 进入 CAL）。
   教训：**跨时钟域握手用"保持到对方确认"，别赌脉冲宽度对齐**。
2. `dfi_rddata_en` 是输出却恒 1 又被本模块 FSM 读回 → READY→READ 自触发死循环。
   修复：改为 `(state==PHY_READ)` 读窗口指示 + 读超时兜底返回 READY。

## 遗留问题（未修）

- pll_stub 的 clk_90 与 clk_180 同相（都在 negedge 翻转），非正交
- RX 捕获靠 DQS 边沿计数锁存，一次触发后永久武装
- 校准无真实测量回读
