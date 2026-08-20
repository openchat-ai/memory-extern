/* pim_extract_all.c — 流式解量化 GGUF 全部张量到 stdout，一行一行输出 fp32。
 *
 * 输出格式（每个 tensor 一段）:
 *   [u32 name_len] [bytes name] [u32 ndims] [u64 dims[4]] [u32 ggml_type]
 *   [u64 n_rows] [u64 d0] [u64 rowstride_f32]
 *   对每行: [fp32 d0]
 *
 * 用于 PIM 全模型精度模拟：Python 侧边读边算，算完丢弃，避免落盘。
 *
 * 用法: pim_extract_all <model.gguf> [max_rows_per_tensor]
 *   max_rows=0 默认（大张量>256MB fp32 时只抽 128 行，小张量全部）
 *   max_rows>0 强制每张量最多抽取这么多行
 *
 * 编译: g++ -O2 -I /root/sparkmoe-fork/ggml/src pim_extract_all.c \
 *        -L /root/sparkmoe-fork/build/src -llama -lggml -o /root/pim_extract_all
 */
#include "ggml.h"
#include "ggml-quants.h"
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* 静态编译时需要 stub 这几个 ggml 基础符号（本工具不使用完整 ggml API） */
void ggml_abort(const char *file, int line, const char *fmt, ...) { (void)file; (void)line; (void)fmt; abort(); }
size_t ggml_row_size(enum ggml_type, int64_t) { return 0; }
size_t ggml_type_size(enum ggml_type) { return 0; }
const char *ggml_type_name(enum ggml_type) { return NULL; }

/* ---- 流式 GGUF 解析（同 dequant_tensor.c） ---- */

static int rd(FILE *fp, void *buf, size_t n) { return fread(buf, 1, n, fp) == n ? 0 : -1; }
static int rd_u64(FILE *fp, uint64_t *v) { return rd(fp, v, 8); }
static int rd_u32(FILE *fp, uint32_t *v) { return rd(fp, v, 4); }

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

static uint64_t pad64(uint64_t x, uint32_t a) { return ((x + a - 1) / a) * a; }

/* 解析所有 tensor 信息到数组 */
typedef struct {
    char name[128];
    int64_t dims[4];
    int32_t ndims;
    int type;
    uint64_t offset;
} TensorInfo;

static int parse_all_tensors(FILE *fp, TensorInfo **out, uint64_t *out_n, uint64_t *out_data_base, uint32_t *out_alignment)
{
    char magic[4]; uint32_t v32; uint64_t v64;
    if (rd(fp, magic, 4) || memcmp(magic, "GGUF", 4)) return -1;
    if (rd_u32(fp, &v32)) return -1;
    if (rd_u64(fp, &v64)) return -1;
    uint64_t n_tensors = v64;
    if (rd_u64(fp, &v64)) return -1;
    uint64_t n_kv = v64;

    uint32_t alignment = 32;
    for (uint64_t k = 0; k < n_kv; k++) {
        uint64_t nlen;
        if (rd_u64(fp, &nlen) || nlen >= 256) return -1;
        char kbuf[256];
        if (rd(fp, kbuf, (size_t)nlen)) return -1;
        kbuf[nlen] = 0;
        uint32_t vt;
        if (rd_u32(fp, &vt)) return -1;
        if (strcmp(kbuf, "general.alignment") == 0 && (vt == KV_U32 || vt == KV_I32)) {
            if (rd_u32(fp, &v32)) return -1;
            alignment = v32;
        } else if (skip_value(fp, vt)) return -1;
    }

    TensorInfo *infos = malloc(sizeof(TensorInfo) * n_tensors);
    for (uint64_t t = 0; t < n_tensors; t++) {
        uint64_t nlen;
        if (rd_u64(fp, &nlen) || nlen >= 128) { free(infos); return -1; }
        char name[128];
        if (rd(fp, name, (size_t)nlen)) { free(infos); return -1; }
        name[nlen] = 0;
        uint32_t nd;
        if (rd_u32(fp, &nd) || nd > 4) { free(infos); return -1; }
        int64_t tdims[4] = {0};
        for (uint32_t i = 0; i < nd; i++) {
            if (rd_u64(fp, &v64)) { free(infos); return -1; }
            tdims[i] = (int64_t)v64;
        }
        uint32_t ty;
        if (rd_u32(fp, &ty)) { free(infos); return -1; }
        if (rd_u64(fp, &v64)) { free(infos); return -1; }
        strncpy(infos[t].name, name, 127); infos[t].name[127] = 0;
        infos[t].type = (int)ty; infos[t].offset = v64;
        infos[t].ndims = (int)nd;
        for (uint32_t i = 0; i < nd; i++) infos[t].dims[i] = tdims[i];
    }
    uint64_t data_base = pad64((uint64_t)ftell(fp), alignment);
    *out = infos; *out_n = n_tensors; *out_data_base = data_base; *out_alignment = alignment;
    return 0;
}

