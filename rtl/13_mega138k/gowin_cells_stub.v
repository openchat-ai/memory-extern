// ============================================================================
// gowin_cells_stub.v — 仅供 Verilator lint 使用
//
// 真实综合时由高云 IDE 的原语库提供这些模块，
// 本文件必须从 Gowin 工程的源文件列表中排除！
// ============================================================================

`timescale 1ns/1ps

// 差分输入缓冲（LVDS）
module TLVDS_IBUF (
    input  wire I,
    output wire O
);
    assign O = I;
endmodule
