#include <stdio.h>
#include <math.h>
#include <omp.h>

int main() {
    printf("Memulai System Noise (4 Threads tanpa Affinity)...\n");
    // Set 4 thread agar CFS menaruhnya di Big Core secara default
    omp_set_num_threads(4);

    #pragma omp parallel
    {
        // Infinite loop yang membuat CPU sibuk (simulasi UI/Network stack)
        volatile double x = 1.0;
        while(1) {
            x = sqrt(x + 1.0) * sin(x);
        }
    }
    return 0;
}
