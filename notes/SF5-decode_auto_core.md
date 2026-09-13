# SF5 — decode_auto_core 设计契约(上板真硬件主目标)

## 1. 目的
把 M25 连续多步解码闭环(tb 内嵌 8 模块 DUT 网)抽为可综合 core,f在 Tang Mega 138K 上
跑真硬件,替代 termux 仿真验证。资源账与障碍在 termux 侧收敛,综合/时序/烧录归 PC。

## 2. 拓扑(与 rtl/41_decode_auto/decode_auto_tb.v 同名 DUT 网逐点同构)
| 实例 | 来源 | 参数冻结口径 | 端口要点 |
|---|---|---|---|
| u_ras   | route_asm      | EX16/TOP4/EW8/NL4/SW16 | in_token 链 → s_score/s_valid → asm/logit |
| u_ex    | sched_exec     | DW32/AW8/NL4/GW16/ATW128 | rail 调度,GDEPTH=GW |
| u_rail  | gemv_rail_ctl  | TDEPTH16/AIDX4 | act_in/weight_in/feed |
| u_pool  | sram_pool_arb  | AW8/DW32 | 池控 |
| aw      | attn_window    | HEADS4/HBUF16/BUFS2 | 窗口 |
| u_ctl   | attn_inner_ctl | DW32/HEADS4/WPR2 | q_vec_p/mul 流水 |
| u_arr   | gemv_array_128 | MAC128 | 128 LANE 乘加 |
|  HV     | head_vprune    | VOC1024/GRP16/BB16/MAXE14/K3/FKXG | 去母 top-K |

NVOC=1024, NK=3, TN=12 (M35/TN, M41/NVOC, M42/NK 冻结)。

## 3. 端口契约(最小锚碇, 与 tb 前端喂送方式一致)
```
module decode_auto_core #(EX=16,TOP=4,EW=8,SW=16,NL=4,NVOC=1024,NK=3,TN=12,
    DW=32,AW=8,GW=16,ATW=128,HEADS=4,HBUF=16,BUFS=2,WPR=2,FEED=4,WA=64,ROWS_TOT=32,BLK=8)( 
  input               clk, rst_n, run,         // run: 起 TB 级循环
  input  [DW-1:0]     query_in,                // 首 token/query (外源)
  input  [DW-1:0]     fresh_in,                // rail 权重/词表注入 (外源, 寄存器级)
  input  [DW-1:0]     weight_in, act_in,       // gemv1 双路向量
  input  [DW-1:0]     ctl_w, ctl_a,            // attn 双路向量
  input  [DW-1:0]     arr_w, arr_a,            // gemv2 双路向量
  output              busy, done,              // done: TN 步终
  output [$clog2(NVOC)-1:0] out_tok, orig_tok, // 每步 argmax + 原始词号
  output [11:0]       out_logit,               // 适配 head_vprune 出口
  output [31:0]       rounds, stall_ct
);
```
### 3.1 闭环(内嵌状态机, 待 PC top 补齐)
run → 每步: query/feed 进→8 模块网→HV out_tok→ argmax→ 写回 feed →
若 rounds<TN-1 继续; 否则 done=1。backpressure 全走 s_take/svc 与 credit(产品语义)。

### 3.2 资源预估(termux 已账合计, LUT 当量)
| 模块 | LUT当量 | 来源 |
|---|---|---|
| gemv_array_128       | 10378 | probe |
| sched_exec           | 11799 | probe |
| attn_window          |  1392 | probe |
| gemv_rail_ctl        |   654 | probe |
| assembler            |    ~  | probe(未出账但可综合) |
| attn_inner_ctl_sf    | 10831 | SF3-P3 |
| router_sel_sf        |  待PC | ys0.68 muxtree 数组段移位 |
| route_asm_sf         |  待PC | 同左(链上 R.k 实例) |
| head_vprune 系       |  待PC | VOC512 全组合 fk 重, termux OOM |
| **合计(乐观)**        | ~3.5万 | 138K LUT4 富余; 时序/BRAM 归 PC |

## 4. PC 侧执行清单
1. nextpnr-gowin/Gowin EDA 读 rtl/13_mega138k/ 全部 *_sf + 产品同源模块;
2. head_vprune/词表 ROM 化(VOC 表 ASYNC_RAM→2K BRAM);
3. 板上 smoke: led 心跳 + core 自检 SUM 校验 (复用 tb 确定性 LCG 权重, 固化 LFSR);
4. 测列: 40-060 microbench pump 600 cts ×2 ................................. 具体测列届时定。

