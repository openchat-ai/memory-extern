/* gguf_requant.c — 通用 GGUF 权重重写/精度注入工具（与具体模型无关）。
 *
 * 用途：把给定 GGUF 模型里指定量化类型的张量，dequantize 后重新量化成
 *       目标类型（默认 Q8_0 = 8bit 均匀 blk32），其余张量原样复制。
 *       用于 PIM 精度实证："Q3 权重用 8bit 均匀 blk32 表示" 对生成的影响。
 *
 * 设计原则：与模型无关（任何 GGUF 都能处理）、元数据驱动、流式（不整读）。
 *          换模型 / 换精度档位只改参数，不改代码 —— 不"重新流片"。
 *
 * 用法:
 *   gguf_requant <in.gguf> <out.gguf> [options]
 *
 * options:
 *   --from TYPE[,TYPE...]   要重写的源类型，默认 iq3_xxs,iq3_s,iq4_xs
 *   --to   TYPE             目标类型，默认 q8_0
 *   --dry-run               只预览（类型分布 + 待重写张量 + 体积估算），不写文件
 *   -t, --threads N         OpenMP 线程数（默认自动）
 */
#define _GNU_SOURCE
#include "ggml.h"
#include "ggml-quants.h"

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifdef _OPENMP
#include <omp.h>
#endif

#define MAX_TENSORS 1024

typedef struct {
    char  name[128];
    uint32_t nd;
    int64_t  dims[4];
    uint32_t type;
    uint64_t offset;   /* 源文件数据区相对偏移 */
    int      inject;   /* 1 = 重写为目标类型 */
} tinfo_t;

/* ---- dequant（源）支持表：只放已验证的条目 ---- */
typedef struct {
    enum ggml_type t;
    const char *name;
    uint8_t  qk;                                  /* 每 block 元素数 */
    size_t   bsz;                                 /* 每 block 字节数 */
    void (*deq)(const void *, float *, int64_t);
} deq_entry_t;

static const deq_entry_t DEQ_TABLE[] = {
    { GGML_TYPE_IQ3_XXS, "iq3_xxs", 256, sizeof(block_iq3_xxs), (void(*)(const void*,float*,int64_t))dequantize_row_iq3_xxs },
    { GGML_TYPE_IQ3_S,   "iq3_s",   256, sizeof(block_iq3_s),   (void(*)(const void*,float*,int64_t))dequantize_row_iq3_s   },
    { GGML_TYPE_IQ4_XS,  "iq4_xs",  256, sizeof(block_iq4_xs),  (void(*)(const void*,float*,int64_t))dequantize_row_iq4_xs  },
};
#define N_DEQ ((int)(sizeof(DEQ_TABLE)/sizeof(DEQ_TABLE[0])))

/* ---- quant（目标）支持表：只放已验证的条目 ---- */
typedef struct {
    enum ggml_type t;
    const char *name;
    uint8_t  qk;
    size_t   bsz;
    void (*quant)(const float *, void *, int64_t);
} quant_entry_t;

static const quant_entry_t QUANT_TABLE[] = {
    { GGML_TYPE_Q8_0, "q8_0", 32, sizeof(block_q8_0), (void(*)(const float*,void*,int64_t))quantize_row_q8_0_ref },
};
#define N_QUANT ((int)(sizeof(QUANT_TABLE)/sizeof(QUANT_TABLE[0])))

/* ---- CLI 选项 ---- */
typedef struct {
    const char *in_path;
    const char *out_path;
    uint32_t   from_mask;   /* bitmask over DEQ_TABLE */
    int        to_idx;      /* index into QUANT_TABLE */
    int        dry_run;
    int        threads;
} opts_t;

static uint32_t parse_type_mask(const char *s)
{
    uint32_t mask = 0;
    char buf[256];
    strncpy(buf, s, sizeof(buf) - 1);
    buf[sizeof(buf) - 1] = 0;
    for (char *tok = strtok(buf, ","); tok; tok = strtok(NULL, ",")) {
        int found = 0;
        for (int i = 0; i < N_DEQ; i++) {
            if (strcmp(tok, DEQ_TABLE[i].name) == 0) { mask |= (1u << i); found = 1; break; }
        }
        if (!found) {
            fprintf(stderr, "error: --from type '%s' not supported (supported: ", tok);
            for (int i = 0; i < N_DEQ; i++) fprintf(stderr, "%s%s", i ? "," : "", DEQ_TABLE[i].name);
            fprintf(stderr, ")\n");
            exit(2);
        }
    }
    return mask;
}

