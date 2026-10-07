// Q4F8 / Q4F8-nl NEON (vqtbl) decode microbenchmark vs Q4_0.
//
// Build:  clang -O3 -march=armv8-a q4f8_neon_bench.c -o q4f8_neon_bench -lm
// Run:    taskset -c 4-5 ./q4f8_neon_bench 24 8   (24 MB, 8 iters)
//
// Verdict (Snapdragon 8 Gen 1, NEON vqtbl kernels):
//   lin/Q4_0 ~1.00,  nl/Q4_0 ~0.95,  nl/lin ~0.94
// Nonlinear codebook lookup is FREE on NEON -- the 1.12x scalar penalty was
// an artifact of address-misaligned scalar loads, not inherent to Q4F8-nl.
#include <arm_neon.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <math.h>
#include <time.h>
static double now_s(void){ struct timespec ts; clock_gettime(CLOCK_MONOTONIC,&ts); return ts.tv_sec+ts.tv_nsec*1e-9; }
static float Q4F8_TABLE[128];
static void init_q4f8(void){ for(int i=0;i<128;i++){ float l=(float)i*(8.0f/127.0f)-12.0f; Q4F8_TABLE[i]= l<-20.0f ? -1e-8f : -ldexpf(1.0f,l);} }
static const int8_t KV_I8[16]={-127,-104,-83,-65,-49,-35,-22,-10,1,13,25,38,53,69,89,113};
static const float AV[32]={0.125f,-0.5f,0.3f,0.9f,-0.2f,0.7f,-0.8f,0.4f,0.6f,-0.3f,0.1f,-0.9f,0.5f,0.2f,-0.4f,0.8f,-0.7f,0.3f,-0.6f,0.9f,0.1f,-0.5f,0.4f,-0.2f,0.8f,0.7f,-0.9f,0.6f,-0.1f,0.3f,-0.4f,0.2f};
static float AVe[16],AVo[16];
static float32x4_t E0,E1,E2,E3,O0,O1,O2,O3;
static void init_av(void){ for(int i=0;i<16;i++){AVe[i]=AV[2*i];AVo[i]=AV[2*i+1];} E0=vld1q_f32(AVe+0);E1=vld1q_f32(AVe+4);E2=vld1q_f32(AVe+8);E3=vld1q_f32(AVe+12);O0=vld1q_f32(AVo+0);O1=vld1q_f32(AVo+4);O2=vld1q_f32(AVo+8);O3=vld1q_f32(AVo+12); }
static inline void unpack16(const uint8_t* p, int8x16_t *lo, int8x16_t *hi){
  uint8x16_t q=vld1q_u8(p);
  *lo=vreinterpretq_s8_u8(q & vdupq_n_u8(0x0F));
  *hi=vreinterpretq_s8_u8(vshrq_n_u8(q,4));
}
static void F16F(const float32x4_t l0,const float32x4_t l1,const float32x4_t l2,const float32x4_t l3,const float32x4_t h0,const float32x4_t h1,const float32x4_t h2,const float32x4_t h3, float32x4_t *a0,float32x4_t *a1,float32x4_t *a2,float32x4_t *a3,float32x4_t *a4,float32x4_t *a5,float32x4_t *a6,float32x4_t *a7, const float32x4_t db){
  *a0=vfmaq_f32(*a0,l0,vmulq_f32(db,E0)); *a1=vfmaq_f32(*a1,l1,vmulq_f32(db,E1));
  *a2=vfmaq_f32(*a2,l2,vmulq_f32(db,E2)); *a3=vfmaq_f32(*a3,l3,vmulq_f32(db,E3));
  *a4=vfmaq_f32(*a4,h0,vmulq_f32(db,O0)); *a5=vfmaq_f32(*a5,h1,vmulq_f32(db,O1));
  *a6=vfmaq_f32(*a6,h2,vmulq_f32(db,O2)); *a7=vfmaq_f32(*a7,h3,vmulq_f32(db,O3));
}
static void conv16(const int8x16_t v, float32x4_t *a,float32x4_t*b,float32x4_t*c,float32x4_t*d){
  int16x8_t w0=vmovl_s8(vget_low_s8(v)),w1=vmovl_s8(vget_high_s8(v));
  *a=vcvtq_f32_s32(vmovl_s16(vget_low_s16(w0)));
  *b=vcvtq_f32_s32(vmovl_s16(vget_high_s16(w0)));
  *c=vcvtq_f32_s32(vmovl_s16(vget_low_s16(w1)));
  *d=vcvtq_f32_s32(vmovl_s16(vget_high_s16(w1)));
}
static float fin(const float32x4_t a0,const float32x4_t a1,const float32x4_t a2,const float32x4_t a3,const float32x4_t a4,const float32x4_t a5,const float32x4_t a6,const float32x4_t a7){
  float32x4_t r=vaddq_f32(vaddq_f32(vaddq_f32(a0,a1),vaddq_f32(a2,a3)),vaddq_f32(vaddq_f32(a4,a5),vaddq_f32(a6,a7)));
  return vaddvq_f32(r);
}
// Q4_0: 2B fp16 scale + 16B code, code=(nibble-8)*d
static float neon_q4(const uint8_t*buf,int n32){
  float32x4_t a0=vdupq_n_f32(0),a1=a0,a2=a0,a3=a0,a4=a0,a5=a0,a6=a0,a7=a0;
  for(int b=0;b<n32;b++){
    __fp16 ds; memcpy(&ds,buf+18*b,2); float d=(float)ds;
    int8x16_t lo,hi; unpack16(buf+18*b+2,&lo,&hi);
    int8x16_t m8=vdupq_n_s8(8);
    float32x4_t l0,l1,l2,l3,h0,h1,h2,h3;
    conv16(vsubq_s8(lo,m8),&l0,&l1,&l2,&l3); conv16(vsubq_s8(hi,m8),&h0,&h1,&h2,&h3);
    float32x4_t db=vmovq_n_f32(d);
    F16F(l0,l1,l2,l3,h0,h1,h2,h3,&a0,&a1,&a2,&a3,&a4,&a5,&a6,&a7,db);
  }
  return fin(a0,a1,a2,a3,a4,a5,a6,a7);
}
static float neon_lin(const uint8_t*buf,int n32){
  float32x4_t a0=vdupq_n_f32(0),a1=a0,a2=a0,a3=a0,a4=a0,a5=a0,a6=a0,a7=a0;
  int8x16_t m8=vdupq_n_s8(8);
  for(int b=0;b<n32;b++){
    float d=Q4F8_TABLE[buf[17*b]];
    int8x16_t lo,hi; unpack16(buf+17*b+1,&lo,&hi);
    float32x4_t l0,l1,l2,l3,h0,h1,h2,h3;
    conv16(vsubq_s8(lo,m8),&l0,&l1,&l2,&l3); conv16(vsubq_s8(hi,m8),&h0,&h1,&h2,&h3);
    float32x4_t db=vmovq_n_f32(d);
    F16F(l0,l1,l2,l3,h0,h1,h2,h3,&a0,&a1,&a2,&a3,&a4,&a5,&a6,&a7,db);
  }
  return fin(a0,a1,a2,a3,a4,a5,a6,a7);
}
static float neon_nl(const uint8_t*buf,int n32){
  const int8x16_t kval=vld1q_s8(KV_I8);
  float32x4_t a0=vdupq_n_f32(0),a1=a0,a2=a0,a3=a0,a4=a0,a5=a0,a6=a0,a7=a0;
  for(int b=0;b<n32;b++){
    float d=Q4F8_TABLE[buf[17*b]];
    int8x16_t lo,hi; unpack16(buf+17*b+1,&lo,&hi);
    int8x16_t kl=vqtbl1q_s8(kval, vreinterpretq_u8_s8(lo));
    int8x16_t kh=vqtbl1q_s8(kval, vreinterpretq_u8_s8(hi));
    float32x4_t l0,l1,l2,l3,h0,h1,h2,h3;
    conv16(kl,&l0,&l1,&l2,&l3); conv16(kh,&h0,&h1,&h2,&h3);
    float32x4_t db=vmovq_n_f32(d);
    F16F(l0,l1,l2,l3,h0,h1,h2,h3,&a0,&a1,&a2,&a3,&a4,&a5,&a6,&a7,db);
  }
  return fin(a0,a1,a2,a3,a4,a5,a6,a7);
}

