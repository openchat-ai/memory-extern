/* dequant_tensor.c — 从 GGUF 读出指定张量的若干行，dequant 到 fp32 二进制文件。
 *
 * 用途：精度预算实测的数据源。用 fork ggml 的官方 dequant 函数，避免 Python 重
 * 实现 IQ codebook 大表出错。流式解析（不整读模型文件）。
 *
 * 用法: dequant_tensor <model.gguf> <tensor_name> <rows> <out.f32bin>
 *   行 = 沿 dim1 步进、dim0 连续（gate_exps 一个专家 = 512 行）。
 *   输出 = rows × dims[0] 个 fp32，raw 二进制。
 */
#include "ggml.h"
#include "ggml-quants.h"

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ---- 流式 GGUF 解析 ---- */

static int rd(FILE *fp, void *buf, size_t n) { return fread(buf, 1, n, fp) == n ? 0 : -1; }
static int rd_u64(FILE *fp, uint64_t *v) { return rd(fp, v, 8); }
static int rd_u32(FILE *fp, uint32_t *v) { return rd(fp, v, 4); }

enum { KV_U8=0, KV_I8=1, KV_U16=2, KV_I16=3, KV_U32=4, KV_I32=5, KV_F32=6,
       KV_BOOL=7, KV_STR=8, KV_ARR=9, KV_U64=10, KV_I64=11, KV_F64=12 };

static int skip_bytes(FILE *fp, uint64_t n)
{
    return fseek(fp, (long)n, SEEK_CUR) == 0 ? 0 : -1;
}

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
        if (rd_u32(fp, &et)) return -1;        /* 元素类型（u32） */
        if (rd_u64(fp, &v64)) return -1;       /* 元素个数（u64） */
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

/* 解析头部 + KV + tensor info，找到目标张量后返回其 type/offset/dims[0..2]。
 * GGUF 的 tensor offset 是相对数据区起点的偏移（gguf.cpp:1406），数据区起点 =
 * metadata 末尾按 general.alignment 对齐后的位置。
 * 返回 0 = 找到；1 = 未找到；-1 = 格式错误 */
static int parse_gguf(FILE *fp, const char *tname, int64_t *dims, int *type, uint64_t *offset, uint64_t *data_base)
{
    char magic[4]; uint32_t v32; uint64_t v64;
    if (rd(fp, magic, 4) || memcmp(magic, "GGUF", 4)) return -1;
    if (rd_u32(fp, &v32)) return -1;                    /* version */
    if (rd_u64(fp, &v64)) return -1;                    /* n_tensors */
    uint64_t n_tensors = v64;
    if (rd_u64(fp, &v64)) return -1;                    /* n_kv */
    uint64_t n_kv = v64;

    uint32_t alignment = 32;                            /* GGUF 默认对齐 */
    for (uint64_t k = 0; k < n_kv; k++) {
        uint64_t nlen;
        if (rd_u64(fp, &nlen) || nlen >= 256) return -1;
        char kbuf[256];
        if (rd(fp, kbuf, (size_t)nlen)) return -1;
        kbuf[nlen] = 0;
        uint32_t vt;
        if (rd_u32(fp, &vt)) return -1;
        if (k < 8) fprintf(stderr, "KV[%llu] name=%s type=%u pos=%ld\n", (unsigned long long)k, kbuf, vt, ftell(fp));
        if (strcmp(kbuf, "general.alignment") == 0 && (vt == KV_U32 || vt == KV_I32)) {
            if (rd_u32(fp, &v32)) return -1;
            alignment = v32;
        } else if (skip_value(fp, vt)) { fprintf(stderr, "KV skip fail at %s type=%u\n", kbuf, vt); return -1; }
        if (k < 8) fprintf(stderr, "   -> after skip pos=%ld\n", ftell(fp));
    }
    fprintf(stderr, "KV loop end pos=%ld\n", ftell(fp));

    uint64_t meta_end = 0;
    int found = 0;
    for (uint64_t t = 0; t < n_tensors; t++) {
        uint64_t nlen;
        if (rd_u64(fp, &nlen)) return -1;
        if (nlen >= 128) return -1;
        char name[128];
        if (rd(fp, name, (size_t)nlen)) return -1;
        name[nlen] = 0;
        uint32_t nd;
        if (rd_u32(fp, &nd) || nd > 4) return -1;
        int64_t tdims[4] = {0};
        for (uint32_t i = 0; i < nd; i++) {
            if (rd_u64(fp, &v64)) return -1;
            tdims[i] = (int64_t)v64;
        }
        uint32_t ty;
        if (rd_u32(fp, &ty)) return -1;
        if (rd_u64(fp, &v64)) return -1;
        meta_end = (uint64_t)ftell(fp);
        if (!found && strcmp(name, tname) == 0) {
            *type = (int)ty; *offset = v64;
            for (uint32_t i = 0; i < nd; i++) dims[i] = tdims[i];
            found = 1;
        }
    }
    if (!found) { fprintf(stderr, "tensor info loop end pos=%ld\n", ftell(fp)); return 1; }
    /* 数据区起点 = 全部 tensor info 之后、按 alignment 对齐（gguf.cpp:757-764） */
    *data_base = pad64(meta_end, alignment);
    return 0;
}

static const char *type_name(int t)
{
    switch (t) {
    case GGML_TYPE_Q5_0:  return "Q5_0";
    case GGML_TYPE_Q8_0:  return "Q8_0";
    case GGML_TYPE_IQ3_XXS:return "IQ3_XXS";
    case GGML_TYPE_IQ3_S: return "IQ3_S";
    case GGML_TYPE_IQ1_M: return "IQ1_M";
    case GGML_TYPE_F32:   return "F32";
    default:              return "other";
    }
}

