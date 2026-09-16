#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# 生成投稿排版 PDF（A4、STSong CID 中文字体，无需安装 LaTeX）
# 《计算机应用与软件》投稿版：实证发现为主、定理降格为排查判据
# 用法：python3 make_paper_pdf.py   → 输出 paper-submit-cjas.pdf
from reportlab.lib.pagesizes import A4
from reportlab.lib.units import cm
from reportlab.lib import colors
from reportlab.lib.enums import TA_JUSTIFY, TA_CENTER, TA_LEFT
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.cidfonts import UnicodeCIDFont
from reportlab.lib.styles import ParagraphStyle
from reportlab.platypus import (BaseDocTemplate, Frame, PageTemplate,
                                Paragraph, Spacer, Table, TableStyle)

OUT = 'paper-submit-cjas.pdf'
TITLE = '命中率指标掩盖的慢介质全量重读：MoE 推理平台的实证分析与排查判据'
pdfmetrics.registerFont(UnicodeCIDFont('STSong-Light'))

BODY = 10.5
LEAD = 17.0
INDENT = BODY * 2

S_title = ParagraphStyle('title', fontName='STSong-Light', fontSize=15,
                         leading=22, alignment=TA_CENTER, spaceAfter=6)
S_author = ParagraphStyle('author', fontName='STSong-Light', fontSize=11,
                          leading=18, alignment=TA_CENTER, spaceAfter=2)
S_meta = ParagraphStyle('meta', fontName='STSong-Light', fontSize=8.5,
                        leading=14, alignment=TA_CENTER, spaceAfter=10)
S_h1 = ParagraphStyle('h1', fontName='STSong-Light', fontSize=13,
                      leading=20, spaceBefore=14, spaceAfter=6)
S_h2 = ParagraphStyle('h2', fontName='STSong-Light', fontSize=11,
                      leading=18, spaceBefore=8, spaceAfter=4)
S_body = ParagraphStyle('body', fontName='STSong-Light', fontSize=BODY,
                        leading=LEAD, alignment=TA_JUSTIFY,
                        firstLineIndent=INDENT, spaceAfter=3, wordWrap='CJK')
S_eq = ParagraphStyle('eq', parent=S_body, firstLineIndent=0,
                      alignment=TA_CENTER, spaceBefore=4, spaceAfter=4)
S_list = ParagraphStyle('list', parent=S_body, firstLineIndent=0,
                        leftIndent=18, spaceAfter=3)
S_cap = ParagraphStyle('cap', fontName='STSong-Light', fontSize=10,
                       leading=15, alignment=TA_CENTER, spaceBefore=6, spaceAfter=4)
S_tcell = ParagraphStyle('tcell', fontName='STSong-Light', fontSize=9.5,
                         leading=14, alignment=TA_LEFT, wordWrap='CJK')
S_tcell_c = ParagraphStyle('tcell_c', parent=S_tcell, alignment=TA_CENTER)
S_ref = ParagraphStyle('ref', fontName='STSong-Light', fontSize=9,
                       leading=13.5, leftIndent=16, firstLineIndent=-16,
                       spaceAfter=2, alignment=TA_JUSTIFY, wordWrap='CJK')


def P(t, s=S_body): return Paragraph(t, s)


META = [
    '作者姓名',
    '作者单位，省份　城市　邮编；作者职称、研究方向占位',
    '收稿日期：2026-××-××　基金项目：××××（编号 ×××××××）',
    '第一作者：×××，××（职称），主要研究方向为×××；邮箱：xxx@xxx.xxx（通讯作者）',
    '中图分类号：TP3　文献标志码：A',
]

