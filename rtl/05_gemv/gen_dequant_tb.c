#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include "../../pim/mxfp4_gemv.h"

// dequant RTL TB 生成器：一个打包字节(2 nibble) + 1 scale → C 参考给出 2 个 fp32。
// 正确调用：rows=1, pcols=1(1字节打包), group=2 → width=2, ngrp=1。
// 输出 dq_packed.hex(每行1字节) dq_scale.hex(每行1 scale) dq_expected.hex(每行1 fp32, 2行/字节)
int main(void) {
    FILE *pk=fopen("dq_packed.hex","w");
    FILE *sc=fopen("dq_scale.hex","w");
    FILE *ex=fopen("dq_expected.hex","w");
    int count=0;
    for (int is=0; is<32; is++) {
        uint8_t s;
        switch(is) {
            case 0: s=0x00; break;   // scale 极端：2^-127
            case 1: s=0x01; break;
            case 2: s=0x7E; break;   // 常规负
            case 3: s=0x80; break;   // 常规
            case 4: s=0xFE; break;   // 溢出阈值
            case 5: s=0xFF; break;   // NaN
            default: s=(uint8_t)(0x75 + (is%0x20)); break;
        }
        for (int pb=0; pb<256; pb++) {
            float o[2];
            uint8_t p[1]={(uint8_t)pb};
            uint8_t ss[1]={s};
            pim_mxfp4_dequant(o, p, ss, 1, 1, 2);
            fprintf(pk,"%02x\n",pb);
            fprintf(sc,"%02x\n",s);
            uint32_t u0,u1; *(float*)&u0=o[0]; *(float*)&u1=o[1];
            fprintf(ex,"%08x\n",u0);
            fprintf(ex,"%08x\n",u1);
            count+=2;
        }
    }
    fclose(pk); fclose(sc); fclose(ex);
    fprintf(stderr,"wrote %d elements\n",count);
    return 0;
}
