python3 tools/profile_trace.py --demo --n-layers 60 --n-experts 384 --topk 8 --alpha 1.3 --stay-p 0.8 --stay-k 3 --n-tokens 1000 --manifest case-k25/k25-manifest.json --bank-budgets "4.51,9.03,18.05,36.10" --tier-budget-gib 4.51 --outdir case-k25/out-topk8

# 时序仿真（§5.6）：K2.5 档位，需先有 demo-trace.jsonl（上面命令生成到 out-topk8/）
python3 tools/sim_scheduler.py --trace case-k25/out-topk8/demo-trace.jsonl \
  --manifest case-k25/k25-manifest.json --budget-gib 4.51 \
  --compute-ms 2 --r0-ms 5 --bandwidth-mib-s 2048 --lookahead "1,2,4" --markov