ABSTRACT = ('<b>摘要：</b>混合专家（Mixture-of-Experts，MoE）大模型的推理平台中，一个常被忽视的带宽'
            '问题在于：当被激活的专家权重无法常驻最快介质层时，即使引擎报告的缓存命中率为 100%，每个 '
            'token 仍必须从慢介质全量重读全部专家权重。本文以 2.8T 参数开源模型在 k3 x86 主机上的冷启动'
            '推理为对象，通过字节级台账实测了这一现象：每 token 专家段从慢盘读取 25.83 GB，耗时 303.58 s，'
            '占端到端耗时的 94%，而平台自带“命中率”白板指标并未反映这一事实。本文将问题归因于“复用未'
            '落在数据能到达的最快介质层”，给出形式化判据：若复用确实发生在最快介质层，则每个更慢介质层'
            '的最小读取次数为 1，且通过缓存调度（如将权重迁入较快介质）可达。在同一平台上的对照实验中，'
            '将专家权重全量迁入 L2 介质后，专家段耗时降低约 37%，方向与判据一致。本文实测数字仅对本实验'
            '成立，判据与排查次序可迁移到同类受内存约束的推理平台。')

KEYWORDS = ('<b>关键词：</b>混合专家模型；大模型推理；缓存命中率；存储层次；带宽墙；工程实测')

S_en = ParagraphStyle('en', fontName='STSong-Light', fontSize=9.5,
                      leading=15, spaceBefore=6, spaceAfter=9)
S_en_h = ParagraphStyle('en_h', fontName='STSong-Light', fontSize=10.5,
                        leading=16, alignment=TA_CENTER, spaceAfter=4)
EN_TITLE = ('Slow-Media Full Re-Reads Masked by Hit-Rate Metrics: An Empirical Analysis '
            'and Diagnostic Criterion for Mixture-of-Experts Inference Platforms')
EN_AUTH = 'Author Name; Affiliation, City Province, China'
EN_ABS = ('<b>Abstract:</b> Mixture-of-Experts (MoE) large-model inference can be bounded by weight '
          'movement rather than compute on memory-constrained hosts. This paper reports an empirical '
          'finding on such a platform (k3 x86, cold start, 2.8T-parameter open model): although the '
          'engine reported a 100% cache hit rate, byte-level tracing showed that every token still '
          're-read 25.83 GB of expert weights from the slow disk, taking 303.58 s, which is 94% of '
          'end-to-end time. The whiteboard hit-rate metric and the underlying byte-transfer fact are '
          'two different observation surfaces, and the former can completely mask the latter. We '
          'attribute the issue to "reuse not occurring in the fastest media layer the data can reach" '
          'and formalize a diagnostic criterion: if reuse truly happens in the fastest layer, each '
          'slower layer needs to be read at least once, and that lower bound is reachable via caching '
          '(e.g., moving weights into a faster tier). In a controlled experiment, moving experts into '
          'an L2-tier medium cut expert-stage time by about 37%, consistent with the criterion\u2019s '
          'direction. The reported figures hold only for this experiment, but the criterion and the '
          'triage order transfer to similarly memory-constrained inference platforms.')
EN_KW = ('<b>Keywords:</b> Mixture-of-Experts; LLM inference; cache hit rate; storage hierarchy; '
         'bandwidth wall; engineering measurement')

