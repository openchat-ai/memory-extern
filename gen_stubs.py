#!/usr/bin/env python3
"""Generate Verilog stubs for Wavious wphy_* analog IP blocks.
Port lists extracted from original RTL in rtl/07_phy_wavious/rtl/.
"""

import re, os

WAVDIR = "rtl/07_phy_wavious/rtl"

# Map: (filename, top_module_name)
MODULES = [
    ("custom_ip/wphy_2to1_14g_rvt.sv", "wphy_2to1_14g_rvt"),
    ("custom_ip/wphy_cgc_diff_lvt.sv", "wphy_cgc_diff_lvt"),
    ("custom_ip/wphy_cgc_diff_rh_lvt.sv", "wphy_cgc_diff_rh_lvt"),
    ("custom_ip/wphy_cgc_diff_rh_svt.sv", "wphy_cgc_diff_rh_svt"),
    ("custom_ip/wphy_cgc_diff_svt.sv", "wphy_cgc_diff_svt"),
    ("custom_ip/wphy_clk_div_2ph_4g_dlymatch_lvt.sv", "wphy_clk_div_2ph_4g_dlymatch_lvt"),
    ("custom_ip/wphy_clk_div_2ph_4g_dlymatch_svt.sv", "wphy_clk_div_2ph_4g_dlymatch_svt"),
    ("custom_ip/wphy_clk_div_2ph_4g_lvt.sv", "wphy_clk_div_2ph_4g_lvt"),
    ("custom_ip/wphy_clk_div_2ph_4g_svt.sv", "wphy_clk_div_2ph_4g_svt"),
    ("custom_ip/wphy_clk_div_4ph_10g_dlymatch_svt.sv", "wphy_clk_div_4ph_10g_dlymatch_svt"),
    ("custom_ip/wphy_clk_div_4ph_10g_svt.sv", "wphy_clk_div_4ph_10g_svt"),
    ("custom_ip/wphy_clkmux_3to1_diff.sv", "wphy_clkmux_3to1_diff"),
    ("custom_ip/wphy_clkmux_3to1_diff_slvt.sv", "wphy_clkmux_3to1_diff_slvt"),
    ("custom_ip/wphy_clkmux_diff.sv", "wphy_clkmux_diff"),
    ("custom_ip/wphy_gfcm_lvt.sv", "wphy_gfcm_lvt"),
    ("custom_ip/wphy_gfcm_svt.sv", "wphy_gfcm_svt"),
    ("custom_ip/wphy_pi_4g.sv", "wphy_pi_4g"),
    ("custom_ip/wphy_pi_dly_match_4g.sv", "wphy_pi_dly_match_4g"),
    ("custom_ip/wphy_prog_dly_se_4g.sv", "wphy_prog_dly_se_4g"),
    ("custom_ip/wphy_prog_dly_se_4g_small.sv", "wphy_prog_dly_se_4g_small"),
    ("custom_ip/wphy_sa_4g_2ph_pdly_no_esd.sv", "wphy_sa_4g_2ph_pdly_no_esd"),
    ("ddr_ip/wphy_lp4x5_cke_drvr_w_lpbk.sv", "wphy_lp4x5_cke_drvr_w_lpbk"),
    ("ddr_ip/wphy_lp4x5_cmn.sv", "wphy_lp4x5_cmn"),
    ("ddr_ip/wphy_lp4x5_cmn_clks_svt.sv", "wphy_lp4x5_cmn_clks_svt"),
    ("ddr_ip/wphy_lp4x5_dq_drvr_w_lpbk.sv", "wphy_lp4x5_dq_drvr_w_lpbk"),
    ("ddr_ip/wphy_lp4x5_dqs_drvr_w_lpbk.sv", "wphy_lp4x5_dqs_drvr_w_lpbk"),
    ("ddr_ip/wphy_lp4x5_dqs_rcvr_no_esd.sv", "wphy_lp4x5_dqs_rcvr_no_esd"),
    ("mvppll_ip/wphy_rpll_mvp_4g.sv", "wphy_rpll_mvp_4g"),
    # Non-wphy modules also needed
    ("../mvp_pll/mvp_pll_dig.v", "mvp_pll_dig"),
    ("../jtag/wav_jtag_lib.sv", "wav_jtag_reg"),
    ("../jtag/wav_jtag_lib.sv", "wav_jtag_top"),
    ("../ahb/wav_ahb.sv", "wav_ahb_slave_mux"),
]


def extract_ports(filepath, modname):
    """Extract port list from module declaration in file."""
    with open(filepath) as f:
        content = f.read()

    # Find the module declaration
    pattern = rf'^module\s+{re.escape(modname)}\s*[\(#]'
    match = re.search(pattern, content, re.MULTILINE)
    if not match:
        return None

    # Extract from module line to );
    start = match.start()
    paren_depth = 0
    found_open = False
    end = start
    for i in range(start, min(start + 5000, len(content))):
        c = content[i]
        if c == '(':
            paren_depth += 1
            found_open = True
        elif c == ')':
            paren_depth -= 1
            if found_open and paren_depth == 0:
                end = i + 1
                break

    port_block = content[start:end]

    # Check if ANSI style (has direction keywords in port list)
    if re.search(r'\b(input|output|inout)\s', port_block):
        return extract_ansi_ports(port_block, modname)
    else:
        # Non-ANSI: extract names from port list, then find directions in body
        return extract_nonansi_ports(content, port_block, modname)


