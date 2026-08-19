#!/bin/bash
# binary search for first tensor data diff using cmp
# each iteration doubles the skip, so O(log2(N)) calls
FILE1=/root/models/Qwen3.6-35B-A3B-UD-Q3_K_S-8bit.gguf
FILE2=/root/models/Qwen3.6-35B-A3B-UD-Q3_K_S-8bit-v2.gguf
DATA=10990048
SIZE=36668357600

# first verify metadata vs tensor boundary
cmp --bytes=1000000 --ignore-initial=$DATA "$FILE1" "$FILE2"
r1=$?
echo "1MB at data_off rc=$r1"

# binary search from data_off
LO=$DATA
HI=$SIZE
while [ $((HI-LO)) -gt 1048576 ]; do
    MID=$(( (LO + HI) / 2 ))
    SKIP=$((MID - DATA))
    LEN=$((HI - MID))
    cmp --bytes=$LEN --ignore-initial=$MID "$FILE1" "$FILE2"
    if [ $? -eq 0 ]; then
        LO=$MID
    else
        HI=$MID
    fi
done
echo "NARROWED to [$LO, $HI]"
# final: find exact byte in that range
for i in $(seq 0 $((HI-LO-1))); do
    B=$((LO+i))
    SKIP=$((B-DATA))
    cmp --bytes=1 --ignore-initial=$B "$FILE1" "$FILE2"
    [ $? -eq 0 ] || { echo "FIRST_DATA_DIFF_AT=$B"; break; }
done