BLOCKS = [
    ('h1', '1　引言'),
    ('h2', '1.1　背景与问题'),
    ('p', '大语言模型规模持续扩张，MoE 凭借稀疏激活成为主流扩展范式[1-6]。以 2.8T 参数开源模型为例[1]：'
          '共 93 层，896 路由专家，每 token 激活 16 个专家，激活参数约 104B。单看稀疏红利，每 token 只需'
          '读取全部专家权重的约 1.8%——这是 MoE 推理“省带宽”承诺的由来。'),
    ('p', '但该承诺有一个常被忽略的隐藏前提：<b>被激活的权重必须常驻在或能快速到达计算侧</b>。在 GPU '
          '服务器上，trunk 与热专家常驻显存，前提成立；而在仅有系统内存、需从机械盘流式读权重的主机或'
          '边缘设备上，前提不成立。此时稀疏只决定“必须搬动多少字节”，没有决定“这些字节从哪一层介质搬”。'),
    ('p', '这种平台上，管理层与工具层用了同一类指标（缓存命中率、缓存命中计数）汇报“缓存状态”，但这些'
          '<b>白板指标与底层字节搬迁事实是两个观测面</b>，可能互相遮蔽。本文用一个真机案例说明这种遮蔽'
          '可严重到什么程度，并给出一条可迁移的排查判据。'),
    ('h2', '1.2　实测发现：命中率 100%，字节却每 token 全量重读'),
    ('p', '在一次 k3 x86 主机的冷启动推理测试中（2026-08），引擎自报缓存命中率 100%。同一时段的内建字节级 '
          'READ 计数（台账，每行可回查）却显示：'),
    ('p', '每 token 专家段从慢盘 sde 读取 <b>25.83 GB</b>（=92 层 × 16 专家 × 17.55 MB/专家，与理论载入'
          '逐字节吻合）；该 25.83 GB 以约 85 MB/s 计耗时 <b>303.58 s</b>，占端到端 324.36 s 的 <b>94%</b>[13]。'),
    ('p', '也就是说：报告口径说“全部命中”，字节口径说“每 token 全量重读一遍”。引擎并没有做错什么——'
          '它的资源配置决定了被激活专家不常驻更快介质，因此每次都必须回慢盘取数；问题在于“命中率 100%”'
          '这个被普遍用作健康度的指标，完全看不到这一点。'),
    ('h2', '1.3　本文工作'),
    ('li', '<b>①</b>　提供可逐字节回查的字节流台账，揭示“命中率白板指标与慢介质全量重读并存”的现实；'),
    ('li', '<b>②</b>　把现象归因提炼为一条可排查的判据（复用必须落在数据能到达的最快介质层），并给出'
           '形式化表述与证明；'),
    ('li', '<b>③</b>　用对照实验（专家迁入 L2 介质，专家段耗时 −37%）验证判据的方向有效性，给出可迁移'
           '的排查次序。'),

    ('h1', '2　相关工作'),
    ('h2', '2.1　MoE 稀疏激活与它的带宽前提'),
    ('p', 'MoE 思想可追溯至 Shazeer 等的稀疏门控网络[2]，GShard[3] 提出 top-K 路由与分片，Switch '
          'Transformer[4] 将激活专家降至单个，Mixtral of Experts[5] 验证开源 8×7B 级 MoE 的实用性，'
          'DeepSeekMoE[6] 提出细粒度专家切分与共享专家隔离，本文实验对象[1]在此基础上将路由专家扩展至 '
          '896。上述工作的稀疏红利都以“激活权重可被快速访问”为前提；本文不讨论模型侧稀疏性优化，聚焦'
          '“既定的激活集合如何穿越存储层次”这一实现侧问题。'),
    ('h2', '2.2　存储层次与带宽建模'),
    ('p', 'Roofline 模型[7]给出了算力/带宽瓶颈的经典判断框架：在带宽受限区（decode 阶段约 1 FLOP/byte），'
          '<b>复用是唯一杠杆</b>。但 Roofline 回答的是“复用值不值得做”，未回答“复用应落在哪一层介质”。'
          'Eyeriss[8] 在加速器层面实证了“慢层读一次、片上复用数百次”的存在性（AlexNet 上 DRAM 访问约 '
          '0.0029 次/MAC）。这与本文方向一致；本文补充的是工程观测面：<b>如何发现平台的“复用”其实没有'
          '落在应落的那一层</b>。'),
    ('h2', '2.3　LLM 推理的缓存、预取与调度'),
    ('p', 'vLLM/PagedAttention[9] 用分页缓存消除 KV 碎片，可视为“让复用尽量落在快层”的实现；FlightLLM[10] '
          '在 FPGA 上把 decode 权重复用约束在片上；CXL-SpecKV[11] 用 CXL 内存池、预测预取与冷热分层缓解 '
          'KV 缓存带宽墙，其活集超容量时的预取/驱逐正是本文判据“不在场”情形的处置；FastKV[12] 以“只保留'
          '必要数据于快层”为原则解耦压缩与算力。这些工作都隐含“慢层应只被读一次、复用应留在快层”的'
          '工程直觉，但未见把它变成一条<b>可回查的判据</b>；本文补上这形式化一步。'),

    ('h1', '3　排查判据：慢介质读一次'),
    ('p', '本节是一条可回查的判据，作为排查工具使用。若某平台实测的慢层读取次数明显大于其下界，说明'
          '判据的“在场条件”未被满足——先查复用落在哪一层，而不是先怀疑算法是否需要免读。'),
    ('h2', '3.1　定义'),
    ('p', '设存储层次由 N 层介质构成，按单次字节访问代价单调上升排序：M<sub>1</sub>（最慢，代价最高）→ '
          'M<sub>2</sub> → … → M<sub>N</sub>（最快，代价最低）。对数据项 d，被访问（复用）总次数 R≥1；'
          '记 R<sub>i</sub> 为 d 从介质 M<sub>i</sub> 被读取的次数（i=1,…,k，M<sub>1</sub> 最慢）。'),
    ('p', '<b>参与路径</b>：判据只对 d 实际穿越的介质下结论。某介质物理上更快但 d 从不进入，则不参与 '
          'd 的路径，不计入求和范围。'),
    ('h2', '3.2　判据（命题）'),
    ('p', '设数据项 d 被复用 R≥1 次，且复用的实际发生位置是 d 能到达的最快介质 M<sub>k</sub>。则对任意 '
          'i&lt;k，恒有'),
    ('eq', 'R<sub>i</sub> ≥ 1，'),
    ('p', '且该下界<b>同时可达</b>：存在读取调度使 R<sub>i</sub>=1 对所有 i&lt;k 同时成立，其余 R−1 次'
          '全部发生在 M<sub>k</sub>。'),
    ('p', '<b>推论</b>：复用若发生在最快层，各慢层读取次数总和的最小值即“各慢层恰读一次”；使该最小值'
          '达成的调度同时是慢访问代价最小的调度。'),
    ('h2', '3.3　证明'),
    ('p', '<b>第 1 步（信息守恒下界，无条件）</b>：若 d 从未被从 M<sub>i</sub>（i&lt;k）读入，则 d 不可能'
          '到达 M<sub>i+1</sub> 及以上层次，更不可能到达 M<sub>k</sub> 被复用——数据只能逐层向上搬移。因此'
          '每层 M<sub>i</sub>（i&lt;k）至少被读一次：R<sub>i</sub>≥1。此下界不依赖任何容量假设与工作量。□'),
    ('p', '<b>第 2 步（代价单调）</b>：介质按访问代价单调排序，层号越大代价越低。任何越过下界 1 的“多余”'
          '慢读都可被替换为一次更快介质的读取而不增加总代价（慢读严格贵于快读）。故达到下界的调度使'
          '慢访问总代价最小。□'),
    ('p', '<b>第 3 步（可达性）</b>：复用发生在 M<sub>k</sub> 意味着 d 在 M<sub>k</sub> 有活集位置，R−1 次'
          '复用可全部在 M<sub>k</sub> 内完成；d 到达 M<sub>k</sub> 的路径即逐层各读一次（M<sub>1</sub> 一次 → '
          'M<sub>2</sub> 一次 → … → M<sub>k</sub> 一次），该调度合法且同时满足所有下界。□'),
    ('h2', '3.4　判据的使用与边界'),
    ('li', '<b>用法</b>：先核对“复用事实是否真的发生在最快层”（在场条件）；再数“慢层实测读取次数”。'
           '若实测明显大于 1，几乎总是因在场条件被违背（典型如“命中不落内存、每次仍全量搬迁”）。此时'
           '应去查资源配置，而不是先质疑算法。'),
    ('li', '<b>边界</b>：容量不构成判据条件——若活集超出 M<sub>k</sub> 容量，复用无法全部落在 '
           'M<sub>k</sub>，这是“不在场”情形，判据不违反、不适用；物理更快但不参与路径的介质不计入；'
           '判据回答“下界是多少、达到没有”，不回答“如何达到”（那交给调度工作[9-12]）。'),

    ('h1', '4　真机实测与对照实验'),
    ('h2', '4.1　平台与数据来源'),
    ('p',     '实验对象：2.8T 参数开源模型权重[1]。作者对权重做 safetensors 全量字节扫描，专家语义为 MXFP4 '
          '格点、实际落盘约 2.12 bit/weight（含 scale）[13]，单专家 17.55 MB。引擎：k3 x86 真机推理实现[14]；'
          '存储层次：慢盘 sde（源盘，近满、实测约 84~85 MB/s）→ L2 介质 sdd7 → 系统内存 → 计算。运行时'
          '统计内建字节级 READ 计数；出处为台账文件，标注行号可逐字节回查[13]。'),
    ('h2', '4.2　发现一：命中率 100% 与“每 token 全量重读”并存'),
    ('p', '表 1 给出关键台账数字。核心结论是两套口径的分裂：<b>白板口径（引擎自报）</b>＝缓存命中 100%；'
          '<b>字节口径（台账实测）</b>＝每 token 从慢盘全量重读 25.83 GB、占端到端 94%。且实测 READ 量与'
          '理论载入逐字节吻合（92×16×17.55 MB），说明不是“额外读取”，而是“该读的一次都不少、还从最慢'
          '的介质读”。'),
    ('table1', None),
    ('p', '说明：表中 84 MB/s 与 85 MB/s 两值各有出身——84 MB/s 是介质性能刻画的整值（慢盘近满、巨型 '
          'O_DIRECT pread 的实测形态），85 MB/s 是 25.83 GB 与 303.58 s 的精确商。本文据实并列，不引入'
          '第三个“速率”声称。'),
    ('h2', '4.3　为什么白板指标“看不见”这一事实'),
    ('p', '对照第 3 章判据：该平台的问题是“在场条件”被违背——被激活专家的复用没有落在它能到达的'
          '最快介质（内存）层，而是每次落回慢盘。引擎自报的“命中率”建立在白板计数口径上，这一口径与'
          '字节搬迁是两个观测面，前者无法反映后者。由此得到一条经验：<b>对受内存约束的推理平台，“缓存'
          '命中率”不应单独作为健康度指标，需与字节级 READ 计数对照使用。</b>'),
    ('h2', '4.4　对照实验：让复用靠近快层'),
    ('p', '判据预演：慢介质读一次的前提是复用落在更快层。2026-08 复查将专家全量 distinct 集（约 10,010 '
          '个专家 × 17.55 MB ≈ 176 GB）驻留到 L2 介质 sdd7（实测约 419 MB/s，较慢盘快约 5 倍）：专家段耗时'
          '从 303 s 降至 <b>191.6 s（约 −37%）</b>，端到端从 326.5 s 降至 262.8 s。'),
    ('p', '该读数两个方向性含义：其一，<b>方向与判据一致</b>——把慢盘全量重读移到更快介质，显著压缩'
          '代价；收益未达判据给的上界（trace 推演 25.8 GB→2.58 GB/token，约 −90%），因为复用仍未真正'
          '落进内存层（每 token 仍从 L2 介质 pread 25.83 GB，1786 MB/s 下亦需约 14.5 s），白板命中同样'
          '不能免除字节搬运。其二，<b>判据得到印证</b>——瓶颈不由“算法能否免读”决定，而由“复用发生在'
          '哪一层”决定。'),
    ('h2', '4.5　方法局限'),
    ('p', '第 3 章判据属逻辑层，其真值不依赖本节任何数字；本节台账属真机层，账实一致、可回查，但只对'
          '本实验（该模型、该介质、该负载、该冷启动时序）成立。台账中如实记录挂死/FAIL 条目（如 '
          'D-state 永久挂起），未选择性剔除负样本。'),

    ('h1', '5　讨论与应用'),
    ('h2', '5.1　排查次序：先问“复用落在哪一层”'),
    ('li', '<b>① 算法能否免读</b>：该数据项是否必须被读取（如专家是否真是路由集合的必要输入）；'),
    ('li', '<b>② 能否缓存复用</b>：读取结果能否在快层驻留并被复用（即判据在场条件）；'),
    ('li', '<b>③ 落盘位置</b>：若必须慢读，权重是否至少置于参与路径中较快的介质；'),
    ('li', '<b>④ 落盘前压缩</b>：能否先压缩再落盘，减少届时必须搬动的字节。'),
    ('p', '本案例中引擎在第 ② 条失守（命中不落内存、每次仍全量搬迁），纵使第 ①、④ 条成立，带宽墙仍'
          '占端到端 94%。'),
    ('h2', '5.2　与调度/预取工作的衔接'),
    ('p', '本文判据不替代调度器，而是为既有调度工作[9-12]提供可回查的落点：当方案声称“缓存命中”或'
          '“预取成功”时，应核实字节层是否真的避免了慢层重读——命中率指标与非易失介质上的字节搬迁指标'
          '可能互相遮蔽（见 4.4）。这正是本文想提醒平台开发者与评测者的一条操作步骤。'),
    ('h2', '5.3　局限性'),
    ('li', '存储模型假设单向逐层搬移，未覆盖旁路、直接 DMA 到计算侧等非逐层实现路径——“逐层”是可达性'
           '的充分构造，非必要路径。'),
    ('li', '真机数字来自单一模型、单次冷启动实测，不声明跨工作量恒真；判据可达性由第 3 步构造保证，'
           '与读者是否阅读本文无关。'),

    ('h1', '6　结论'),
    ('p', '本文通过逐字节可回查的真机台账揭示了一个在受内存约束的 MoE 推理平台上真实存在的现象：'
          '<b>引擎自报缓存命中率 100% 的同时，每 token 仍从慢盘全量重读 25.83 GB 专家权重，占端到端耗时'
          '的 94%</b>。“命中率”白板与字节搬运是两个观测面，前者可能完全遮蔽后者。本文从该现象抽象出'
          '一条可迁移的排查判据（复用必须落在数据能到达的最快介质层，否则慢层读取次数必然大于其下界'
          '1），并用专家迁入 L2 介质后的 −37% 对照实验验证了判据的方向有效性。对同类平台的开发者与'
          '评测者，本文建议把“复用发生在哪一层介质”作为排查带宽墙的第一步，并与“缓存命中率”指标'
          '并行观测。'),
]