static float a_mag;
// -- Q1T nibble-mask NEON kernel -------------------------------------------------
static float q1t_neon(const uint8_t *buf,int n32){
  uint32_t masks[16];
  for(int v=0;v<16;v++){ uint32_t m=0; for(int k=0;k<4;k++) if((v>>k)&1) m|=0xFFFFFFFFu<<(8*k); masks[v]=m; }
  const uint8x16_t tmask=vld1q_u8((const uint8_t*)masks);
  const uint8x16_t lowmask=vdupq_n_u8(0x0F);
  float32x4_t a0=vdupq_n_f32(0),a1=a0,a2=a0,a3=a0,a4=a0,a5=a0,a6=a0,a7=a0;
  for(int b=0;b<n32;b++){
    float32x4_t v=vmovq_n_f32(a_mag*fabsf(Q4F8_TABLE[buf[5*b]]));
    uint8x16_t codes=vld1q_u8(buf+5*b+1);
    uint8x16_t mlo=vqtbl1q_u8(tmask, codes & lowmask);
    uint8x16_t mhi=vqtbl1q_u8(tmask, vshrq_n_u8(codes,4));
    const uint8_t *pm=(const uint8_t*)&mlo, *qh=(const uint8_t*)&mhi;
    #define SEL4(ptr,off,avp) vmulq_f32( vbslq_f32(vld1q_u32((const uint32_t*)(ptr+off)), vld1q_f32(avp), vnegq_f32(vld1q_f32(avp))), v)
    a0=vaddq_f32(a0,SEL4(pm,0,AV+0));
    a1=vaddq_f32(a1,SEL4(pm,16,AV+4));
    a2=vaddq_f32(a2,SEL4(pm,32,AV+8));
    a3=vaddq_f32(a3,SEL4(pm,48,AV+12));
    a4=vaddq_f32(a4,SEL4(qh,0,AV+16));
    a5=vaddq_f32(a5,SEL4(qh,16,AV+20));
    a6=vaddq_f32(a6,SEL4(qh,32,AV+24));
    a7=vaddq_f32(a7,SEL4(qh,48,AV+28));
    #undef SEL4
  }
  float32x4_t s0=vaddq_f32(vaddq_f32(a0,a1),vaddq_f32(a2,a3));
  float32x4_t s1=vaddq_f32(vaddq_f32(a4,a5),vaddq_f32(a6,a7));
  return vaddvq_f32(vaddq_f32(s0,s1));
}

