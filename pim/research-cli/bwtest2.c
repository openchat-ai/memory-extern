#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <pthread.h>
static unsigned char *dst, *src;
static int BS;             /* bytes per memcpy call */
static int ITERS;
static double now(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec*1e-9;}
static void *th(void*a){int id=*(int*)a;
  for(int i=0;i<ITERS;i++) memcpy(dst+(size_t)id*BS, src+(size_t)id*BS, BS); return NULL;}
int main(int argc,char**argv){
  int nth  = argc>1?atoi(argv[1]):1;
  int kb   = argc>2?atoi(argv[2]):426;   /* bytes per memcpy */
  ITERS    = argc>3?atoi(argv[3]):1000;
  BS = kb*1024;
  size_t total=(size_t)BS*nth;
  dst=malloc(total);src=malloc(total);
  memset(dst,1,total);memset(src,2,total);
  pthread_t ths[32]; int ids[32];
  double t0=now();
  for(int i=0;i<nth;i++){ids[i]=i;pthread_create(&ths[i],0,th,&ids[i]);}
  for(int i=0;i<nth;i++) pthread_join(ths[i],0);
  double dt=now()-t0;
  double gbs=(double)BS*nth*ITERS/dt/1e9;
  printf("nth=%2d blk=%dKB iters=%d  %.2f GiB/s  (%.1f us/op)\n", nth, kb, ITERS, gbs, dt*1e6/(ITERS));
  return 0;
}