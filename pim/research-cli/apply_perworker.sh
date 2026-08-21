#!/bin/bash
set -e
F=/root/sparkmoe-fork/ggml/src/ggml-cpu/ggml-cpu.c
# apply per-worker semaphore fix on top of CURRENT file (which has [c] log), do NOT cp .bak6
perl -0pi -e 's/static sem_t ggml_chip_sem_submit;/static sem_t ggml_chip_sem_submit[GGML_CHIP_MAX_THREADS];/' $F
perl -0pi -e 's/sem_wait\(&ggml_chip_sem_submit\);/sem_wait(\&ggml_chip_sem_submit[ith]);/' $F
perl -0pi -e 's/for \(int i = 0; i < ggml_chip_nthreads; i\+\+\) \{\n        sem_post\(&ggml_chip_sem_submit\);\n    \}/for (int i = 0; i < ggml_chip_nthreads; i++) {\n        sem_post(\&ggml_chip_sem_submit[i]);\n    }/' $F
perl -0pi -e 's/sem_init\(&ggml_chip_sem_submit, 0, 0\);/for (int i = 0; i < GGML_CHIP_MAX_THREADS; i++) { sem_init(\&ggml_chip_sem_submit[i], 0, 0); }/' $F
grep -n 'ggml_chip_sem_submit' $F