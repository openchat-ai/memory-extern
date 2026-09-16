# 第 5 章 参考文献

> 本篇只列**被正文实际引用、且条目本身可回查**的文献。凡条目我自己没亲眼读过原件、凭二手的，
> 一律标注"转引自对账章 2.5"，不冒充第一手。文献列表本身遵守第 4 章纪律：不为任何物种担保
> 读了引文就写出了正确引擎。

## 5.1 定理/原理层（第 2 章引用）

1. **Eyeriss**：Chen, Y.-H., Emer, J., Sze, V. — *Eyeriss: An Energy-Efficient Reconfigurable
   Accelerator for Deep Convolutional Neural Networks*（ISCA 2016）。row-stationary 数据流，
   AlexNet 上 DRAM 访问 0.0029 次/MAC（≈344× 片上复用）。——第 2 章 2.5：慢介质读一次、
   最快层复用的实证存在性实例。
2. **Roofline**：Williams, S., Waterman, A., Patterson, D. — *Roofline: An Insightful Visual
   Performance Model for Multicore Architectures*（CACM 2009）；复用判定条件在 LLM 推理的
   表现见 vLLM 技术报告（带宽受限区 decode ~1 FLOP/byte，复用是唯一杠杆）。——第 2 章 2.5。

## 5.2 实现/系统层（第 2 章对账，转引）

3. **CXL-SpecKV**：arXiv 2512.11920 —— CXL 内存上的 liveness 驱动 KV 预取与驱逐（活集超容量
   时的妥协处置，即定理不在场情形的实例）。
4. **FAST-Prefill**：arXiv 2510.16323 —— 热/冷 KV 分层 + liveness 驱逐，TTFT 2.5×。
5. **FlightLLM / GLITCHES**：权重 read-once 流式；decode 阶段权重从 DDR 读一遍即弃——高速层
   维持复用、慢层只读一次在现代 LLM 的重现。

## 5.3 真机字节账（第 3 章证据出处，本篇自产可回查）

6. k3 x86 真机专家段字节流台账：`notes/byteflow-matrix.md`（k3 x86 冷启动 2026-08；专家段
   25.83GB/token @ 84MB/s，占端到端 94%，303s/token）。——第 3 章证据依赖此账，账在文件可回查。

> 注：本篇不收录未读原件的"未来引擎正确性"类声明——未发生，无法回查（第 4 章 4.2/4.3）。

——第 5 章 完（压缩版，六件套由此补齐）——
