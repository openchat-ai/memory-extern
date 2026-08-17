#!/usr/bin/env python3
"""Crude pre-layout STA: longest path (in ns) over a yosys sky130-mapped netlist.

Reads tt.abc.v + per-cell sky130 JSON (tt 25C 1.8V corner). Per arc:
  delay = NLDM nearest-index cell_rise/cell_fall(slew=index1max, cap=fanout caps)
Wire delay + clock skew ignored (pre-layout). Approach intentionally simple.
"""
import json, re, os, sys
from collections import defaultdict

ABC = '/data/data/com.termux/files/home/sram/rtl/05_gemv/tt.abc.v'
CELL = '/data/data/com.termux/files/usr/tmp/opencode/sky3/cells'
CORNER = 'tt_025C_1v80'

CELLJSON = {}
def celljson(cell):
    if cell in CELLJSON: return CELLJSON[cell]
    want = '%s__%s.lib.json' % (cell, CORNER)
    for root, _, files in os.walk(CELL):
        if want in files:
            CELLJSON[cell] = json.load(open(os.path.join(root, want)))
            return CELLJSON[cell]
    return None

def nn(grid, x):
    best, bi = 1e18, 0
    for i, g in enumerate(grid):
        d = abs(g - x)
        if d < best:
            best, bi = d, i
    return bi

def parsemodules():
    mods = defaultdict(list)
    cur = None
    it = iter(open(ABC))
    for line in it:
        if line.startswith('module '):
            cur = line.split()[1].split('(')[0].strip()
        elif line.startswith('endmodule'):
            cur = None
        elif cur and 'sky130_fd_sc_hd__' in line:
            buf = line
            while ');' not in buf:
                buf += next(it)
            m = re.match(r'\s*(sky130_fd_sc_hd__\w+)\s+(\S+)\s*\((.*?)\)\s*;', buf, re.S)
            if m:
                cell, inst, ports = m.groups()
                mods[cur].append((cell, inst,
                                  dict(re.findall(r'\.(\w+)\s*\(\\?(\S+)\)\s*,?', ports))))
    return mods

def out_pins(cell):
    """pins with direction==output from the cell lib (cached)."""
    d = celljson(cell)
    if not d:
        return []
    return [k.split(',')[1] for k in d
            if k.startswith('pin,') and isinstance(d[k], dict)
            and d[k].get('direction') == 'output']

def pin_cap(cell, pin):
    d = celljson(cell)
    c = d.get('pin,%s' % pin, {}).get('capacitance') if d else None
    return c if isinstance(c, (int, float)) else 0.0

def build(target, insts):
    """nets: fanin caps; drive: net -> (cell,outpin); seq_out: DFF Q nets."""
    fanin_cap = defaultdict(float)
    drive = {}
    seq_out = set()
    for cell, inst, pm in insts:
        is_dff = 'dfxtp' in cell or 'dfrtp' in cell or 'dfsfp' in cell or 'dfbbp' in cell or 'dfrtp' in cell or 'dffs' in cell or 'dfxtp' in cell
        outs = out_pins(cell)
        for p, net in pm.items():
            if p == 'Q' and is_dff:
                seq_out.add(net)
                drive[net] = (cell, p)
            elif p in outs:
                drive[net] = (cell, p)
            else:
                fanin_cap[net] += pin_cap(cell, p)
    return fanin_cap, drive, seq_out

def gate_ns(cell, outpin, cap):
    d = celljson(cell)
    t = d.get('pin,%s' % outpin)
    if not t or isinstance(t, list): return 0.0, 0.0
    timing = t.get('timing', {})
    if not isinstance(timing, dict): timing = {}
    vals = {}
    for k, v in timing.items():
        if k.startswith('cell_rise,') and isinstance(v, dict):
            vals['r'] = (v['index_1'], v['index_2'], v['values'])
        if k.startswith('cell_fall,') and isinstance(v, dict):
            vals['f'] = (v['index_1'], v['index_2'], v['values'])
    best = 0.0
    for key in ('r', 'f'):
        if key not in vals: continue
        i1, i2, vv = vals[key]
        a, b = nn(i1, i1[-1]), nn(i2, cap)
        row = vv[a] if not isinstance(vv[0], list) else vv[a]
        best = max(best, float(row[b]) if isinstance(row, list) else float(row))
    return best, max(cap, 0.0)

def crudesta(mod, insts):
    fanin, drive, seq_out = build(mod, insts)
    # nets fed by some gate output = driven
    driven = set(drive.keys())
    # primary inputs: appear as cell inputs but are not driven
    cell_in_nets = set()
    for cell, inst, pm in insts:
        for p, net in pm.items():
            if p in ('Q', 'QN', 'CLK', 'RESET_B', 'SET_B', 'D'):
                continue
            cell_in_nets.add(net)
    starts = (cell_in_nets - driven) | seq_out

    # edge: input net -> output net via gate, weighted by gate delay on that arc
    out_from = defaultdict(list)
    for cell, inst, pm in insts:
        outs = [(p, n) for p, n in pm.items() if p in out_pins(cell)]
        if not outs:
            continue
        for op, onet in outs:
            if onet in seq_out:
                continue  # don't extend through register boundary
            cap_for = fanin.get(onet, 0.0)
            wt, _ = gate_ns(cell, op, cap_for)
            for ip, innet in pm.items():
                if ip in outs:
                    continue
                if ip in ('CLK', 'RESET_B', 'SET_B'):
                    continue
                out_from[innet].append((onet, wt))

    dp = {}
    visited = set()

    def solve(net):
        if net in dp:
            return dp[net]
        if net in visited:
            return 0.0  # cycle guard (should not happen post-synth)
        visited.add(net)
        best = 0.0
        for onet, wt in out_from.get(net, []):
            best = max(best, wt + solve(onet))
        visited.discard(net)
        dp[net] = best
        return best

    crit = 0.0
    for net in starts:
        v = solve(net)
        if v > crit:
            crit = v
    return crit, len(insts), len(starts)

def main():
    if len(sys.argv) > 1:
        targets = sys.argv[1:]
    else:
        targets = ['f32_add', 'periph_scale', 'periph_mac', 'tt_um_periph_mac']
    mods = parsemodules()
    def find(t):
        for k in mods:
            clean = k.replace('\\', '')
            # parameterized: $paramod/periph_mac/NGRP=8...
            m = re.search(r'paramod[/\\]?([a-z0-9_]+)', clean)
            base = m.group(1) if m else clean.split('(')[0]
            if base == t:
                return k
        return None
    print('%-22s %8s %8s  %s' % ('module', 'gates', 'cp(ns)', 'note'))
    for t in targets:
        key = find(t)
        insts = mods.get(key, [])
        if not insts:
            print('%-22s  (not in netlist)' % t); continue
        crit, n, ns = crudesta(t, insts)
        print('%-22s %8d %8.2f  %d start nets' % (t, n, crit, ns))

if __name__ == '__main__':
    main()