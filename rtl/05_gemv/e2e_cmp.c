/* e2e_cmp.c — 端到端对拍：RTL 数字外围输出 vs CPU double 参考。
 *
 * RTL periph_mac 的结果已经由 periph_mac_tb.v 逐位 assert 等于 expected.hex
 * （设备 golden），所以这里 READ ONLY 两个文件：
 *   expected.hex      RTL 输出（≡ 设备 fp32 外围）
 *   expected_cpu.hex  CPU double 参考（pim_mxfp4_gemv）
 * 统计口径与 sim_cim.c 完全一致：
 *   maxrel   最大化相对误差（被近零点积分母→0 放大，看看就好）
 *   p99.9    第 99.9 百分位相对误差
 *   normrms  max|err|/RMS(ref) —— 对信号尺度归一，设备/CPU 差别的真实口径
 * 契约：设备不逐位等于 CPU（fp32 外围 vs double），误差落在容限内。
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

static int load_hex(const char *path, float **out, int *n)
{
    FILE *fp = fopen(path, "r");
    if (!fp) { perror(path); return -1; }
    int cap = 64, m = 0;
    *out = malloc((size_t)cap * 4);
    char line[64];
    while (fgets(line, sizeof line, fp)) {
        uint32_t u;
        if (sscanf(line, "%8x", &u) != 1) continue;
        if (m == cap) { cap *= 2; *out = realloc(*out, (size_t)cap * 4); }
        memcpy(&(*out)[m++], &u, 4);
    }
    fclose(fp);
    *n = m;
    return 0;
}

static int cmp_d(const void *a, const void *b)
{
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}

int main(int argc, char **argv)
{
    const char *devp = argc > 1 ? argv[1] : "expected.hex";
    const char *cpup = argc > 2 ? argv[2] : "expected_cpu.hex";
    float *dev, *cpu;
    int n, m;
    if (load_hex(devp, &dev, &n) || load_hex(cpup, &cpu, &m)) return 2;
    if (n != m) { fprintf(stderr, "行数不一致 dev=%d cpu=%d\n", n, m); return 3; }

    double maxabs = 1.0, sumsq = 0;
    for (int i = 0; i < n; i++) {
        if (fabs((double)cpu[i]) > maxabs) maxabs = fabs((double)cpu[i]);
        sumsq += (double)cpu[i] * (double)cpu[i];
    }
    double rms = sqrt(sumsq / n);
    static double rels[8192];
    double normmax = 0;
    int bitdiff = 0;
    for (int i = 0; i < n; i++) {
        uint32_t a, b;
        memcpy(&a, &dev[i], 4); memcpy(&b, &cpu[i], 4);
        if (a != b) bitdiff++;
        double r = fabs((double)cpu[i]);
        double d = fabs((double)dev[i] - (double)cpu[i]);
        rels[i] = (r > 0) ? d / r : d / maxabs;
        double nn = d / rms;
        if (nn > normmax) normmax = nn;
    }
    qsort(rels, n, sizeof(double), cmp_d);

    printf("== 端到端对拍: RTL 数字外围 vs CPU double 参考 ==\n");
    printf("  %d 行长累积 y  比特不一致行: %d / %d\n", n, bitdiff, n);
    printf("  maxrel      = %.3e   (近零点积分母→0，会被放大)\n", rels[n - 1]);
    printf("  p99.9       = %.3e\n", rels[(int)((n - 1) * 0.999)]);
    printf("  max|err|RMS = %+.2e   (对信号尺度的真实误差，契约口径)\n", normmax);

    if (normmax < 2e-2) printf("=== ALL PASS（容限 2e-2 RMS，对应 sim_cim 理想 8/12 档 1.63e-2）===\n");
    else { printf("=== 超出容限（>2e-2 RMS）===\n"); return 1; }

    for (int i = 0; i < n && i < 5; i++) {
        uint32_t a, b; memcpy(&a, &dev[i], 4); memcpy(&b, &cpu[i], 4);
        if (a != b) printf("  前若干差异行 [%d]: dev=%08x cpu=%08x\n", i, a, b);
    }
    return 0;
}