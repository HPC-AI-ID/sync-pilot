/**
 * no_affinity.c - LD_PRELOAD intercept for CFS baseline measurement
 *
 * Override pthread_setaffinity_np to a no-op so that IC-RCE's affinity
 * hints are silently ignored and the Linux CFS scheduler is free to
 * place threads on any core without constraint.
 *
 * Build:
 *   gcc -shared -fPIC -o no_affinity.so no_affinity.c
 *
 * Usage:
 *   LD_PRELOAD=./no_affinity.so ./fsrcnn_thread20 input.yuv output.yuv 20
 */

#define _GNU_SOURCE
#include <pthread.h>

/* Override: pthread_setaffinity_np → no-op → CFS decides freely */
int pthread_setaffinity_np(pthread_t thread,
                            size_t cpusetsize,
                            const cpu_set_t *cpuset)
{
    (void)thread;
    (void)cpusetsize;
    (void)cpuset;
    return 0;   /* always succeed, do nothing */
}