static int parse_to_type(const char *s)
{
    for (int i = 0; i < N_QUANT; i++) {
        if (strcmp(s, QUANT_TABLE[i].name) == 0) return i;
    }
    fprintf(stderr, "error: --to type '%s' not supported (supported: ", s);
    for (int i = 0; i < N_QUANT; i++) fprintf(stderr, "%s%s", i ? "," : "", QUANT_TABLE[i].name);
    fprintf(stderr, ")\n");
    exit(2);
}

static void parse_args(int argc, char **argv, opts_t *o)
{
    memset(o, 0, sizeof(*o));
    o->from_mask = (1u << N_DEQ) - 1;   /* 默认全部 deq 类型 */
    o->to_idx    = 0;                   /* 默认 q8_0 */
    o->threads   = 0;
    if (argc < 3) {
        fprintf(stderr, "usage: %s <in.gguf> <out.gguf> [--from T,T] [--to T] [--dry-run] [-t N]\n", argv[0]);
        exit(2);
    }
    o->in_path  = argv[1];
    o->out_path = argv[2];
    for (int i = 3; i < argc; i++) {
        if      (strcmp(argv[i], "--from")   == 0 && i + 1 < argc) o->from_mask = parse_type_mask(argv[++i]);
        else if (strcmp(argv[i], "--to")     == 0 && i + 1 < argc) o->to_idx    = parse_to_type(argv[++i]);
        else if (strcmp(argv[i], "--dry-run")== 0)                 o->dry_run   = 1;
        else if ((strcmp(argv[i], "-t") == 0 || strcmp(argv[i], "--threads") == 0) && i + 1 < argc)
                                                                    o->threads   = atoi(argv[++i]);
        else { fprintf(stderr, "unknown arg: %s\n", argv[i]); exit(2); }
    }
}

static int type_injectable(uint32_t t, const opts_t *o)
{
    for (int i = 0; i < N_DEQ; i++) {
        if ((o->from_mask & (1u << i)) && DEQ_TABLE[i].t == t) return 1;
    }
    return 0;
}

static const deq_entry_t *find_deq(uint32_t t)
{
    for (int i = 0; i < N_DEQ; i++) if (DEQ_TABLE[i].t == t) return &DEQ_TABLE[i];
    return NULL;
}

/* ---- GGUF 基础读 ---- */
static int rd(FILE *fp, void *buf, size_t n) { return fread(buf, 1, n, fp) == n ? 0 : -1; }
static int rd_u32(FILE *fp, uint32_t *v) { return rd(fp, v, 4); }
static int rd_u64(FILE *fp, uint64_t *v) { return rd(fp, v, 8); }

enum { KV_U8=0, KV_I8=1, KV_U16=2, KV_I16=3, KV_U32=4, KV_I32=5, KV_F32=6,
       KV_BOOL=7, KV_STR=8, KV_ARR=9, KV_U64=10, KV_I64=11, KV_F64=12 };

static int skip_bytes(FILE *fp, uint64_t n) { return fseek(fp, (long)n, SEEK_CUR) == 0 ? 0 : -1; }

static int skip_value(FILE *fp, uint32_t t)
{
    uint64_t v64; uint32_t v32;
    switch (t) {
    case KV_U8: case KV_I8: case KV_BOOL:   return skip_bytes(fp, 1);
    case KV_U16: case KV_I16:               return skip_bytes(fp, 2);
    case KV_U32: case KV_I32: case KV_F32:  return skip_bytes(fp, 4);
    case KV_U64: case KV_I64: case KV_F64:  return skip_bytes(fp, 8);
    case KV_STR: {
        if (rd_u64(fp, &v64)) return -1;
        return skip_bytes(fp, v64);
    }
    case KV_ARR: {
        uint32_t et;
        if (rd_u32(fp, &et)) return -1;
        if (rd_u64(fp, &v64)) return -1;
        if (et == KV_STR) {
            for (uint64_t i = 0; i < v64; i++) {
                uint64_t len;
                if (rd_u64(fp, &len) || skip_bytes(fp, len)) return -1;
            }
            return 0;
        }
        static const uint8_t sz[13] = { 1,1,2,2,4,4,8,1,0,0,8,8,8 };
        if (et <= KV_F64 && et != KV_ARR) return skip_bytes(fp, v64 * sz[et]);
        return -1;
    }
    default: return -1;
    }
}

