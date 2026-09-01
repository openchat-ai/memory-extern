#!/data/data/com.termux/files/usr/bin/bash
# ============================================================================
# sim.sh — 一键回归: SerDes 协议抽象层全部仿真
#   1. proto_core       L2 通用内核
#   2. axis_pcie        实例B (PCIe 风格适配器 + 内核)
#   3. custom_serdes    实例A (phy+framer 完整回环, 快乐路径 3 包)
#   4. crc_check        framer_rx CRC-16 检测能力(篡改注入)
#   5. varlen           可变每帧长度(4/16/64) 自适应负载 + CRC
#   6. phy_backpressure phy RX 背压(FIFO) 无丢失验证
#   7. crc16            CRC-16-CCITT 标准向量
#   8. multilane        多 lane 聚合(N_LANE=4), 字节轮流分发+聚合保序
#   9. multilane_e2e    多 lane 端到端(framer<->link 4lane<->framer) 3 帧
#  10. edge             边界扫描 8 组(N=1/2/4/8, BIT_DELAY, RX_DEPTH, 背压抖动)
#  11. load             满载边界:N=1/4/8/16/24 满灌, 零丢失+保序+速度边界 min(N/8,1)
#  12. sfp_load         SFP+/SerDes 高速档: 换 phy(serdes_phy_sfp) 不换协议层,
#                        N=1/4/8 满载零丢失保序 (验证可插拔接口适配器, 10G/背板)
#  13. gw_pcie_bridge   PCIe 20G 桥: gowin_pcie_ip <-> proto_core, 3 帧背压回程
#  14. path_cache       SSD 双路径(M.2本地/主机PCIe)自动识别+统一权重流+命令来源可切
#  15. expert_dir       专家 LRU 缓存目录: trunk 恒驻留 + LRU 替换 + 动态更新
#  16. cachectl_pipe    端到端: 探测+选通+专家LRU目录+GEMV(冷首访/重访/trunk/更新/主机)
#  17. file2lba         文件→LBA 映射: 多文件句柄(分区起始+全局extent表+文件目录+越界)
#  18. ext4_scan        RTL ext4 扫描: 阶段1 superblock+组0desc → 阶段2 根inode → 阶段3/4 目录rec_len枚举→结果表 → 阶段7 全文件收集 → 阶段9/10 索引多层递归下钻多叶 → 阶段12 索引块多路遍历(全部ei_leaf) → 阶段11 一级子目录递归 → 阶段13 跨多块 inode 表 → 阶段14 多 blk_groups 定位 → 阶段15 任意层级目录递归(目录栈) → 阶段16 查询闭环(qblk跨extent累积→绝对LBA) → 阶段17b(件2) 深度3 索引嵌套 DFS 节点栈(根→块60→块61→叶62/63) → 阶段17c(件3) 子目录文件跨 inode 表块收集(组0块4/组1块6) → 阶段8 落表RAM+查询FSM(合成镜像闭环)
#  19. cache_lba_top    cache_lba_top 端到端接线(阶段17/件1/件4): 例化 ext4_scan_core + cachectl_pipeline, reset 自动扫描→读 RAM 表→转录 FSM(件1 多文件全目录: 遍历所有 extent 按 ino 分组写 F[f].base/size + 全局 EXT[k])→file2lba 多文件目录→(件4) TIDLE 保持就绪, rescan 拉高触发重扫→管线按 file0=ino12 组合直出绝对物理 LBA(分区块号0→part+32/1→+33/2→越界fault) — 完整“扫描→多文件转录→查询→读地址”模块链路
#  20. nvme             NVMe host 阶段N1: admin握手+读写命令+队列背压 (V0 admin / V1 写 / V2 读 / V3 背压)
#  21. nvme_n23         NVMe 阶段N2/N3: 读数据→FIFO 背压收齐 + 写路径更新缓存闭环 (源→FIFO→host→设备自校验)
# 依赖: iverilog 12 (g2012). 全部 PASS 则 exit 0。
# ============================================================================
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP=/data/data/com.termux/files/usr/tmp
pass=0; fail=0

run() {
    local name="$1"; shift
    local out="$TMP/sim_$name.vvp"
    if ! iverilog -g2012 -o "$out" "$@" 2>"$TMP/iverr_$name.log"; then
        echo "[$name] COMPILE FAIL"; cat "$TMP/iverr_$name.log"; fail=$((fail+1)); return
    fi
    local vlog
    vlog=$(timeout 40 vvp "$out" 2>&1)
    local rc=$?
    if [ $rc -ne 0 ]; then
        echo "[$name] RUN TIMEOUT/ERR rc=$rc"; echo "$vlog" | tail -3; fail=$((fail+1))
    elif echo "$vlog" | grep -qE "\bPASS\b"; then
        echo "[$name] PASS"; echo "$vlog" | grep -E "\bPASS\b" | head -1; pass=$((pass+1))
    else
        echo "[$name] FAIL (no PASS)"; echo "$vlog" | tail -5; fail=$((fail+1))
    fi
}

