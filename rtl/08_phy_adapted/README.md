# WDDR PHY 通用适配版

## 目标

设计一个不绑定特定代工厂的 LPDDR5X PHY：
- **数字逻辑**：完全可移植，不依赖任何代工厂
- **模拟接口**：通过 stub 模块预留，根据代工厂替换

## 架构

```
wddr_phy_generic.v (顶层)
├── pll_stub.v          ← 需要代工厂替换
├── ck_driver_stub.v    ← 需要代工厂替换
├── wddr_tx_generic.v   ✅ 纯数字，可移植
└── wddr_rx_generic.v   ✅ 纯数字，可移植
```

## 文件列表

| 文件 | 功能 | 可移植性 |
|---|---|---|
| `wddr_phy_generic.v` | 顶层模块 | ✅ |
| `wddr_tx_generic.v` | TX 通路 | ✅ |
| `wddr_rx_generic.v` | RX 通路 | ✅ |
| `foundry_stub.v` | 代工厂接口桩 | ❌ 需替换 |
| `tb/wddr_phy_tb.v` | 测试平台 | ✅ |

## 代工厂适配指南

### 步骤 1：替换 PLL

找到你代工厂的 PLL IP，替换 `foundry_stub.v` 中的 `pll_stub`。

需要提供的信号：
```verilog
input  ref_clk,     // 参考时钟
input  rst_n,       // 复位
output clk_0,       // 0° 相位
output clk_90,      // 90° 相位
output clk_180,     // 180° 相位
output clk_270,     // 270° 相位
output locked       // 锁定信号
```

### 步骤 2：替换 I/O Cell

找到你代工厂的 I/O Cell，替换 `foundry_stub.v` 中的驱动器/接收器。

需要提供的模块：
- `ck_driver_stub` → 差分时钟驱动
- `dq_driver_stub` → 数据输出驱动
- `dq_receiver_stub` → 数据输入接收
- `ca_driver_stub` → 命令地址驱动

### 步骤 3：调整时序参数

根据你代工厂的 timing library 调整：
- 时钟频率
- 建立/保持时间
- 驱动强度

## 代工厂选择

| 代工厂 | 工艺 | PLL 可用 | I/O Cell 可用 | 备注 |
|---|---|---|---|---|
| SMIC | 14nm | ✅ | ✅ | 需联系销售 |
| TSMC | 16nm | ✅ | ✅ | 成本较高 |
| GlobalFoundries | 12nm | ✅ | ✅ | Wavious 原版 |
| 华虹 | 14nm | ✅ | ✅ | 国产选项 |

## 验证

```bash
# 编译
iverilog -o wddr_phy_tb.vvp wddr_phy_generic.v wddr_tx_generic.v wddr_rx_generic.v foundry_stub.v tb/wddr_phy_tb.v

# 运行
vvp wddr_phy_tb.vvp
```

## 下一步

1. **确定代工厂**：联系 SMIC/TSMC/华虹 获取 IP 报价
2. **替换 stub**：用代工厂实际 IP 替换 stub 模块
3. **集成到芯片**：连接到你的 GEMV 计算单元
4. **流片**：MPW 验证