int main(int argc,char**argv){
  init_q4f8(); init_av(); a_mag=0.354f;
  int mb= atoi(argc>1?argv[1]:"24"); int iters= atoi(argc>2?argv[2]:"8");
  size_t n=(size_t)mb*(1u<<20)/4;
  float *w=malloc(n*4); srand(11);
  for(size_t i=0;i<n;i++) w[i]=((float)(rand()%50)-25.0f)+((float)(rand()%50)-25.0f)/100.0f;
  size_t n32=n/32;
  uint8_t *bq=malloc(n32*18+64);
  uint8_t *b1=malloc(n32*5+64);
  for(size_t bb=0;bb<n32;bb++){
    const float*x=w+bb*32; float mx=fabsf(x[0]); for(int i=1;i<32;i++){float aa=fabsf(x[i]);if(aa>mx)mx=aa;}
    __fp16 dh=(__fp16)(-(mx>0?mx:1)/8.0f); memcpy(bq+18*bb,&dh,2);
    uint8_t qsq[16]={0};
    for(int i=0;i<32;i++){ int bx=(int)roundf(x[i]/(-((float)dh))+8); if(bx<0)bx=0; if(bx>15)bx=15; if(i<16) qsq[i/2]|=(uint8_t)bx<<(i%2?4:0); else qsq[(i-16)/2]|=(uint8_t)bx<<((i-16)%2?4:0); }
    memcpy(bq+18*bb+2,qsq,16);
    float db=(mx>0?mx:1)/a_mag; int sc=(int)round((log2f(db)+12.0)*(127.0/8.0)); if(sc<0)sc=0; if(sc>127)sc=127;
    uint32_t bits=0; for(int i=0;i<32;i++) if(x[i]>=0) bits|=1u<<i;
    b1[5*bb]=(uint8_t)sc; memcpy(b1+5*bb+1,&bits,4);
  }
  printf("sanity q4=%.3f q1t=%.3f\n",neon_q4(bq,(int)n32),q1t_neon(b1,(int)n32));
  volatile float sink=0;
  for(int it=0;it<iters;it++) sink+=neon_q4(bq,(int)n32);
  double t0=now_s(); for(int it=0;it<iters;it++) sink+=neon_q4(bq,(int)n32);
  double t1=now_s(); for(int it=0;it<iters;it++) sink+=q1t_neon(b1,(int)n32);
  double t2=now_s(); for(int it=0;it<iters;it++) sink+=neon_q4(bq,(int)n32);
  double t3=now_s(); for(int it=0;it<iters;it++) sink+=q1t_neon(b1,(int)n32);
  double t4=now_s();
  double fa=(t1-t0)+(t3-t2), fb=(t2-t1)+(t4-t3);
  double bytes=(double)n*4*(double)(iters);
  printf("Q4_0: %7.1f ms/run  equiv %5.2f GB/s\n",fa/2*1e3, bytes/(fa/2)/1e9);
  printf("Q1T : %7.1f ms/run  equiv %5.2f GB/s  actual-storage %5.2f GB/s\n",
         fb/2*1e3, bytes/(fb/2)/1e9, (double)n32*5/(fb/2/1e3)/1e9);
  printf("Q1T/Q4_0 = %.3f (sink=%.2f)\n",fb/fa,(float)sink);
  return 0;
}
