// ============================================================================
// file2lba.v — 文件→LBA 映射接口层(真机落地: ext4 缓存文件块级寻址)
//
// 背景: 缓存磁盘(SSD)多分区, 缓存文件落在"最大的 ext4 分区"里。RTL 缓存
//   控制器只能按磁盘 LBA 读块; 而文件在文件系统中由若干连续区段(extent)
//   构成。本模块把"文件逻辑块号 → 物理 LBA"翻译做实, 供真机按地址读盘。
//
// 职责:
//   1. 存一张 extent 映射表(分区起始 LBA + 每段 base_lba + 段内块数),
//      host 侧工具解析分区/ext4 后经命令通道写入。
//   2. 查询: 给文件逻辑块号 -> 组合输出对应物理 LBA; 越界 -> lba_fault=1。
//
// 命令帧(与 cachectl 命令通道同款两拍帧, ready 恒 1, 可与其它命令共用流):
//   拍0 帧头 cmd[7:0]=CMD_CFG_LBA(0x50), 拍0 [15:8]=reg_addr
//   拍1 载荷 data[31:0]
//   寄存器映射(reg_addr):
//     0x00            PART_LBA[31:0]        分区起始物理 LBA 低 32
//     0x01*           PART_LBA[47:32]       高 16(默认 0; 大容量再配)
//     0x10+2k         EXT[k].base_lo        第 k 段 base_lba[31:0]
//     0x11+2k         EXT[k].base_hi        base_lba[47:32]
//     0x20+k          EXT[k].cnt            [15:0] 段内块数(逻辑连续)
//   * 0x01 等保留。ENTRYS 段按逻辑起点连续: 段0 从文件块0 起, 段 k 从
//     sum(前 k 段 cnt) 起。
//
// 查询(req_blk 任意时刻有效, 组合直出):
//   phys_lba = 所在段的 base_lba + (req_blk - 段逻辑起点)
//   lba_fault = 1  当 req_blk >= 文件总块数(sum(cnt)) 或未落入任何段
//
// 可综合(纯组合查询 + 简单 reg 阵列; 为方便 CS 分析分两个全块)。
// ============================================================================

`timescale 1ns/1ps

module file2lba #(
    parameter LBAW    = 48,       // 物理 LBA 位宽(分低32/高16两次配置)
    parameter BLKW    = 16,       // 文件逻辑块号位宽
    parameter ENTRYS  = 4,        // extent 段数
    parameter CMD_CFG_LBA = 8'h50 // 配置命令标识
)(
    input  wire                 clk,
    input  wire                 rst_n,

    // ---- 命令通道(两拍帧, 与 cachectl 共用声明, ready 恒 1) ----
    input  wire [31:0]          cmd_data,
    input  wire                 cmd_valid,
    output wire                 cmd_ready,

    // ---- 查询: 文件逻辑块号 --> 物理 LBA ----
    input  wire [BLKW-1:0]      req_blk,
    output wire [LBAW-1:0]      phys_lba,
    output wire                 lba_fault
);

    // ---- 配置寄存器 ----
    reg [31:0] part_lba_lo;         // 分区起始物理 LBA(低32)
    reg [15:0] part_lba_hi;         // 分区起始物理 LBA(高16)
    reg [31:0] ext_base_lo [0:ENTRYS-1];  // 每段 base_lba 低32
    reg [15:0] ext_base_hi [0:ENTRYS-1];  // 每段 base_lba 高16
    reg [15:0] ext_cnt    [0:ENTRYS-1];   // 每段块数

    // ---- 命令帧解码(两拍: 帧头 -> 载荷写寄存器) ----
    localparam CS_IDLE=0, CS_HDR=1;
    reg [1:0] fsm;
    reg [7:0] sav_reg;
    integer e;

    assign cmd_ready = 1'b1;

    always @(posedge clk) begin
        if (!rst_n) begin
            fsm <= CS_IDLE; sav_reg <= 0;
            part_lba_lo <= 0; part_lba_hi <= 0;
            for (e = 0; e < ENTRYS; e = e + 1) begin
                ext_base_lo[e] <= 0;
                ext_base_hi[e] <= 0;
                ext_cnt[e]     <= 0;
            end
        end else begin
            case (fsm)
                CS_IDLE: if (cmd_valid && cmd_data[7:0] == CMD_CFG_LBA) begin
                    sav_reg <= cmd_data[15:8];   // reg_addr
                    fsm     <= CS_HDR;
                end
                CS_HDR: begin
                    if (cmd_valid) begin
                        case (sav_reg)
                            8'h00:      part_lba_lo <= cmd_data;
                            8'h01:      part_lba_hi <= cmd_data[15:0];
                            default: begin
                                // 0x10+2k base_lo / 0x11+2k base_hi / 0x20+k cnt
                                for (e = 0; e < ENTRYS; e = e + 1) begin
                                    if (sav_reg == (8'h10 + 2*e))
                                        ext_base_lo[e] <= cmd_data;
                                    if (sav_reg == (8'h11 + 2*e))
                                        ext_base_hi[e] <= cmd_data[15:0];
                                    if (sav_reg == (8'h20 + e))
                                        ext_cnt[e] <= cmd_data[15:0];
                                end
                            end
                        endcase
                    end
                    fsm <= CS_IDLE;
                end
            endcase
        end
    end

    // ---- 组合查询 ----
    // ext base 存"分区内相对 LBA"(宿主工具解析 ext4 后写入)。真实物理 LBA =
    //   分区起始(part_lba) + 段 base + 段内偏移(req_blk - 段逻辑起点)。
    integer i;
    reg  [31:0]  acc;                 // 段逻辑起点累计(宽松, 与 BLKW/段数无关)
    reg  [31:0]  total;
    reg  [15:0]  off;
    reg  [LBAW-1:0] lba_out;
    reg             fault_out;
    reg             found;

    always @(*) begin
        total = 0;
        for (i = 0; i < ENTRYS; i = i + 1)
            total = total + ext_cnt[i];

        found = 1'b0;
        lba_out = 0;
        acc = 0;
        for (i = 0; i < ENTRYS; i = i + 1) begin
            if (!found && (req_blk >= acc) && (req_blk < acc + ext_cnt[i])) begin
                off     = req_blk - acc[BLKW-1:0];
                lba_out = {part_lba_hi, part_lba_lo} +
                          { {16{1'b0}}, ext_base_hi[i], ext_base_lo[i] } +
                          {16'b0, off};
                found = 1'b1;
            end
            acc = acc + ext_cnt[i];
        end
        fault_out = ~found | (req_blk >= total);
    end

    assign phys_lba = lba_out;
    assign lba_fault = fault_out;

endmodule