def extract_ansi_ports(block, modname):
    """Extract from ANSI-style module declaration."""
    # Remove ifdef blocks
    block = re.sub(r'`ifdef.*?`endif', '', block, flags=re.DOTALL)
    block = re.sub(r'`else', '', block)
    block = re.sub(r',\s*,', ',', block)

    # Find port list between ( and )
    m = re.search(r'\((.*)\)', block, re.DOTALL)
    if not m:
        return None
    port_str = m.group(1)

    ports = []
    for line in port_str.split('\n'):
        line = line.strip().rstrip(',')
        if not line or line.startswith('//') or line.startswith('`'):
            continue

        # Parse direction and names
        m_dir = re.match(r'(input|output|inout)\s+(wire\s+)?(logic\s+)?(\[.*?\]\s*)?(.*)', line)
        if m_dir:
            direction = m_dir.group(1)
            width = m_dir.group(4) or ''
            names_str = m_dir.group(5).strip().rstrip(';')
            names = [n.strip() for n in names_str.split(',') if n.strip()]
            for name in names:
                # Skip if contains special characters (ifdef artifacts)
                if re.match(r'^[a-zA-Z_]\w*$', name):
                    ports.append((direction, width, name))

    return ports


def extract_nonansi_ports(content, block, modname):
    """Extract from non-ANSI module declaration."""
    # Get port names from declaration
    m = re.search(r'^module\s+' + re.escape(modname) + r'\s*\((.*?)\)', block, re.DOTALL)
    if not m:
        return None

    port_names_raw = m.group(1)
    # Remove ifdef blocks
    port_names_raw = re.sub(r'`ifdef.*?`endif', '', port_names_raw, flags=re.DOTALL)
    port_names_raw = re.sub(r'`else', '', port_names_raw)
    port_names_raw = re.sub(r',\s*,', ',', port_names_raw)

    port_names = []
    for name in port_names_raw.split(','):
        name = name.strip()
        if name and re.match(r'^[a-zA-Z_]\w*$', name):
            port_names.append(name)

    # Find direction declarations in module body (after endmodule of port decl or after module line)
    body_start = block.find(');')
    if body_start < 0:
        body_start = 0
    else:
        body_start += 2

    body = content[body_start:body_start + 3000]

    port_info = {}
    for line in body.split('\n'):
        line = line.strip()
        m_dir = re.match(r'(input|output|inout)\s+(wire\s+)?(logic\s+)?(\[.*?\]\s*)(.*?);', line)
        if m_dir:
            direction = m_dir.group(1)
            width = m_dir.group(4) or ''
            names = [n.strip() for n in m_dir.group(5).split(',') if n.strip()]
            for name in names:
                if name in port_names:
                    port_info[name] = (direction, width)

        # Also match without width
        m_dir2 = re.match(r'(input|output|inout)\s+(wire\s+)?(logic\s+)?(\w+)\s*[;,]', line)
        if m_dir2:
            direction = m_dir2.group(1)
            name = m_dir2.group(4)
            if name in port_names and name not in port_info:
                port_info[name] = (direction, '')

    # For ports with parameters, check parameter list
    param_block = content[:content.find(')')]
    # wav_jtag_reg and wav_jtag_top have parameterized ports

    ports = []
    for name in port_names:
        if name in port_info:
            d, w = port_info[name]
            ports.append((d, w, name))
        else:
            # Default to input if not found
            ports.append(('input', '', name))

    return ports


def gen_stub(modname, ports):
    """Generate a Verilog stub module."""
    lines = []
    lines.append(f"module {modname} (")

    port_decls = []
    port_names = []
    for direction, width, name in ports:
        port_decls.append(f"    {direction} {width}{name}")
        port_names.append(name)

    lines.append(",\n".join(port_decls))
    lines.append(");")

    # Behavioral: tie outputs to 0
    for direction, width, name in ports:
        if direction == 'output':
            if width and '[' in width:
                lines.append(f"    assign {name} = '0;")
            else:
                lines.append(f"    assign {name} = 1'b0;")

    lines.append("endmodule")
    return "\n".join(lines)


def main():
    lines = []
    lines.append("// ============================================================================")
    lines.append("// Wavious WDDR PHY — Behavioral Stubs for Analog/Mixed-Signal IP")
    lines.append("// Port lists extracted from original RTL (rtl/07_phy_wavious/rtl/)")
    lines.append("// Apache 2.0 License (Wavious LLC)")
    lines.append("// ============================================================================")
    lines.append("`timescale 1ps/1ps")
    lines.append("")

    success = 0
    failed = 0

    for filepath, modname in MODULES:
        fullpath = os.path.join(WAVDIR, filepath)
        if not os.path.exists(fullpath):
            print(f"SKIP (not found): {modname} <- {fullpath}")
            failed += 1
            continue

        ports = extract_ports(fullpath, modname)
        if ports is None:
            print(f"FAIL (no module): {modname} <- {fullpath}")
            failed += 1
            continue

        stub = gen_stub(modname, ports)
        lines.append(f"// {modname}")
        lines.append(stub)
        lines.append("")
        success += 1
        print(f"OK: {modname} ({len(ports)} ports)")

    # Also copy from original sources for modules that need real behavior
    # wav_ahb_slave_mux has complex parameterization - use original
    # wav_jtag_reg has parameterization - use original
    # wav_jtag_top has parameterization - use original

    outpath = "rtl/10_phy_final/wphy_stubs/wphy_all_stubs.v"
    with open(outpath, 'w') as f:
        f.write("\n".join(lines))

    print(f"\nDone: {success} OK, {failed} FAILED")
    print(f"Written to {outpath}")


if __name__ == "__main__":
    main()