static void print_row_stats(const float *row, int64_t d0, int r)
{
    double s = 0, ss = 0, mn = 1e30, mx = -1e30;
    long long nz = 0;
    for (int64_t i = 0; i < d0; i++) {
        double v = row[i];
        s += v; ss += v * v;
        if (v < mn) mn = v;
        if (v > mx) mx = v;
        if (v != 0.0) nz++;
    }
    double rms = sqrt(ss / (double)d0);
    printf("row %3d: min=%+.4f max=%+.4f rms=%+.4f mean=%+.4f nonzero=%lld/%lld (%.1f%%)\n",
           r, mn, mx, rms, s / d0, nz, (long long)d0, 100.0 * nz / d0);
}

int main(int argc, char **argv)
{
    if (argc != 5) {
        fprintf(stderr, "usage: %s <model.gguf> <tensor> <rows> <out.f32bin>\n", argv[0]);
        return 2;
    }
    const char *gguf_path = argv[1];
    const char *tname     = argv[2];
    int         nrows     = atoi(argv[3]);
    const char *out_path  = argv[4];

    FILE *fp = fopen(gguf_path, "rb");
    if (!fp) { fprintf(stderr, "cannot open: %s\n", gguf_path); return 2; }

    int64_t dims[4] = {0};
    int type = -1;
    uint64_t offset = 0, data_base = 0;
    int rc = parse_gguf(fp, tname, dims, &type, &offset, &data_base);
    if (rc != 0) { fprintf(stderr, "tensor '%s' not found (rc=%d)\n", tname, rc); return 2; }
    const int64_t d0 = dims[0];
    printf("tensor=%s type=%s offset=%llu data_base=%llu dims=(%lld,%lld,%lld)\n",
           tname, type_name(type), (unsigned long long)offset, (unsigned long long)data_base,
           (long long)dims[0], (long long)dims[1], (long long)dims[2]);

    int qk = 0; size_t bsz = 0;
    void (*deq)(const void *, float *, int64_t) = NULL;
    switch (type) {
    case GGML_TYPE_Q5_0:  qk = 32;  bsz = sizeof(block_q5_0);  deq = (void(*)(const void*,float*,int64_t))dequantize_row_q5_0;  break;
    case GGML_TYPE_Q8_0:  qk = 32;  bsz = sizeof(block_q8_0);  deq = (void(*)(const void*,float*,int64_t))dequantize_row_q8_0;  break;
    case GGML_TYPE_IQ2_S: qk = 256; bsz = sizeof(block_iq2_s);  deq = (void(*)(const void*,float*,int64_t))dequantize_row_iq2_s; break;
    case GGML_TYPE_IQ3_XXS:qk = 256; bsz = sizeof(block_iq3_xxs);deq = (void(*)(const void*,float*,int64_t))dequantize_row_iq3_xxs; break;
    case GGML_TYPE_IQ3_S: qk = 256; bsz = sizeof(block_iq3_s);  deq = (void(*)(const void*,float*,int64_t))dequantize_row_iq3_s; break;
    case GGML_TYPE_IQ1_M: qk = 256; bsz = sizeof(block_iq1_m);  deq = (void(*)(const void*,float*,int64_t))dequantize_row_iq1_m; break;
    case GGML_TYPE_F32:   qk = 1;   bsz = 4;                    break;
    default:
        fprintf(stderr, "unsupported type %d (name=%s)\n", type, tname);
        return 2;
    }
    if (d0 % qk != 0) { fprintf(stderr, "d0=%lld not multiple of qk=%d\n", (long long)d0, qk); return 2; }
    const int64_t nblk_row = d0 / qk;
    const size_t rowbytes  = (size_t)nblk_row * bsz;
    const uint64_t abs_off = data_base + offset;

    if (fseek(fp, (long)abs_off, SEEK_SET)) { fprintf(stderr, "seek to tensor fail\n"); return 2; }

    float *row = malloc((size_t)d0 * 4);
    uint8_t *vx = (type == GGML_TYPE_F32) ? (uint8_t *)row : malloc(rowbytes);
    FILE *fo = fopen(out_path, "wb");
    if (!fo) { fprintf(stderr, "cannot write %s\n", out_path); return 2; }

    for (int r = 0; r < nrows; r++) {
        /* 读原始量化字节到独立缓冲，dequant 到 row（避免原地覆盖后续 block） */
        if (rd(fp, vx, rowbytes)) {
            fprintf(stderr, "read fail row %d\n", r); return 2;
        }
        if (type != GGML_TYPE_F32) deq(vx, row, d0); else memcpy(row, vx, rowbytes);
        fwrite(row, 4, (size_t)d0, fo);
        double s = 0, ss = 0, mn = 1e30, mx = -1e30;
        long long nz = 0;
        for (int64_t i = 0; i < d0; i++) {
            double v = row[i];
            s += v; ss += v * v;
            if (v < mn) mn = v;
            if (v > mx) mx = v;
            if (v != 0.0) nz++;
        }
        double rms = sqrt(ss / (double)d0);
        printf("row %3d: min=%+.4f max=%+.4f rms=%+.4f mean=%+.4f nonzero=%lld/%lld (%.1f%%)\n",
               r, mn, mx, rms, s / d0, nz, (long long)d0, 100.0 * nz / d0);
    }
    fclose(fo); fclose(fp);
    if (vx != (uint8_t *)row) free(vx);
    free(row);
    printf("wrote %d rows x %lld fp32 -> %s\n", nrows, (long long)d0, out_path);
    return 0;
}
