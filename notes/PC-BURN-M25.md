# PC-BURN-M25 — M25 主线烧录收敛清单 (PC 侧承接)

## 输入件 (termux 已交, git 当前)
- rtl/13_mega138k/board_decode_top.v   (整包顶层, GOOD 双证 led[3])
- rtl/13_mega138k/decode_auto_core.v   (SELFDRV=1 自驱闭环; STRESS=0 默认关缺陷窗)
- rtl/13_mega138k/{route_asm,router_sel,attn_inner_ctl,head_vprune,vocab_prune,output_head}_sf.v
- rtl/34_assembler/assembler.v ... (7 产品件, 零改动)
- cst: mega138k_engine.cst (sys_clk P16=50MHz 直连 rst K16 led M25/R26/L20/J14)

## 已验证 (termux)
- yosys 0.68 synth_gowin -top board_decode_top 全 14 文件 rc=0
  (占位数据面折叠后 LUT540+ALU366+FF616; 激活面真账 PC 用真数据面重估)
- core_selftest: done@162, a_words=128, 内容级哈希 0104bef0 同seed复现
- board_good_tb: GOOD(led[3]) 帧3起, 双证 (每帧+128词 && 内容流活跃)

## 执行序
1. 上游 Gowin EDA: read netlist (译出) + cst + .sdc (make .sdc: sys_clk 50MHz create_clock)
2. P&R 四个 option 排列 (参考 macsplit smoke: route=2 place=3 max_fanout=100)
3. 检查时序: Fmax 目标 ≥50MHz (逻辑深度预算见 SF12+ P8: 余量充裕; 关键链3 fk ~19级)
   - 若 >124MHz 兴趣: fk 加入两拍流水再收敛 (P8 建议)
4. 烧录 SRAM (JTAG 8MHz; 15MHz 曾 20% 失败, 直接 8MHz 稳妥)
5. 板验判活:
   - LED[0] 心跳 (div[22] 慢闪) ; LED[2]=done 帧内高; LED[3]=GOOD 数帧后常亮; LED[1]=busy strobe
6. 读回/观测: out_data/out_expert 帧流 (切片词内容=预灌值, 与 core_selftest 基准可比)

## 已知缺陷复查项
- DC01 (SF12b): 信用停摆窗下 assembler 切片相位错位 (前71词一致, 后48词 +0x20 偏移)
  - 默认 STRESS=0 (板上无停摆) 不影响; 若上游信用波动设计, PC 侧修 assembler 层握手
    (S_TAKE 显式 in_valid 连续, 或 router layer_done 对齐) 后回归 core_stress_tb。
- 词表预灌: slice LUT 用 wr 接口预灌 (值=序号语义已验); 真词表数据 PC 替换 wr_data。