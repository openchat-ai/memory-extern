# sky130 时序估计（tt 25°C 1.8V, pre-layout）

## 链路
skywater-pdk-libs-sky130_fd_sc_hd JSON (fluence-flat) `j2l.py` → `sky130.tt.lib`
（197 cells，fd_sc_hd）→ yosys `read_liberty -lib` + `synth` + `dfflibmap` + `abc -liberty`
→ `tt.abc.v`（2704 instances / 45 cell types）

## 关键路径延迟（aggressive crude STA：drsta.py 自写，NLDM nearest-index，
   输入 slew=x1 max，输出负载=扇出电容和，无布线/时钟偏斜）

| 模块 | 门数 | cp(ns) | 备注 |
|---|---|---|---|
| f32_add | 1562 | 3.16 | 对齐→加→规格化→舍入串链 |
| periph_scale | 784 | 1.98 | 纯组合 |
| periph_mac | 310 | 0.46 | 累加环路被 DFF 切断 |
| tt_um_periph_mac | 48 | 0.32 | 顶层控制 |

## 驱动强度（clkinv 四尺寸）
| cell | 小负载0.02pF | 大负载1.0pF |
|---|---|---|
| _1 | 0.145 ns | 1.550 ns |
| _2 | 0.055 ns | 1.653 ns |
| _8 | 0.040 ns | 1.662 ns |
| _16 | 0.028 ns | 0.821 ns |

结论：小负载下底面积更小的 cell 不差；1pF+ 大扇出才值得 _16（唯一大幅领先）。
映射时 abc 选了 45 种 base 单元（多数 _1/_0），对 fp32 加法器负载是合理的。

## 限制（诚实说明）
- pre-layout：0 布线延迟、0 时钟偏斜，真实功耗更差
- 未建模 slew 传播（输入 slew 恒为查表上限），延迟偏乐观
- abc 的 `stime`/`&stime` 在本机 abc 1.01 build 有 assertion bug，故用自写 drsta.py