cd "$DIR"

echo "=== SerDes 协议抽象层仿真回归 ==="

run proto_core \
    tb/tb_proto_core.v core/proto_core.v

run axis_pcie \
    adapter/axis_pcie/tb_axis_pcie.v adapter/axis_pcie/axis_pcie_adapter.v core/proto_core.v

run custom_serdes \
    adapter/custom_serdes/tb_custom_serdes.v \
    adapter/custom_serdes/serdes_framer_tx.v adapter/custom_serdes/serdes_framer_rx.v \
    adapter/custom_serdes/serdes_phy.v adapter/custom_serdes/crc16.v

run crc_check \
    adapter/custom_serdes/tb_crc_check.v adapter/custom_serdes/serdes_framer_rx.v adapter/custom_serdes/crc16.v

run varlen \
    adapter/custom_serdes/tb_varlen.v \
    adapter/custom_serdes/serdes_framer_tx.v adapter/custom_serdes/serdes_framer_rx.v \
    adapter/custom_serdes/serdes_phy.v adapter/custom_serdes/crc16.v

run phy_rx_backpressure \
    adapter/custom_serdes/tb_phy_rx_backpressure.v adapter/custom_serdes/serdes_phy.v

run crc16 \
    adapter/custom_serdes/tb_crc16.v adapter/custom_serdes/crc16.v

run multilane \
    adapter/custom_serdes/tb_link.v \
    adapter/custom_serdes/serdes_link.v adapter/custom_serdes/serdes_phy.v

run multilane_e2e \
    adapter/custom_serdes/tb_link_serdes.v \
    adapter/custom_serdes/serdes_framer_tx.v adapter/custom_serdes/serdes_framer_rx.v \
    adapter/custom_serdes/serdes_link.v adapter/custom_serdes/serdes_phy.v adapter/custom_serdes/crc16.v

run edge \
    adapter/custom_serdes/tb_edge.v \
    adapter/custom_serdes/serdes_link.v adapter/custom_serdes/serdes_phy.v

run load \
    adapter/custom_serdes/tb_load.v \
    adapter/custom_serdes/serdes_link.v adapter/custom_serdes/serdes_phy.v

run sfp_load \
    adapter/sfp_serdes/tb_sfp_load.v \
    adapter/custom_serdes/serdes_link.v adapter/custom_serdes/serdes_phy.v \
    adapter/sfp_serdes/serdes_phy_sfp.v

run gw_pcie_bridge \
    adapter/axis_pcie/tb_gw_pcie_bridge.v adapter/axis_pcie/gw_pcie_bridge.v core/proto_core.v

run path_cache \
    adapter/path_cache/tb_path_cache.v \
    adapter/path_cache/cachectl_top.v adapter/path_cache/links_detect.v adapter/path_cache/path_mux.v

run expert_dir \
    adapter/path_cache/tb_expert_dir.v adapter/path_cache/expert_dir.v

run cachectl_pipe \
    adapter/path_cache/tb_cachectl_pipeline.v \
    adapter/path_cache/cachectl_pipeline.v adapter/path_cache/links_detect.v \
    adapter/path_cache/path_mux.v adapter/path_cache/expert_dir.v adapter/path_cache/file2lba.v

run file2lba \
    adapter/path_cache/tb_file2lba.v adapter/path_cache/file2lba.v

run ext4_scan \
    adapter/path_cache/tb_ext4_scan.v adapter/path_cache/ext4_scan_core.v

run cache_lba_top \
    adapter/path_cache/tb_cache_lba.v adapter/path_cache/cache_lba_top.v \
    adapter/path_cache/ext4_scan_core.v adapter/path_cache/cachectl_pipeline.v \
    adapter/path_cache/links_detect.v adapter/path_cache/path_mux.v \
    adapter/path_cache/expert_dir.v adapter/path_cache/file2lba.v

run nvme \
    adapter/nvme/tb_nvme.v adapter/nvme/nvme_host.v adapter/nvme/nvme_device_model.v

run nvme_n23 \
    adapter/nvme/tb_nvme_n23.v adapter/nvme/nvme_host.v \
    adapter/nvme/nvme_data_fifo.v adapter/nvme/nvme_device_model.v

echo "------------------------------------------"
echo "结果: PASS=$pass FAIL=$fail"
[ $fail -eq 0 ] && echo "ALL GREEN" && exit 0
echo "HAS FAILURE"; exit 1
