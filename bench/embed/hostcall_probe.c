/* bench/embed — per-shape host-call probe (doc 60 §5.3 ledger).
 *
 * One call shape per run, so `perf stat` measures exactly that shape:
 *
 *   hostcall_probe <shape> <iters>
 *
 * Per-call cost = (counts at <iters>) - (counts at 0), divided by <iters>;
 * the 0-iteration run absorbs VM creation and script compile. Run with
 * MH_NOJIT=1 for the tier-0 boundary on its own (the guest bodies are
 * trivial, so the JIT has nothing to win and only adds tiering noise).
 *
 * Shapes (doc 60 §5.3: 0/1/4/8/9 arguments, 0/1/4 results, heap values,
 * vararg surplus, register-window size, result-park overflow):
 *   a0 a1 a4 a8 a9  N int arguments into an N-parameter function, 1 result
 *                   (9 is past the planned straight-line entry's limit: the
 *                   fallback cost once a hand-written entry exists)
 *   r0 r1 r4        0 arguments, 0/1/4 int results
 *   heap            1 string argument, the same string back (park in + out)
 *   vararg          3 int arguments into f(a, ...) (two-region layout)
 *   wide            1 argument into a 40-register window (nil-fill cost)
 *   overflow        8 string results: 2 past the inline park every call
 *
 * Informational, never a gate (global Rule #22).
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "mahina.h"

static const char script[] =
    "function a0() return 0 end\n"
    "function a1(a) return a end\n"
    "function a4(a, b, c, d) return d end\n"
    "function a8(a, b, c, d, e, f, g, h) return h end\n"
    "function a9(a, b, c, d, e, f, g, h, i) return i end\n"
    "function r0() end\n"
    "function r1() return 1 end\n"
    "function r4() return 1, 2, 3, 4 end\n"
    "function heap(s) return s end\n"
    "function vararg(a, ...) return a end\n"
    "function wide(a)\n"
    "  local b1, b2, b3, b4, b5, b6, b7, b8, b9, b10 = 1, 2, 3, 4, 5, 6, 7, 8, 9, 10\n"
    "  local c1, c2, c3, c4, c5, c6, c7, c8, c9, c10 = 1, 2, 3, 4, 5, 6, 7, 8, 9, 10\n"
    "  local d1, d2, d3, d4, d5, d6, d7, d8, d9, d10 = 1, 2, 3, 4, 5, 6, 7, 8, 9, 10\n"
    "  local e1, e2, e3, e4, e5, e6, e7, e8, e9 = 1, 2, 3, 4, 5, 6, 7, 8, 9\n"
    "  return a\n"
    "end\n"
    "function overflow() return 's1', 's2', 's3', 's4', 's5', 's6', 's7', 's8' end\n";

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: %s <shape> <iters>\n", argv[0]);
        return 2;
    }
    const char *shape = argv[1];
    long long iters = atoll(argv[2]);

    mh_vm *vm;
    mh_config cfg = {0};
    if (getenv("MH_NOJIT")) cfg.jit = 2;
    if (mh_vm_new(&cfg, &vm) != MH_OK) return 1;
    size_t n;
    mh_value out[8];
    if (mh_eval(vm, MH_STR(script), MH_STR("probe"), out, 0, &n) != MH_OK) {
        mh_str e = mh_last_error(vm);
        fprintf(stderr, "script: %.*s\n", (int)e.len, (const char *)e.ptr);
        return 1;
    }

    size_t nargs = 0, max_results = 1;
    mh_value args[9];
    for (int i = 0; i < 9; i++) args[i] = mh_int(i + 1);
    const char *fname = shape;
    if (strcmp(shape, "a0") == 0) nargs = 0;
    else if (strcmp(shape, "a1") == 0) nargs = 1;
    else if (strcmp(shape, "a4") == 0) nargs = 4;
    else if (strcmp(shape, "a8") == 0) nargs = 8;
    else if (strcmp(shape, "a9") == 0) nargs = 9;
    else if (strcmp(shape, "r0") == 0) max_results = 0;
    else if (strcmp(shape, "r1") == 0) max_results = 1;
    else if (strcmp(shape, "r4") == 0) max_results = 4;
    else if (strcmp(shape, "heap") == 0) {
        nargs = 1;
        /* Kept alive across the loop as each call's own argument (re-parked
         * by every call, mahina.h "VALUE LIFETIME"). */
        if (mh_string_new(vm, MH_STR("probe-string"), &args[0]) != MH_OK) return 1;
    } else if (strcmp(shape, "vararg") == 0) nargs = 3;
    else if (strcmp(shape, "wide") == 0) nargs = 1;
    else if (strcmp(shape, "overflow") == 0) max_results = 8;
    else {
        fprintf(stderr, "unknown shape %s\n", shape);
        return 2;
    }

    mh_value callee;
    if (mh_global_get(vm, (mh_str){(const uint8_t *)fname, strlen(fname)}, &callee) != MH_OK) return 1;
    /* The callee is a global, so it stays rooted across the loop. */
    uint64_t check = 0;
    for (long long i = 0; i < iters; i++) {
        if (mh_call(vm, callee, args, nargs, out, max_results, &n) != MH_OK) {
            mh_str e = mh_last_error(vm);
            fprintf(stderr, "call: %.*s\n", (int)e.len, (const char *)e.ptr);
            return 1;
        }
        check += n;
    }
    printf("%s %llu\n", shape, (unsigned long long)check);
    mh_vm_free(vm);
    return 0;
}
