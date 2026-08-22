#!/usr/bin/env python3
import re
for modfile, modname in [
    ("ddr_ip/wphy_lp4x5_cmn.sv", "wphy_lp4x5_cmn"),
    ("mvppll_ip/wphy_rpll_mvp_4g.sv", "wphy_rpll_mvp_4g"),
    ("custom_ip/wphy_pi_4g.sv", "wphy_pi_4g"),
    ("custom_ip/wphy_clkmux_diff.sv", "wphy_clkmux_diff"),
    ("ddr_ip/wphy_lp4x5_dqs_drvr_w_lpbk.sv", "wphy_lp4x5_dqs_drvr_w_lpbk"),
    ("ddr_ip/wphy_lp4x5_cmn_clks_svt.sv", "wphy_lp4x5_cmn_clks_svt"),
]:
    filepath = f"rtl/07_phy_wavious/rtl/{modfile}"
    with open(filepath) as f:
        c = f.read()
    m = re.search(rf'^module\s+{modname}', c, re.MULTILINE)
    if not m:
        print(f"=== {modname}: MODULE NOT FOUND ===")
        continue

    paren_start = c.find('(', m.start())
    d = 0
    end = paren_start
    for i in range(paren_start, min(paren_start+8000, len(c))):
        if c[i] == '(':
            d += 1
        elif c[i] == ')':
            d -= 1
            if d == 0:
                end = i
                break

    # body
    body_start = c.find(');', end) + 2
    endmod = c.find('endmodule', body_start)
    body = c[body_start:endmod]

    # Show first 60 non-blank lines of body
    print(f"\n=== {modname} BODY (first 60 lines) ===")
    for i, line in enumerate(body.split('\n')[:60]):
        s = line.rstrip()
        if s.strip():
            print(f"  {i}: {s}")
    print("...")
