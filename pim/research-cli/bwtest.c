#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <pthread.h>
static unsigned char *dst, *src;
static int NB;             /* bytes per thread */
static int ITERS;
static double now(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec*1e-9;}
static void *th(void*a){int id=*(int*)a; size_t off=(size_t)id*NB;
  for(int i=0;i<ITERS;i++) memcpy(dst+off,src+off,NB); return NULL;}
int main(int argc,char**argv){
  int nth = argc>1?atoi(argv[1]):1;
  int mb  = argc>2?atoi(argv[2]):256;   /* MB per thread */
  ITERS   = argc>3?atoi(argv[3]):10;
  NB = mb<<20;
  dst=malloc(NB*nth);src=malloc(NB*nth);
  memset(dst,1,NB*nth);memset(src,2,NB*nth);
  pthread_t ths[64]; int ids[64];
  for(int i=0;i<nth;i++){ids[i]=i;pthread_create(&ths[i],0,th,&ids[i]);}
  double t0=now();
  for(int i=0;i<nth;i++) pthread_join(ths[i],0);
  double dt=now()-t0;
  printf("nth=%2d blk=%dMB iters=%d  %.2f GiB/s\n", nth, mb, ITERS, (double)(size_t)NB*nth*ITERS/dt/1e9);
  return 0;
}