REFS = [
    'Moonshot AI. Kimi K3: Open Frontier Intelligence. arXiv:2607.24653, 2026.',
    'Shazeer N, Mirhoseini A, et al. Outrageously Large Neural Networks: The Sparsely-Gated '
    'Mixture-of-Experts Layer. ICLR 2017.',
    'Lepikhin D, Lee H, et al. GShard: Scaling Giant Models with Conditional Computation and '
    'Automatic Sharding. NeurIPS 2020.',
    'Fedus W, Zoph B, Shazeer N. Switch Transformers: Scaling to Trillion Parameter Models '
    'with Simple and Efficient Sparsity. JMLR 23(120):1-39, 2022.',
    'Jiang A Q, Sablayrolles A, et al. Mixtral of Experts. arXiv:2401.04088, 2024.',
    'Dai D, Deng C, et al. DeepSeekMoE: Towards Ultimate Expert Specialization in '
    'Mixture-of-Experts Language Models. ACL 2024:1280-1297.',
    'Williams S, Waterman A, Patterson D. Roofline: An Insightful Visual Performance Model for '
    'Multicore Architectures. Communications of the ACM, 52(4):65-76, 2009.',
    'Chen Y H, Emer J, Sze V. Eyeriss: A Spatial Architecture for Energy-Efficient Dataflow for '
    'Convolutional Neural Networks. ISCA 2016:367-379.',
    'Kwon W, Li Z, et al. Efficient Memory Management for Large Language Model Serving with '
    'PagedAttention. SOSP 2023:611-626.',
    'Zeng S, Liu J, et al. FlightLLM: Efficient Large Language Model Inference with a Complete '
    'Mapping Flow on FPGAs. FPGA 2024.',
    'Liu D, Yu Y. CXL-SpecKV: A Disaggregated FPGA Speculative KV-Cache for Datacenter LLM '
    'Serving. FPGA 2026:56-66.',
    'Jo D, Song J, Kim Y, Kim J-J. FastKV: Decoupling of Context Reduction and KV Cache '
    'Compression for Prefill-Decoding Acceleration. Findings of ACL 2026.',
    '作者. kimi-k3-in-c: Kimi K3 推理引擎实现与本文字节流台账分析代码. '
    'https://github.com/openchat-ai/kimi-k3-in-c, 2026.',
    '作者自建真机字节流台账（k3 x86 冷启动，2026-08），项目内文件：notes/byteflow-matrix.md.',
]

