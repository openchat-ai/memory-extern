#!/usr/bin/env python3
"""Extract exact port info from Wavious .sv files - v3 with robust body parser."""
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
    ("jtag/wav_jtag_lib.sv", "wav_jtag_reg"),
    ("jtag/wav_jtag_lib.sv", "wav_jtag_top"),
    ("ahb/wav_ahb.sv", "wav_ahb_slave_mux"),
]


def strip_directives(text):
    """Remove all preprocessor directives, keep all content."""
    return '\n'.join(l for l in text.split('\n') if not l.strip().startswith('`'))


def parse_body_decls(body_flat):
    """Parse ALL direction declarations from flattened body.
    Handles: output foo, bar, baz;  input [2:0] foo;  inout vdd, vss;
    Joins continuation lines, splits on commas."""
    info = {}
    for line in body_flat.split('\n'):
        line = line.strip()
        # Match direction declarations
        m = re.match(
            r'(input|output|inout)\s+(?:wire\s+)?(?:logic\s+)?(.+)',
            line)
        if m:
            direction = m.group(1)
            rest = m.group(2).rstrip(';').strip()
            # Extract [width] if present
            width = ''
            wm = re.match(r'(\[\d+:\d+\]\s*)', rest)
            if wm:
                width = wm.group(1)
                rest = rest[wm.end():]
            # Split on comma for multi-port declarations
            for name in rest.split(','):
                name = name.strip()
                # Remove inline bus refs like [2:0] from names
                name = re.sub(r'\[.*?\]', '', name).strip()
                if re.match(r'^[a-zA-Z_]\w*$', name) and name not in info:
                    info[name] = (direction, width)
    return info


def extract_one(filepath, modname):
    with open(filepath) as f:
        content = f.read()

    # Find exact module match
    found = False
    for m in re.finditer(
            r'^module\s+' + re.escape(modname) + r'\s*[\(#]',
            content, re.MULTILINE):
        # Verify it's exact (not prefix match)
        after = content[m.end() - 1:m.end() + 50]
        if after[0] in '(#' or after.startswith(' (') or after.startswith(' #'):
            start = m.start()
            found = True
            break
    if not found:
        return None

    # Find port list
    paren = content.find('(', start)
    d = 0
    end = paren
    for i in range(paren, min(paren + 16000, len(content))):
        if content[i] == '(':
            d += 1
        elif content[i] == ')':
            d -= 1
            if d == 0:
                end = i
                break

    port_text = content[paren + 1:end]
    flat_ports = strip_directives(port_text)

    # ANSI style?
    if re.search(r'\b(input|output|inout)\s', flat_ports):
        # Parse ANSI-style: direction [wire/logic] [width] name
        ports = []
        for line in flat_ports.split('\n'):
            line = line.strip().rstrip(',')
            if not line or line.startswith('//'):
                continue
            m = re.match(
                r'(input|output|inout)\s+(?:wire\s+|logic\s+)?(\[[^\]]+\]\s*)?([a-zA-Z_]\w*)',
                line)
            if m:
                d_str, w, n = m.group(1), m.group(2) or '', m.group(3)
                w = w.strip() + ' ' if w.strip() else ''
                ports.append((d_str, w, n))
        return ports

    # Non-ANSI: get port names from list
    names = []
    for tok in flat_ports.split(','):
        tok = re.sub(r'//.*$', '', tok).strip().strip(';').strip()
        tok = re.sub(r'\s+', ' ', tok)
        if re.match(r'^[a-zA-Z_]\w*$', tok):
            names.append(tok)

    # Get body between port-list close and first endmodule of THIS module
    body_start = content.find(');', end) + 2
    # Find endmodule at depth 0
    depth = 0
    pos = body_start
    endmod = len(content)
    while pos < len(content):
        if content[pos:pos + 7] == 'module ':
            depth += 1
        if content[pos:pos + 9] == 'endmodule':
            if depth == 0:
                endmod = pos
                break
            depth -= 1
        pos += 1

    body = content[body_start:endmod]
    body_flat = strip_directives(body)
    info = parse_body_decls(body_flat)

    ports = []
    for n in names:
        if n in info:
            d_str, w = info[n]
            ports.append((d_str, w, n))
        else:
            ports.append(('input', '', n))
    return ports


def gen_stub(modname, ports):
    lines = [f"module {modname} ("]
    pdecls = []
    for d, w, n in ports:
        pdecls.append(f"    {d} {w}{n}")
    lines.append(",\n".join(pdecls))
    lines.append(");")
    for d, w, n in ports:
        if d == 'output':
            lines.append(f"    assign {n} = '0;")
    lines.append("endmodule")
    return "\n".join(lines)


def main():
    header = [
        "// ============================================================================",
        "// Wavious WDDR PHY - Behavioral Stubs for Analog/Mixed-Signal IP",
        "// Port lists extracted from original RTL (rtl/07_phy_wavious/rtl/)",
        "// Apache 2.0 License (Wavious LLC)",
        "// ============================================================================",
        "`timescale 1ps/1ps",
        "",
    ]

    results = []
    for fp, mn in MODULES:
        fullpath = os.path.join(WAVDIR, fp)
        if not os.path.exists(fullpath):
            print(f"SKIP: {mn} ({fullpath} not found)")
            continue
        ports = extract_one(fullpath, mn)
        if ports is None:
            print(f"FAIL: {mn}")
            continue
        print(f"OK: {mn} ({len(ports)} ports)")
        results.append(gen_stub(mn, ports))

    outpath = "rtl/10_phy_final/wphy_stubs/wphy_all_stubs.v"
    with open(outpath, 'w') as f:
        f.write("\n\n".join(header + results))
    print(f"\nWritten {outpath}")


if __name__ == "__main__":
    main()
