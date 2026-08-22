#include <stdio.h>
int main() {
    unsigned long hwcaps = 0;
    FILE *f = fopen("/proc/self/auxv", "rb");
    if (f) { /* simple check */ fclose(f); }
    printf("sizeof(int): %zu\n", sizeof(int));
    #if defined(__ARM_FEATURE_DOTPROD)
    printf("DOTPROD: YES\n");
    #else
    printf("DOTPROD: NO (compile-time)\n");
    #endif
    return 0;
}