## 5. 与验证体系接口
- 产品 RTL(01-41) + 41 TB 不动,210 门基线冻结;
- 镜像 (*_sf) 只增不改产品, 每镜像列出唯一差异(见各文件头注释与 SF3 台账);
- termux 侧等价性证据 = 逐行 diff 审查 + hierarchy 0 ERROR; LOCKSTEP 对账留 PC。
## SF6 增补 — board_smoke 烧录就绪 (termux 侧全闭环)
- rtl/13_mega138k/board_smoke_top.v: led[0]=clk 分频眨眼; led[1]=乘加自检 (LFSR 初值
  CAFE_BEEF, 8 拍流水 16x16→32 累加) == GOLD 0xe552b3e0 (board_smoke_self_tb 标定);
  led[3:2]=LFSR 位状态。合成一次过: LUT69 + ALU174 + FF268 (~819 LUT 当量)。
- 自标定过程抓到 2 个真 bug: ① prod_r 16bit 截断 32bit 乘 ② tb double-loop 污染 GOLD。
  断言体系生效; RTL 已修。
- 烧录清单 (PC + Gowin EDA / nextpnr-gowin):
  1. cst 复用 mega138k_engine.cst 引脚节 (sys_clk P16 / rst_n K16 / led[3:0]);
  2. sys_clk 直连 50M 振荡器 (PLL 留后续 core);
  3. 综合/布线/烧写 → 板上观: led0 眨眼 + led1 常亮 = FPGA 基本逻辑+乘加链判活;
  4. 通过后再切 decode_auto_core 全核时序收斂。

## SF7 落地 — decode_auto_core 骨架 (可编译实体)
- rtl/13_mega138k/decode_auto_core.v: 8 模块 DUT 网 + 最小状态机 (run→go→wait token_done & h_token_done→done)
  数据面 (s_v_t/gsw/qf) 外源注入端口 (SF5 契约); 全链走 *_sf 镜像 (ys0.68 数组/参数for界兼容)。
- 实测: yosys hierarchy 0 ERROR (读 *_sf 集合) + iverilog elab rc=0 + vvp rc=0。
- 迭代录: 3 处 `*_sf 化` (attn_inner_ctl_sf 打包端口 → route_asm_sf → head_vprune_sf cand 打包) 均为
  ys0.68 边界实证复述, 逐一对应已验证镜像。
- 后续: core mini smoke (状态机连通) → PC 数据面填充 → 全核 P&R。

## SF8 补记 — sram_pool_arb 账 (P4 定案)
- termux 综合: LUT=95175/ALU=288/FF=428 (rc=0)。95K LUT 失真 = mem 数组未映射 BRAM 摊成
  大 LUT 逻辑 (SF1 观察复证)。P4: 换 Gowin_DPB/SDPB 原语 (厂商工艺映射, 归 PC; termux 无网表) 。
- core 资源预估更新: 现全部 *_sf 链单独账皆在; 全核 P&R 时以 BRAM 化后为准。

## SF9 收口 — board_decode_top 整包可烧 (termux 全链闭环)
- rtl/13_mega138k/board_decode_top.v: sys_clk 直连 50M / rst_n / led[3:0] (cst 复用 engine);
  core 例化 + 周期 run 脉冲; led[0]=心跳 led[1]=busy led[2]=done led[3]=out_token[0]。
- synth_gowin -top board_decode_top 全 *_sf 链 (14 文件) rc=0:
  LUT=1410 ALU=750 FF=552 (LUT当量2.9K) — 占位数据面被常化折叠的激活核;
  PC 夯真数据面 (ROM/外源) 后按真规模 P&R。
- 迭代录: ①slice_addr 常数驱动拒 (ys) → 悬空 ②rail_feed 常数驱动拒 → 悬空
  ③sl_reg 自保持被 iverilog 拒 unresolved ④ 端口悬空=干净 (input/output 均无连接即可)。
- 状态: decode_auto_core (SF7) 与 board_decode_top (SF9) 均 iverilog/vvp/ys0.68 hierarchy 兼容;
  core_smoke PASS (run→busy 状态机连通)。

## SF10 自驱闭环 — core 内嵌数据面 (SELFDRV=1), 真链真跑全完成
- decode_auto_core 修改: ①SELFDRV 内嵌 LFSR 分值源, RUN 期每拍供专家(int_drv), full cred الم恒开;
  ②occ_q 同拍吞吐 bug 修复: 通拍 out_valid&&credit_r 存量不动(原式在occ=0 时净+1 →
  单调顶 2048 → 信用钳死 → assembler 卡死, 96拍后 cr=0 实证);
  ③done 巡检 h_td_cap sticky 采集 (h_token_done@115 早于 token_done@160, 错拍两高永不达原条件)。
- core_selftest PASS: token_done@160 a_words=128 全量; done@162 连续两次同 seed 哈希 ff81ff81 逐位一致;
  哈希域 = out_expert/words 流程稳态 (词表内容 x 属 PC 预灌, 见 SF5 契约)。
- 词流实证: 128 词 / 每层 4 专家 ×8 词 × 4 层; 决策 expert 序 [0,4,1,14,...] 确定性。
