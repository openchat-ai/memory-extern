#!/usr/bin/env python3
"""Generate correct Verilog stubs for Wavious wphy_* analog IP."""
import re, os

WAVDIR = "rtl/07_phy_wavious/rtl"

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
    ("mvp_pll/mvp_pll_dig.v", "mvp_pll_dig"),
]


def flatten_ifdef(text):
    """Remove ALL preprocessor directives, keep ALL content lines (union of branches)."""
    result = []
    for line in text.split('\n'):
        s = line.strip()
        if s.startswith('`'):
            continue
        result.append(line)
    return '\n'.join(result)


def extract_ports(filepath, modname):
    with open(filepath) as f:
        content = f.read()

    pattern = rf'^module\s+{re.escape(modname)}'
    match = re.search(pattern, content, re.MULTILINE)
    if not match:
        return None, None

    paren_start = content.find('(', match.start())
    depth = 0
    end = paren_start
    for i in range(paren_start, min(paren_start + 8000, len(content))):
        if content[i] == '(':
            depth += 1
        elif content[i] == ')':
            depth -= 1
            if depth == 0:
                end = i
                break

    port_text = content[paren_start + 1:end]
    flat = flatten_ifdef(port_text)

    # Check ANSI style
    if re.search(r'\b(input|output|inout)\s', flat):
        return parse_ansi(flat), None

    # Non-ANSI: get port names
    names = []
    for tok in flat.split(','):
        tok = re.sub(r'//.*$', '', tok).strip().strip(';').strip()
        tok = re.sub(r'\s+', ' ', tok)
        # Remove inline comments and ifdef remnants
        if re.match(r'^[a-zA-Z_]\w*$', tok):
            names.append(tok)

    # Get body for direction/width
    body_start = content.find(');', end)
    if body_start < 0:
        body_start = end
    else:
        body_start += 2

    endmod = content.find('endmodule', body_start)
    if endmod < 0:
        endmod = len(content)
    body = content[body_start:endmod]

    # Flatten ifdef in body too
    body = flatten_ifdef(body)

    info = {}
    for line in body.split('\n'):
        line = line.strip()
        for pat in [
            r'(input|output|inout)\s+wire\s+(\[[^\]]+\]\s+)(\w+)',
            r'(input|output|inout)\s+wire\s+(\w+)\s*[;,]',
            r'(input|output|inout)\s+(\[[^\]]+\]\s+)(\w+)',
            r'(input|output|inout)\s+(\w+)\s*[;,]',
        ]:
            m = re.match(pat, line)
            if m:
                groups = m.groups()
                if len(groups) == 4:
                    d, w, n = groups[0], groups[1], groups[2]
                else:
                    d, w, n = groups[0], '', groups[1]
                w = w.strip() + ' ' if w.strip() else ''
                if n not in info:
                    info[n] = (d, w)

    ports = []
    for n in names:
        if n in info:
            ports.append((info[n][0], info[n][1], n))
        else:
            ports.append(('input', '', n))
    return ports, names


def parse_ansi(flat):
    ports = []
    for line in flat.split('\n'):
        line = line.strip().rstrip(',')
        if not line or line.startswith('//'):
            continue
        # Try: direction [optional wire/logic] [width] name
        m = re.match(
            r'(input|output|inout)\s+(?:wire\s+|logic\s+)?(\[[^\]]+\]\s*)?([a-zA-Z_]\w*)',
            line)
        if m:
            d, w, n = m.group(1), m.group(2) or '', m.group(3)
            w = w.strip() + ' ' if w.strip() else ''
            ports.append((d, w, n))
    return ports


def gen_stub(modname, ports):
    lines = [f"module {modname} ("]
    pdecls = []
    pnames = []
    for d, w, n in ports:
        pdecls.append(f"    {d} {w}{n}")
        pnames.append(n)
    lines.append(",\n".join(pdecls))
    lines.append(");")
    for d, w, n in ports:
        if d == 'output':
            lines.append(f"    assign {n} = '0;")
    lines.append("endmodule")
    return "\n".join(lines)


def main():
    lines = [
        "// ============================================================================",
        "// Wavious WDDR PHY - Behavioral Stubs for Analog/Mixed-Signal IP",
        "// Port lists extracted from original RTL (rtl/07_phy_wavious/rtl/)",
        "// Apache 2.0 License (Wavious LLC)",
        "// ============================================================================",
        "`timescale 1ps/1ps",
        "",
    ]

    for fp, mn in MODULES:
        fullpath = os.path.join(WAVDIR, fp)
        if not os.path.exists(fullpath):
            print(f"SKIP: {mn} ({fullpath} not found)")
            continue
        ports, _ = extract_ports(fullpath, mn)
        if ports is None:
            print(f"FAIL: {mn}")
            continue
        print(f"OK: {mn} ({len(ports)} ports)")
        lines.append(f"// {modname if False else mn}")
        lines.append(gen_stub(mn, ports))
        lines.append("")

    outpath = "rtl/10_phy_final/wphy_stubs/wphy_all_stubs.v"
    with open(outpath, 'w') as f:
        f.write("\n".join(lines))
    print(f"\nWritten {outpath}")


if __name__ == "__main__":
    main()
