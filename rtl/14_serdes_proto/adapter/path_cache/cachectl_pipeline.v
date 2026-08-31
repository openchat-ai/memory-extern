// ============================================================================
// cachectl_pipeline.v — 缓存控制器(做实): 路径探测 + 统一权重流 + 专家LRU目录
//
// 把三条已验证的机制串成端到端缓存管线:
//   links_detect (路径自动识别+锁定)
//     -> path_mux   (按锁定路径选通源桩字流)
//     -> expert_dir (专家 LRU 目录: trunk 驻留 + 专家命中/替换/动态更新)
//     -> GEMV       (统一权重流 wt_valid/wt_data/wt_ready, 无感知)
//
// 字流格式: 外部桩每字 = [7:0]=expert_id(tag), [31:8]=权重(简化单字)。
//   访问 tag -> expert_dir 命中则出目录权重; 未命中则本字作为 load 装入 LRU 槽
//   (冷首访 = 装入即出), 后续命中直接出。
//   命令通道 CMD_UPDATE_EXPERT 更新某专家权重(动态更新)。
//
// TRUNK: trunk_id 对应专家永不替换, 恒命中(目录槽0)。
//
// 文件->LBA 接口(file2lba): 真机落地用。每字 tag 视为"文件逻辑块号", 当拍
//   组合给出对应物理 LBA(分区起始+extent 表)伴随在 wt_lba 上, 供 NVMe 读引擎
//   按地址读盘。CMD_CFG_LBA(0x50) 帧共用命令流配置 extent 表。
// ============================================================================

