#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <omp.h>

int main(int argc, char* argv[]) {
    int num_threads = 4;
    if (argc > 1) {
        num_threads = atoi(argv[1]);
    }
    printf("Memulai System Noise (%d Threads tanpa Affinity)...\n", num_threads);
    // Set thread agar CFS menaruhnya di Big Core secara default
    omp_set_num_threads(num_threads);

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
