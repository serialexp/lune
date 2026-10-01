/* bench/embed — timing + reporting helpers shared by the host programs.
 *
 * Output protocol (parsed by run.py):
 *   bench <op> <ns_per_op> <checksum>
 *   maxrss_kb <n>
 * Any failure: print "FAIL <op>: <detail>" and exit non-zero.
 */
#ifndef BENCH_EMBED_COMMON_H
#define BENCH_EMBED_COMMON_H

#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/resource.h>
#include <time.h>

static inline uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static inline void report(const char *op, uint64_t elapsed_ns, long long ops, long long checksum) {
    printf("bench %s %.2f %lld\n", op, (double)elapsed_ns / (double)ops, checksum);
}

static inline void report_maxrss(void) {
    struct rusage ru;
    getrusage(RUSAGE_SELF, &ru);
    printf("maxrss_kb %ld\n", ru.ru_maxrss);
}

#define FAIL(op, detail)                                  \
    do {                                                  \
        fprintf(stderr, "FAIL %s: %s\n", (op), (detail)); \
        exit(1);                                          \
    } while (0)

#endif /* BENCH_EMBED_COMMON_H */