static const char *type_name(int t)
{
    switch (t) {
    case GGML_TYPE_F32:   return "f32";
    case GGML_TYPE_Q4_0:  return "q4_0";
    case GGML_TYPE_Q4_1:  return "q4_1";
    case GGML_TYPE_Q5_0:  return "q5_0";
    case GGML_TYPE_Q5_1:  return "q5_1";
    case GGML_TYPE_Q8_0:  return "q8_0";
    case GGML_TYPE_Q2_K:  return "q2_K";
    case GGML_TYPE_Q3_K:  return "q3_K";
    case GGML_TYPE_Q4_K:  return "q4_K";
    case GGML_TYPE_Q5_K:  return "q5_K";
    case GGML_TYPE_Q6_K:  return "q6_K";
    case GGML_TYPE_Q8_K:  return "q8_K";
    case GGML_TYPE_IQ2_XXS:return "iq2_xxs";
    case GGML_TYPE_IQ3_XXS:return "iq3_xxs";
    case GGML_TYPE_IQ1_S: return "iq1_s";
    case GGML_TYPE_IQ1_M: return "iq1_m";
    case GGML_TYPE_IQ4_NL: return "iq4_nl";
    case GGML_TYPE_IQ3_S: return "iq3_s";
    case GGML_TYPE_IQ2_S: return "iq2_s";
    case GGML_TYPE_IQ4_XS: return "iq4_xs";
    default: return "unknown";
    }
}

