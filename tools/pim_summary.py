#!/usr/bin/env python3
import json, os
os.chdir("/tmp")
configs = {
    "cell_only_mxfp4": "pim_cell_mx",
    "mxfp4": "pim_mxfp4",
    "mxfp4_no_noise": "pim_mx_nonoise",
    "cell_only_int8": "pim_cell_int8",
    "int8_blk32": "pim_int8",
    "int8_blk256": "pim_int8_blk256",
    "int6_blk32": "pim_int6",
    "dac_adc_only": "pim_dac_adc",
}
print("=" * 95)
print(f"{'Config':<22s}  n     max_err    p95       p50       p25")
print("=" * 95)
for label, fn in configs.items():
    d = json.load(open(f"{fn}.json"))
    t = d["agg"]["total"]
    print(f"{label:<22s}  {t['n']:>4d}  {t['max']:.2e}  {t['p95']:.2e}  {t['p50']:.2e}  {t['p25']:.2e}")

print()
print("By source quant type — p50(max_err/RMS):")
header = f"{'Type':<10s}"
for label in configs:
    header += f" {label:<22s}"
print(header)
print("-" * len(header))

types = set()
for fn in configs.values():
    d = json.load(open(f"{fn}.json"))
    for row in d["agg"]["by_type"]:
        types.add(row["key"])

for ty in sorted(types):
    line = f"{ty:<10s}"
    for label, fn in configs.items():
        d = json.load(open(f"{fn}.json"))
        row = next((r for r in d["agg"]["by_type"] if r["key"] == ty), None)
        if row:
            line += f" {row['p50']:.2e}".rjust(23)
        else:
            line += f" {'---':>10s}".rjust(23)
    print(line)