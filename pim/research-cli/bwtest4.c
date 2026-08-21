#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <pthread.h>
#include <stdint.h>
#include <immintrin.h>

static unsigned char *dst, *src;
static int BS, N_BLK, GAP, ITERS, MODE, NTH;
static int64_t cur_blk;
static pthread_barrier_t bar;
static double now(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec*1e-9;}

static void nt_copy(unsigned char *d, const unsigned char *s, size_t n){
  size_t i=0;
  for(; i+64<=n; i+=64){
    __m256i a=_mm256_stream_load_si256((const __m256i*)(s+i));
    __m256i b=_mm256_stream_load_si256((const __m256i*)(s+i+32));
    _mm256_stream_si256((__m256i*)(d+i),a);
    _mm256_stream_si256((__m256i*)(d+i+32),b);
  }
  for(; i<n; i++) d[i]=s[i];
  _mm_sfence();
}

static void *th(void*a){
  int id = *(int*)a;
  int64_t base = (int64_t)BS*N_BLK*id;
  for(int it=0; it<ITERS; it++){
    if(MODE==0){
      for(int blk=id; blk<N_BLK; blk+=NTH){
        memcpy(dst+(int64_t)blk*(BS+GAP), src+base+(int64_t)blk*BS, BS);
      }
    } else {
      for(int blk=id; blk<N_BLK; blk+=NTH){
        nt_copy(dst+(int64_t)blk*(BS+GAP), src+base+(int64_t)blk*BS, BS);
      }
    }
  }
  return NULL;
}

int main(int argc,char**argv){
  NTH   = argc>1?atoi(argv[1]):8;
  int kb= argc>2?atoi(argv[2]):440;
  N_BLK = argc>3?atoi(argv[3]):33;
  GAP   = argc>4?atoi(argv[4]):0;
  MODE  = argc>5?atoi(argv[5]):0;
  ITERS = argc>6?atoi(argv[6]):100;
  BS=kb*1024;
  int64_t stride=BS+GAP;
  int64_t dst_size=stride*N_BLK;
  int64_t src_size=(int64_t)BS*N_BLK*NTH;
  dst=malloc(dst_size); src=malloc(src_size);
  (void)posix_memalign((void**)&dst, 64, dst_size);
  (void)posix_memalign((void**)&src, 64, src_size);
  memset(dst,1,dst_size); memset(src,2,src_size);
  pthread_t ths[32]; int ids[32];
  pthread_barrier_init(&bar, NULL, NTH);
  double t0=now();
  for(int i=0;i<NTH;i++){ids[i]=i; cur_blk=0; pthread_create(&ths[i],0,th,&ids[i]);}
  for(int i=0;i<NTH;i++) pthread_join(ths[i],0);
  double dt=now()-t0;
  double gbs=(double)BS*N_BLK*ITERS/dt/1e9;
  printf("nth=%2d blk=%dKB nblk=%d gap=%d mode=%s iters=%d  %.2f GiB/s\n",
    NTH,kb,N_BLK,GAP,MODE?"nt":"memcpy",ITERS,gbs);
  return 0;
}