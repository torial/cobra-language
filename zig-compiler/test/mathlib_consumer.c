#include "mathlib_test.h"
#include <stdio.h>

int main(void) {
    int64_t sum  = MathLib_add(10, 32);
    int64_t prod = MathLib_mul(6, 7);
    double  clmp = MathLib_clamp(1.5, 0.0, 1.0);
    bool    even = MathLib_isEven(42);
    printf("add(10,32)=%lld  mul(6,7)=%lld  clamp(1.5,0,1)=%.1f  isEven(42)=%d\n",
           (long long)sum, (long long)prod, clmp, (int)even);
    return 0;
}
