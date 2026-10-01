/* bench/embed — shared guest programs and iteration counts.
 *
 * Both host programs (bench_mahina.c, bench_lua.c) include this so every
 * engine runs byte-identical guest code with identical rep counts; the
 * runner cross-checks the printed checksums (the parity half of the suite,
 * like bench/run.py's cross/luajit columns).
 */
#ifndef BENCH_EMBED_SOURCES_H
#define BENCH_EMBED_SOURCES_H

/* host->guest: one trivial guest function, called N times from the host. */
#define SRC_ID_FN "function id(x) return x end"
#define N_CALL 200000

/* guest->host: a guest loop hammering a registered host function. */
#define SRC_CALLBACK_LOOP \
    "local s = 0 for i = 1, 1000000 do s = s + host_id(i) end return s"
#define N_CALLBACK 1000000
#define CALLBACK_CHECKSUM 500000500000LL

/* table get/set: one reused guest-string key. */
#define TABLE_KEY "field"
#define N_TABLE 1000000

/* iteration: a hash-part-heavy table built by the guest, walked by the host. */
#define SRC_BUILD_BIG "big = {} for i = 1, 10000 do big['k' .. i] = i end"
#define BIG_ENTRIES 10000
#define BIG_VALUE_SUM 50005000LL
#define N_ITER_PASSES 30

/* ref churn: root + unroot a fresh guest string. */
#define REF_STRING "churn"
#define N_REF 200000

/* repeated compilation of a small chunk (never run). */
#define SRC_SMALL_CHUNK "local acc = 0 for i = 1, 10 do acc = acc + i end return acc"
#define N_COMPILE 20000

/* full eval round trip. */
#define SRC_EVAL "return 1 + 2"
#define N_EVAL 20000

#endif /* BENCH_EMBED_SOURCES_H */