static uint64_t pad64(uint64_t x, uint64_t a) { return ((x + a - 1) / a) * a; }

/* tensor 元素数 */
static uint64_t tinfo_ne(const tinfo_t *T)
{
    uint64_t ne = 1;
    for (uint32_t i = 0; i < T->nd; i++) ne *= (uint64_t)T->dims[i];
    return ne;
}
/* 源文件存储字节数 */
static uint64_t tinfo_src_bytes(const tinfo_t *T)
{
    uint64_t ne = tinfo_ne(T);
    return (ne / (uint64_t)ggml_blck_size(T->type)) * (uint64_t)ggml_type_size(T->type);
}
/* 注入后存储字节数 */
static uint64_t tinfo_dst_bytes(const tinfo_t *T, const quant_entry_t *qu)
{
    uint64_t ne = tinfo_ne(T);
    return (ne / qu->qk) * qu->bsz;
}

int main(int argc, char **argv)
{
    opts_t o;
    parse_args(argc, argv, &o);
    const quant_entry_t *qent = &QUANT_TABLE[o.to_idx];
#ifdef _OPENMP
    if (o.threads > 0) omp_set_num_threads(o.threads);
#else
    (void)o.threads;
#endif

    FILE *fi = fopen(o.in_path, "rb");
    if (!fi) { fprintf(stderr, "cannot open: %s\n", o.in_path); return 2; }
    const int fd = fileno(fi);

    /* ---- 解析头部 ---- */
    char magic[4]; uint32_t v32; uint64_t v64;
    if (rd(fi, magic, 4) || memcmp(magic, "GGUF", 4)) { fprintf(stderr, "bad magic\n"); return 2; }
    if (rd_u32(fi, &v32)) return 2;                 /* version */
    if (rd_u64(fi, &v64)) return 2;
    const uint64_t n_tensors = v64;
    if (rd_u64(fi, &v64)) return 2;
    const uint64_t n_kv = v64;
    if (n_tensors > MAX_TENSORS) { fprintf(stderr, "too many tensors: %" PRIu64 "\n", n_tensors); return 2; }

    const long kv_start = ftell(fi);
    uint64_t alignment = 32;
    for (uint64_t k = 0; k < n_kv; k++) {
        uint64_t nlen;
        if (rd_u64(fi, &nlen) || nlen >= 256) return 2;
        char kbuf[256];
        if (rd(fi, kbuf, (size_t)nlen)) return 2;
        kbuf[nlen] = 0;
        uint32_t vt;
        if (rd_u32(fi, &vt)) return 2;
        if (strcmp(kbuf, "general.alignment") == 0 && (vt == KV_U32 || vt == KV_I32)) {
            if (rd_u32(fi, &v32)) return 2;
            alignment = v32;
        } else if (skip_value(fi, vt)) return 2;
    }
    const long tinfo_start = ftell(fi);

    tinfo_t T[MAX_TENSORS];
    for (uint64_t t = 0; t < n_tensors; t++) {
        uint64_t nlen;
        if (rd_u64(fi, &nlen)) return 2;
        if (nlen >= 128) return 2;
        char name[128];
        if (rd(fi, name, (size_t)nlen)) return 2;
        name[nlen] = 0;
        uint32_t nd;
        if (rd_u32(fi, &nd) || nd > 4) return 2;
        T[t].nd = nd;
        for (uint32_t i = 0; i < nd; i++) {
            if (rd_u64(fi, &v64)) return 2;
            T[t].dims[i] = (int64_t)v64;
        }
        if (rd_u32(fi, &v32)) return 2;
        T[t].type = v32;
        if (rd_u64(fi, &v64)) return 2;
        T[t].offset = v64;
        strcpy(T[t].name, name);
        T[t].inject = type_injectable(T[t].type, &o);
    }
    const uint64_t data_base = pad64((uint64_t)ftell(fi), alignment);
    printf("n_tensors=%" PRIu64 " n_kv=%" PRIu64 " alignment=%" PRIu64 " data_base=%" PRIu64 "\n",
           n_tensors, n_kv, alignment, data_base);

    /* ---- 统计 ---- */
    uint64_t n_inj = 0, n_copy = 0, src_bytes = 0, dst_bytes = 0;
    for (uint64_t t = 0; t < n_tensors; t++) {
        uint64_t ne = tinfo_ne(&T[t]);
        src_bytes += ne;
        if (T[t].inject) { n_inj++; dst_bytes += tinfo_dst_bytes(&T[t], qent); }
        else             { n_copy++; dst_bytes += tinfo_src_bytes(&T[t]); }
    }
    printf("[%s] to=%s  inject=%" PRIu64 " copy=%" PRIu64 "  src_bytes=%" PRIu64 "  dst_bytes=%" PRIu64 "\n",
           o.dry_run ? "DRY-RUN" : "RUN", qent->name, n_inj, n_copy, src_bytes, dst_bytes);

    if (o.dry_run) {
        printf("\nwill-rewrite (%" PRIu64 " tensors):\n", n_inj);
        for (uint64_t t = 0; t < n_tensors; t++) {
            if (!T[t].inject) continue;
            printf("  [%2" PRIu64 "] %-46s %-10s -> %s (%" PRIu64 "B)\n",
                   t, T[t].name, ggml_type_name(T[t].type), qent->name, tinfo_dst_bytes(&T[t], qent));
        }
        fclose(fi);
        printf("dry-run ok. nothing written.\n");
        return 0;
    }

    /* ---- 打开输出 ---- */
    FILE *fo = fopen(o.out_path, "wb");
    if (!fo) { fprintf(stderr, "cannot write: %s\n", o.out_path); return 2; }

    /* header */
    uint32_t ver = 3;
    if (fwrite("GGUF", 1, 4, fo) != 4 || fwrite(&ver, 4, 1, fo) != 1 ||
        fwrite(&n_tensors, 8, 1, fo) != 1 || fwrite(&n_kv, 8, 1, fo) != 1) { fprintf(stderr, "write header fail\n"); return 2; }
    /* KV 原样复制 */
    {
        long kv_len = tinfo_start - kv_start;
        if (fseek(fi, kv_start, SEEK_SET)) return 2;
        char *buf = malloc((size_t)kv_len);
        if (!buf || fread(buf, 1, (size_t)kv_len, fi) != (size_t)kv_len ||
            fwrite(buf, 1, (size_t)kv_len, fo) != (size_t)kv_len) { fprintf(stderr, "kv copy fail\n"); return 2; }
        free(buf);
    }

    /* tinfo（重写 type/offset） */
    uint64_t cur = 0;
    for (uint64_t t = 0; t < n_tensors; t++) {
        cur = pad64(cur, alignment);
        size_t nlen = strlen(T[t].name);
        uint32_t newtype = T[t].inject ? (uint32_t)qent->t : T[t].type;
        if (fwrite(&nlen, 8, 1, fo) != 1 || fwrite(T[t].name, 1, nlen, fo) != nlen ||
            fwrite(&T[t].nd, 4, 1, fo) != 1) { fprintf(stderr, "tinfo write fail\n"); return 2; }
        for (uint32_t i = 0; i < T[t].nd; i++) {
            uint64_t d = (uint64_t)T[t].dims[i];
            if (fwrite(&d, 8, 1, fo) != 1) return 2;
        }
        if (fwrite(&newtype, 4, 1, fo) != 1 || fwrite(&cur, 8, 1, fo) != 1) { fprintf(stderr, "tinfo write fail2\n"); return 2; }
        cur += T[t].inject ? tinfo_dst_bytes(&T[t], qent) : tinfo_src_bytes(&T[t]);
    }
    /* pad 到 alignment */
    {
        uint64_t pos = (uint64_t)ftell(fo);
        uint64_t padn = pad64(pos, alignment) - pos;
        char z[32] = {0};
        while (padn) { size_t w = padn < 32 ? (size_t)padn : 32; fwrite(z, 1, w, fo); padn -= w; }
    }
    printf("metadata written; data starts at %" PRIu64 "\n", (uint64_t)ftell(fo));

    /* ---- 数据区 ---- */
    for (uint64_t t = 0; t < n_tensors; t++) {
        const uint64_t ne = tinfo_ne(&T[t]);
        const int64_t d0 = T[t].dims[0];
        const uint64_t nrows = d0 ? ne / (uint64_t)d0 : 0;
        const uint64_t src_off = data_base + T[t].offset;

        if (!T[t].inject) {
            /* 原样复制整张量字节 */
            uint8_t buf[1 << 16];
            const uint64_t copy_bytes = tinfo_src_bytes(&T[t]);
            uint64_t left = copy_bytes;
            if (fseek(fi, (long)src_off, SEEK_SET)) { fprintf(stderr, "seek src fail\n"); return 2; }
            while (left) {
                size_t chunk = left < sizeof(buf) ? (size_t)left : sizeof(buf);
                if (fread(buf, 1, chunk, fi) != chunk || fwrite(buf, 1, chunk, fo) != chunk) { fprintf(stderr, "copy fail\n"); return 2; }
                left -= chunk;
            }
            if ((t % 20) == 0 || t == n_tensors - 1)
                printf("copy  [%2" PRIu64 "/%" PRIu64 "] %-46s %-10s (%" PRIu64 "B)\n",
                       t, n_tensors, T[t].name, ggml_type_name(T[t].type), copy_bytes);
            continue;
        }

        /* 注入：dequant -> 目标类型 quant */
        const deq_entry_t *de = find_deq(T[t].type);
        if (!de) { fprintf(stderr, "unexpected type %u for %s\n", T[t].type, T[t].name); return 2; }
        if (d0 % (int64_t)de->qk != 0) { fprintf(stderr, "d0=%lld not %u-multiple\n", (long long)d0, de->qk); return 2; }
        if (d0 % (int64_t)qent->qk != 0) { fprintf(stderr, "d0=%lld not %u-multiple (to)\n", (long long)d0, qent->qk); return 2; }
        const size_t src_row = (size_t)(d0 / (int64_t)de->qk) * de->bsz;
        const size_t dst_row = (size_t)(d0 / (int64_t)qent->qk) * qent->bsz;
        const uint64_t src_row_base = src_off;

        uint8_t *qall = malloc(dst_row * nrows);
        if (!qall) { fprintf(stderr, "malloc %zu fail\n", dst_row * nrows); return 2; }

        #pragma omp parallel for schedule(dynamic, 64)
        for (int64_t r = 0; r < (int64_t)nrows; r++) {
            uint8_t *vx = malloc(src_row);
            float  *row = malloc((size_t)d0 * 4);
            if (!vx || !row) { fprintf(stderr, "row malloc fail\n"); exit(2); }
            if (pread(fd, vx, src_row, src_row_base + (uint64_t)r * src_row) != (ssize_t)src_row) {
                fprintf(stderr, "pread fail %s\n", T[t].name); exit(2);
            }
            de->deq(vx, row, d0);
            qent->quant(row, qall + (size_t)r * dst_row, d0);
            free(vx); free(row);
        }

        if (fwrite(qall, 1, dst_row * nrows, fo) != dst_row * nrows) { fprintf(stderr, "data write fail\n"); return 2; }
        free(qall);

        if ((t % 20) == 0 || t == n_tensors - 1)
            printf("inject[%2" PRIu64 "/%" PRIu64 "] %-46s %-10s -> %s (%" PRIu64 "B)\n",
                   t, n_tensors, T[t].name, ggml_type_name(T[t].type), qent->name, dst_row * nrows);
    }

    fclose(fo);
    fclose(fi);
    printf("done -> %s\n", o.out_path);
    return 0;
}