TABLE_DATA = [
    ('指标', '数值', '出处'),
    ('每 token 专家理论载入', '92×16×17.55 MB = 25.83 GB', '台账 :246'),
    ('实测专家段 READ/token', '25.83 GB', ':325, :327'),
    ('专家段耗时', '303.58 s/token', ':327'),
    ('端到端耗时', '324.36 s/token', ':325（total）'),
    ('端到端占比', '303.58/324.36 = 94%', ':327'),
    ('等效速率（精确商）', '25.83 GB/303.58 s = 85 MB/s', ':327'),
    ('介质刻画速率（碰壁整值）', '84 MB/s（D-state 根因刻画）', ':224'),
]

REFP = [Paragraph(f'[{i}] {t}', S_ref) for i, t in enumerate(REFS, 1)]


def build_table():
    tdata = [[Paragraph(c, S_tcell_c if i == 0 else S_tcell)
              for i, c in enumerate(row)] for row in TABLE_DATA]
    w = [5.4 * cm, 6.4 * cm, 3.2 * cm]
    t = Table(tdata, colWidths=w, repeatRows=1)
    style = [
        ('FONT', (0, 0), (-1, -1), 'STSong-Light', 9.5),
        ('ALIGN', (0, 0), (-1, 0), 'CENTER'),
        ('GRID', (0, 0), (-1, -1), 0.4, colors.black),
        ('LINEABOVE', (0, 0), (-1, 0), 1.1, colors.black),
        ('LINEBELOW', (0, 0), (-1, 0), 0.8, colors.black),
        ('LINEBELOW', (0, -1), (-1, -1), 1.1, colors.black),
        ('TOPPADDING', (0, 0), (-1, -1), 5),
        ('BOTTOMPADDING', (0, 0), (-1, -1), 5),
        ('LEFTPADDING', (0, 0), (-1, -1), 8),
        ('RIGHTPADDING', (0, 0), (-1, -1), 8),
    ]
    t.setStyle(TableStyle(style))
    return t