`timescale 1ns/1ps

module cachectl_pipeline #(
    parameter DW              = 32,
    parameter CW              = 32,
    parameter EXPERT_SLOTS    = 8,          // 目录总槽 = 1(trunk)+专家
    parameter CMD_UPDATE_EXPERT = 8'h40,
    parameter FILE_BLKW       = 8,          // 文件逻辑块号位宽(每字 tag 宽度)
    parameter FILE_IDW        = 4,          // 文件句柄位宽
    parameter FILES_N         = 4,          // 文件目录条目数
    parameter FILE_ID         = 0,          // 本流使用的文件句柄(单一缓存文件场景)
    parameter CMD_CFG_LBA     = 8'h50
)(
    input  wire clk,
    input  wire rst_n,

    // ---- 两路就绪 ----
    input  wire serdes_aligned,
    input  wire pcie_link_up,

    // ---- 路径1 源桩字流(A: 本地 SSD) ----
    input  wire [DW-1:0]  st_in_a_data,
    input  wire           st_in_a_valid,
    output wire           st_in_a_ready,

    // ---- 路径2 源桩字流(B: 主机 PCIe) ----
    input  wire [DW-1:0]  st_in_b_data,
    input  wire           st_in_b_valid,
    output wire           st_in_b_ready,

    // ---- 命令通道(来源可切) ----
    input  wire [CW-1:0]  cmd_a_data, input wire cmd_a_valid, output wire cmd_a_ready,
    input  wire [CW-1:0]  cmd_b_data, input wire cmd_b_valid, output wire cmd_b_ready,

    // ---- 统一权重流 -> GEMV ----
    output wire [DW-1:0]  wt_data,
    output wire           wt_valid,
    input  wire           wt_ready,

    // ---- 文件->LBA (真机按地址读盘; 与 wt 流同拍) ----
    output wire [47:0]    wt_lba,
    output wire           lba_fault,

    // ---- 状态 ----
    output wire           path_locked,
    output wire           path_sel,
    output reg  [31:0]    loads,          // 装入(冷首访/替换)次数
    output reg  [31:0]    hits,           // 目录命中次数
    output reg  [31:0]    misses,         // 冷首访次数
    output reg  [31:0]    trun_hits,      // trunk 命中
    output reg  [7:0]     trunk_id_out
);

    wire sel, locked;
    links_detect u_detect (
        .clk(clk), .rst_n(rst_n),
        .align_a(serdes_aligned), .link_b(pcie_link_up),
        .sel(sel), .locked(locked), .valid_a(), .valid_b()
    );

    // 选通后的源字流
    wire [DW-1:0] src_data;
    wire          src_valid;
    wire          src_ready;
    wire a_ready, b_ready;
    path_mux #(.DW(DW)) u_mux (
        .clk(clk), .rst_n(rst_n),
        .sel(sel), .locked(locked),
        .wtd_a(st_in_a_data), .wtv_a(st_in_a_valid), .wtr_a(a_ready),
        .wtd_b(st_in_b_data), .wtv_b(st_in_b_valid), .wtr_b(b_ready),
        .wt_valid(src_valid), .wt_data(src_data), .wt_ready_gnv(src_ready)
    );
    assign st_in_a_ready = a_ready;
    assign st_in_b_ready = b_ready;

    // 每字 tag = [7:0]
    wire [7:0] req_tag = src_data[7:0];

    // trunk 配置: 保留专家 id=0 作 trunk(永久驻留, 恒在)
    wire [7:0]   trunk_id   = 8'd0;
    wire [DW-1:0] trunk_data = 32'h0A0A0A0A;

    // ---- expert_dir 目录 ----
    wire req_hit, req_is_trunk;
    wire [7:0] req_way;
    wire [DW-1:0] req_data;

    wire miss = src_valid & ~req_hit & ~req_is_trunk;   // 冷首访(未命中专家)

    // 每词单拍完成:
    //   trunk  -> 恒出 trunk 权重
    //   命中    -> 出目录权重(req_data)
    //   未命中  -> 冷首访: 出源桩原字(src_data), 同拍自动装入目录(load)
    expert_dir #(.DW(DW), .EXPERT_SLOTS(EXPERT_SLOTS)) u_dir (
        .clk(clk), .rst_n(rst_n),
        .trunk_id(trunk_id), .trunk_data(trunk_data),
        .req_valid(src_valid),
        .req_tag(req_tag),
        .req_hit(req_hit), .req_way(req_way), .req_data(req_data), .req_is_trunk(req_is_trunk),
        .load_valid(miss),                 // 冷首访自动装入(该专家首份权重)
        .load_way(req_way),
        .load_tag(req_tag),
        .load_data(src_data),
        .upd_valid(upd_valid), .upd_id(upd_id), .upd_data(upd_data)
    );

    // 统一出口: 单拍直通; 全程无需恢复拍, 无 valid 多拍重复
    assign wt_valid = src_valid & src_ready;
    assign wt_data  = req_is_trunk ? trunk_data : (req_hit ? req_data : src_data);
    assign src_ready = wt_ready & locked;

    // ---- 文件->LBA 接口: 每字 tag 即文件内逻辑块号, 组合给物理 LBA ----
    // 文件句柄 req_file 由参数 FILE_ID 指定(单一缓存文件场景; 多文件可由上层
    // 其它字段扩展)。FILES/FILE_IDW 交由 file2lba 参数按需配置。
    wire [47:0] cur_lba;
    wire        cur_fault;
    wire [FILE_BLKW-1:0] blk_no = src_data[FILE_BLKW-1:0];
    file2lba #(.BLKW(FILE_BLKW), .FILES(FILES_N), .FILE_IDW(FILE_IDW)) u_f2l (
        .clk(clk), .rst_n(rst_n),
        .cmd_data(cmd_any_data), .cmd_valid(cmd_any_valid), .cmd_ready(),
        .req_file(FILE_ID),
        .req_blk(blk_no),
        .phys_lba(cur_lba), .lba_fault(cur_fault)
    );
    assign wt_lba    = cur_lba;
    assign lba_fault = cur_fault;

    // ---- 命令: CMD_UPDATE_EXPERT 动态更新(来源可切) ----
    reg [1:0] cmd_state;
    reg [7:0] saved_cmd;
    reg       upd_valid;
    reg [7:0] upd_id;
    reg [DW-1:0] upd_data;
    localparam CS_IDLE=0, CS_HDR=1;

    wire cmd_any_valid = cmd_a_valid | cmd_b_valid;
    wire [CW-1:0] cmd_any_data = cmd_a_valid ? cmd_a_data : cmd_b_data;

    assign cmd_a_ready = 1'b1;
    assign cmd_b_ready = 1'b1;

    always @(posedge clk) begin
        if (!rst_n) begin
            cmd_state <= CS_IDLE; saved_cmd <= 0;
            upd_valid <= 0; upd_id <= 0; upd_data <= 0;
            loads <= 0; hits <= 0; misses <= 0; trun_hits <= 0;
        end else begin
            upd_valid <= 0;
            case (cmd_state)
                CS_IDLE: if (cmd_any_valid) begin
                    saved_cmd <= cmd_any_data[7:0];
                    cmd_state <= CS_HDR;
                end
                CS_HDR: begin
                    if (cmd_any_valid && saved_cmd == CMD_UPDATE_EXPERT) begin
                        upd_id   <= cmd_any_data[7:0];
                        upd_data <= cmd_any_data;
                        upd_valid<= 1;
                    end
                    cmd_state <= CS_IDLE;
                end
            endcase

            // 目录访问统计: 每字单拍(valid 高 1 拍), 直接逐拍计数。
            //   trunk   -> 恒命中 trunk
            //   命中    -> 重访命中
            //   未命中  -> 冷首访(同拍已装入 => miss+load)
            if (src_valid) begin
                if (req_is_trunk)
                    trun_hits <= trun_hits + 1;
                else if (req_hit)
                    hits <= hits + 1;
                else begin
                    misses <= misses + 1;
                    loads  <= loads + 1;
                end
            end
        end
    end

    assign path_locked = locked;
    assign path_sel    = sel;
    assign trunk_id_out = trunk_id;

endmodule
