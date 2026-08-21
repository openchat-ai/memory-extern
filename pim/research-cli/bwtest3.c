#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <pthread.h>
#include <stdint.h>

/* Simulate chip copy layout: per-op atomic chunk claiming of N_BLK blocks,
 * each BS bytes, into a spread destination (stride = BS + gap). */
static unsigned char *dst, *src;
static int BS, N_BLK, GAP, ITERS, MODE, NTH;
static int64_t cur_blk;
static pthread_barrier_t bar;
static double now(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec*1e-9;}

static void *th(void*a){
  int id = *(int*)a;
  int64_t base = (int64_t)BS*N_BLK*id;  /* per-thread source region to avoid fake sharing */
  for(int it=0; it<ITERS; it++){
    if(MODE==0){ /* static split: stride=NTH */
      for(int blk=id; blk<N_BLK; blk+=NTH){
        memcpy(dst+(int64_t)blk*(BS+GAP), src+base+(int64_t)blk*BS, BS);
      }
    } else { /* atomic claim, per-op restart like chip copy_next */
      if(id==0) __atomic_store_n(&cur_blk,0,__ATOMIC_RELAXED);
      pthread_barrier_wait(&bar);
      for(;;){
        int64_t b = __atomic_fetch_add(&cur_blk,1,__ATOMIC_RELAXED);
        if(b>=N_BLK) break;
        memcpy(dst+(int64_t)b*(BS+GAP), src+base+(int64_t)b*BS, BS);
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
  memset(dst,1,dst_size); memset(src,2,src_size);
  pthread_t ths[32]; int ids[32];
  pthread_barrier_init(&bar, NULL, NTH);
  double t0=now();
  for(int i=0;i<NTH;i++){ids[i]=i; cur_blk=0; pthread_create(&ths[i],0,th,&ids[i]);}
  for(int i=0;i<NTH;i++) pthread_join(ths[i],0);
  double dt=now()-t0;
  double gbs=(double)BS*N_BLK*ITERS/dt/1e9;
  printf("nth=%2d blk=%dKB nblk=%d gap=%d mode=%s iters=%d  %.2f GiB/s  (%.1f us/op)\n",
    NTH,kb,N_BLK,GAP,MODE?"atomic":"static",ITERS,gbs,dt*1e6/ITERS);
  return 0;
}