def footer(canv, doc):
    canv.saveState()
    canv.setFont('STSong-Light', 8)
    canv.drawCentredString(A4[0] / 2, 1.6 * cm, f'— {doc.page} —')
    canv.restoreState()


def main():
    story = []
    story.append(Paragraph(TITLE, S_title))
    story.append(Paragraph(META[0], S_author))
    story.append(Paragraph(META[1], S_meta))
    for m in META[2:]:
        story.append(Paragraph(m, S_meta))
    story.append(Spacer(1, 4))
    story.append(Paragraph(ABSTRACT, S_body))
    story.append(Spacer(1, 4))
    story.append(Paragraph(KEYWORDS, S_body))
    for kind, val in BLOCKS:
        if kind == 'h1':
            story.append(Paragraph(val, S_h1))
        elif kind == 'h2':
            story.append(Paragraph(val, S_h2))
        elif kind == 'p':
            story.append(Paragraph(val, S_body))
        elif kind == 'eq':
            story.append(Paragraph(val, S_eq))
        elif kind == 'li':
            story.append(Paragraph(val, S_list))
        elif kind == 'table1':
            story.append(Paragraph('表 1　专家段基准台账（冷启动 2026-08）', S_cap))
            story.append(build_table())
    story.append(Paragraph('参考文献', S_h1))
    story += REFP

    doc = BaseDocTemplate(
        OUT, pagesize=A4,
        leftMargin=2.4 * cm, rightMargin=2.4 * cm,
        topMargin=2.6 * cm, bottomMargin=2.6 * cm,
        title=TITLE, author='作者姓名')
    frame = Frame(doc.leftMargin, doc.bottomMargin,
                  doc.width, doc.height, id='f1')
    doc.addPageTemplates([PageTemplate(id='main', frames=[frame], onPage=footer)])
    doc.build(story)
    print('written:', OUT)


if __name__ == '__main__':
    main()