/* 写一段 tensor header + 行数据到 stdout */
static int write_tensor(const char *name, int ndims, const int64_t *dims, int type,
                        FILE *fp, uint64_t data_base, uint64_t offset,
                        int max_rows)
{
    const int64_t d0 = dims[0];
    int64_t n_rows = 1;
    for (int i = 1; i < ndims; i++) n_rows *= dims[i];
    if (n_rows <= 0) return 0;

    int qk = 0; size_t bsz = 0;
    void (*deq)(const void *, float *, int64_t) = NULL;
    switch (type) {
    case GGML_TYPE_F32:   qk = 1;   bsz = 4; break;
    case GGML_TYPE_Q4_0:  qk = 32;  bsz = sizeof(block_q4_0);  deq = (void(*)(const void*,float*,int64_t))dequantize_row_q4_0; break;
    case GGML_TYPE_Q4_1:  qk = 32;  bsz = sizeof(block_q4_1);  deq = (void(*)(const void*,float*,int64_t))dequantize_row_q4_1; break;
    case GGML_TYPE_Q5_0:  qk = 32;  bsz = sizeof(block_q5_0);  deq = (void(*)(const void*,float*,int64_t))dequantize_row_q5_0; break;
    case GGML_TYPE_Q5_1:  qk = 32;  bsz = sizeof(block_q5_1);  deq = (void(*)(const void*,float*,int64_t))dequantize_row_q5_1; break;
    case GGML_TYPE_Q8_0:  qk = 32;  bsz = sizeof(block_q8_0);  deq = (void(*)(const void*,float*,int64_t))dequantize_row_q8_0; break;
    case GGML_TYPE_Q2_K:  qk = 256; bsz = sizeof(block_q2_K);  deq = (void(*)(const void*,float*,int64_t))dequantize_row_q2_K; break;
    case GGML_TYPE_Q3_K:  qk = 256; bsz = sizeof(block_q3_K);  deq = (void(*)(const void*,float*,int64_t))dequantize_row_q3_K; break;
    case GGML_TYPE_Q4_K:  qk = 256; bsz = sizeof(block_q4_K);  deq = (void(*)(const void*,float*,int64_t))dequantize_row_q4_K; break;
    case GGML_TYPE_Q5_K:  qk = 256; bsz = sizeof(block_q5_K);  deq = (void(*)(const void*,float*,int64_t))dequantize_row_q5_K; break;
    case GGML_TYPE_Q6_K:  qk = 256; bsz = sizeof(block_q6_K);  deq = (void(*)(const void*,float*,int64_t))dequantize_row_q6_K; break;
    case GGML_TYPE_Q8_K:  qk = 256; bsz = sizeof(block_q8_K);  deq = (void(*)(const void*,float*,int64_t))dequantize_row_q8_K; break;
    case GGML_TYPE_IQ2_XXS:qk=256; bsz = sizeof(block_iq2_xxs); deq = (void(*)(const void*,float*,int64_t))dequantize_row_iq2_xxs; break;
    case GGML_TYPE_IQ3_XXS:qk=256; bsz = sizeof(block_iq3_xxs); deq = (void(*)(const void*,float*,int64_t))dequantize_row_iq3_xxs; break;
    case GGML_TYPE_IQ1_S: qk = 256; bsz = sizeof(block_iq1_s);  deq = (void(*)(const void*,float*,int64_t))dequantize_row_iq1_s; break;
    case GGML_TYPE_IQ1_M: qk = 256; bsz = sizeof(block_iq1_m);  deq = (void(*)(const void*,float*,int64_t))dequantize_row_iq1_m; break;
    case GGML_TYPE_IQ4_NL:qk = 256; bsz = sizeof(block_iq4_nl); deq = (void(*)(const void*,float*,int64_t))dequantize_row_iq4_nl; break;
    case GGML_TYPE_IQ3_S: qk = 256; bsz = sizeof(block_iq3_s);  deq = (void(*)(const void*,float*,int64_t))dequantize_row_iq3_s; break;
    case GGML_TYPE_IQ2_S: qk = 256; bsz = sizeof(block_iq2_s);  deq = (void(*)(const void*,float*,int64_t))dequantize_row_iq2_s; break;
    case GGML_TYPE_IQ4_XS:qk = 256; bsz = sizeof(block_iq4_xs); deq = (void(*)(const void*,float*,int64_t))dequantize_row_iq4_xs; break;
    default: fprintf(stderr, "unsupported type %d (%s)\n", type, name); return -1;
    }
    if (d0 % qk != 0) { fprintf(stderr, "d0=%lld not mult of qk=%d (%s)\n", (long long)d0, qk, name); return -1; }

    const int64_t nblk_row = d0 / qk;
    const size_t rowbytes = (size_t)nblk_row * bsz;
    const uint64_t abs_off = data_base + offset;

    /* 计算实际输出行数 */
    int64_t out_rows = n_rows;
    uint64_t fp32_total = (uint64_t)n_rows * (uint64_t)d0 * 4;
    if (fp32_total > 268435456ULL && (max_rows <= 0)) {
        out_rows = 128;
    } else if (max_rows > 0 && max_rows < out_rows) {
        out_rows = max_rows;
    }

    /* 写 header: name / ndims / dims / type / n_rows / d0 */
    size_t nlen = strlen(name);
    if (fwrite(&nlen, 4, 1, stdout) != 1) return -1;
    if (fwrite(name, 1, nlen, stdout) != nlen) return -1;
    if (fwrite(&ndims, 4, 1, stdout) != 1) return -1;
    if (fwrite(dims, 8, 4, stdout) != 4) return -1;
    int32_t tty = (int32_t)type;
    if (fwrite(&tty, 4, 1, stdout) != 1) return -1;
    uint64_t urows = (uint64_t)out_rows;
    uint64_t ud0 = (uint64_t)d0;
    if (fwrite(&urows, 8, 1, stdout) != 1) return -1;
    if (fwrite(&ud0, 8, 1, stdout) != 1) return -1;

    /* 如果 tensor 很小或者不采样，全部输出 */
    if (out_rows == n_rows) {
        if (type == GGML_TYPE_F32) {
            /* f32 直接拷贝 */
            uint8_t *buf = malloc(rowbytes);
            for (int64_t r = 0; r < n_rows; r++) {
                if (fseek(fp, (long)(abs_off + (uint64_t)r * rowbytes), SEEK_SET)) { free(buf); return -1; }
                if (rd(fp, buf, rowbytes)) { free(buf); return -1; }
                if (fwrite(buf, 4, d0, stdout) != (size_t)d0) { free(buf); return -1; }
            }
            free(buf);
        } else {
            uint8_t *vx = malloc(rowbytes);
            float *row = malloc(d0 * 4);
            for (int64_t r = 0; r < n_rows; r++) {
                if (fseek(fp, (long)(abs_off + (uint64_t)r * rowbytes), SEEK_SET)) { free(vx); free(row); return -1; }
                if (rd(fp, vx, rowbytes)) { free(vx); free(row); return -1; }
                deq(vx, row, d0);
                if (fwrite(row, 4, d0, stdout) != (size_t)d0) { free(vx); free(row); return -1; }
            }
            free(vx); free(row);
        }
    } else {
        /* 均匀采样 out_rows 行 */
        uint8_t *vx = malloc(rowbytes);
        float *row = malloc(d0 * 4);
        double step = (double)n_rows / (double)out_rows;
        for (int64_t i = 0; i < out_rows; i++) {
            int64_t r = (int64_t)round(step * (double)i);
            if (fseek(fp, (long)(abs_off + (uint64_t)r * rowbytes), SEEK_SET)) { free(vx); free(row); return -1; }
            if (type == GGML_TYPE_F32) {
                if (rd(fp, row, rowbytes)) { free(vx); free(row); return -1; }
            } else {
                if (rd(fp, vx, rowbytes)) { free(vx); free(row); return -1; }
                deq(vx, row, d0);
            }
            if (fwrite(row, 4, d0, stdout) != (size_t)d0) { free(vx); free(row); return -1; }
        }
        free(vx); free(row);
    }
    return 0;
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s <model.gguf> [max_rows]\n", argv[0]);
        return 2;
    }
    const char *gguf_path = argv[1];
    int max_rows = (argc >= 3) ? atoi(argv[2]) : 0;

    FILE *fp = fopen(gguf_path, "rb");
    if (!fp) { fprintf(stderr, "cannot open: %s\n", gguf_path); return 2; }

    TensorInfo *infos = NULL;
    uint64_t n_tensors = 0, data_base = 0;
    uint32_t alignment = 32;
    if (parse_all_tensors(fp, &infos, &n_tensors, &data_base, &alignment)) {
        fprintf(stderr, "parse fail\n"); return 2;
    }

    fprintf(stderr, "n_tensors=%llu data_base=%llu alignment=%u max_rows=%d\n",
            (unsigned long long)n_tensors, (unsigned long long)data_base, alignment, max_rows);
    fflush(stderr);

    for (uint64_t i = 0; i < n_tensors; i++) {
        TensorInfo *ti = &infos[i];
        fprintf(stderr, "  [%llu/%llu] %s  %s  dims=(%lld,%lld,%lld)\n",
                (unsigned long long)(i+1), (unsigned long long)n_tensors,
                ti->name, type_name(ti->type),
                (long long)ti->dims[0], (long long)ti->dims[1], (long long)ti->dims[2]);
        if (write_tensor(ti->name, ti->ndims,
                          ti->dims, ti->type, fp, data_base, ti->offset, max_rows)) {
            fprintf(stderr, "write fail: %s\n", ti->name);
        }
        fflush(stderr);
    }

    free(infos);
    fclose(fp);
    return 0;
}