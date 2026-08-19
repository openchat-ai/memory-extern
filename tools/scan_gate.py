import struct

MODEL = '/root/models/Qwen3.6-35B-A3B-UD-Q3_K_S.gguf'
ABS = 10990048 + 977567744   # 官方 data_offset + tensor offset
ROW = 784                    # 8 block x 98B (IQ3_XXS)
NROWS = 512 * 256            # ne[1] x ne[2]

nz_rows = []
with open(MODEL, 'rb') as f:
    f.seek(ABS)
    for r in range(NROWS):
        b = f.read(ROW)
        if any(x != 0 for x in b):
            nz_rows.append(r)

print(f'non-zero rows: {len(nz_rows)} / {NROWS}  ({100.0*len(nz_rows)/NROWS:.1f}%)')
print(f'first 20 nz rows: {nz_rows[:20]}')
# per-expert (512 rows each) non-zero distribution
per_exp = [0] * 256
for r in nz_rows:
    per_exp[r // 512] += 1
print('per-expert nz rows (min/max):', min(per_exp), max(per_exp), 'mean=%.1f' % (len(nz_rows)/256))
print('experts with 0 nz rows:', sum(1 for x in per_exp if x == 0))
print('first 5 expert counts:', per_exp[:5])
