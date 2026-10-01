/* bench/embed — embedding-boundary benchmark, mahina C ABI (doc 59 E5).
 *
 * Measures the host<->guest boundary through include/mahina.h with the same
 * guest programs and counts as bench_lua.c (LuaJIT / Lua 5.4); run via
 * bench/embed/run.py, which builds all hosts and prints the comparison
 * table. Informational, never a gate (global Rule #22).
 *
 * Value-lifetime notes (the interesting part of writing this host):
 *   - Heap mh_values reused across a loop of guest-running calls stay valid
 *     because they are *arguments* to each call — the API re-parks a call's
 *     own heap arguments after clearing the idle-entry park (mahina.h
 *     "VALUE LIFETIME"). That is the designed game-loop usage, and it is
 *     the exact analogue of the Lua host keeping its operands on the C
 *     stack, so the two hosts do equivalent per-iteration work.
 *   - mh_compile retains each chunk for the VM's lifetime by design (same
 *     ownership as guest load()); the compile bench therefore also grows
 *     the heap — visible in maxrss_kb.
 */
#include <string.h>

#include "mahina.h"

#include "bench_common.h"
#include "sources.h"

static mh_status host_id_cb(mh_vm *vm, void *userdata, const mh_value *args, size_t nargs,
                            mh_value *results, size_t max_results, size_t *nresults) {
    (void)vm;
    (void)userdata;
    if (nargs < 1 || max_results < 1) return MH_ERR_API;
    results[0] = args[0];
    *nresults = 1;
    return MH_OK;
}

static void check(mh_status st, mh_vm *vm, const char *op) {
    if (st != MH_OK) {
        mh_str msg = mh_last_error(vm);
        fprintf(stderr, "FAIL %s: status %d: %.*s\n", op, (int)st, (int)msg.len,
                (const char *)msg.ptr);
        exit(1);
    }
}

int main(void) {
    mh_vm *vm;
    if (mh_vm_new(NULL, &vm) != MH_OK) FAIL("init", "mh_vm_new");

    mh_value out[4];
    size_t n;
    int64_t ival;
    uint64_t t0;
    long long sum;

    /* ---- host -> guest call ------------------------------------------- */
    check(mh_eval(vm, MH_STR(SRC_ID_FN), MH_STR("bench"), out, 0, &n), vm, "call-setup");
    mh_value callee;
    check(mh_global_get(vm, MH_STR("id"), &callee), vm, "call-setup");
    /* warmup */
    { mh_value a = mh_int(1); check(mh_call(vm, callee, &a, 1, out, 1, &n), vm, "call"); }
    sum = 0;
    t0 = now_ns();
    for (long long i = 0; i < N_CALL; i++) {
        mh_value a = mh_int(i);
        check(mh_call(vm, callee, &a, 1, out, 1, &n), vm, "call");
        if (mh_value_int(out[0], &ival) != MH_OK) FAIL("call", "non-int result");
        sum += ival;
    }
    report("call", now_ns() - t0, N_CALL, sum);

    /* ---- guest -> host callback --------------------------------------- */
    check(mh_register_fn(vm, MH_STR("host_id"), host_id_cb, NULL, NULL), vm, "callback-setup");
    check(mh_eval(vm, MH_STR(SRC_CALLBACK_LOOP), MH_STR("bench"), out, 1, &n), vm, "callback");
    t0 = now_ns();
    check(mh_eval(vm, MH_STR(SRC_CALLBACK_LOOP), MH_STR("bench"), out, 1, &n), vm, "callback");
    uint64_t cb_elapsed = now_ns() - t0;
    if (mh_value_int(out[0], &ival) != MH_OK || ival != CALLBACK_CHECKSUM)
        FAIL("callback", "bad checksum");
    report("callback", cb_elapsed, N_CALLBACK, ival);

    /* ---- table get / set (reused guest-string key) --------------------- */
    mh_value tbl, key;
    check(mh_table_new(vm, &tbl), vm, "table-setup");
    mh_ref tbl_ref;
    check(mh_ref_create(vm, tbl, &tbl_ref), vm, "table-setup");
    check(mh_string_new(vm, MH_STR(TABLE_KEY), &key), vm, "table-setup");
    mh_ref key_ref;
    check(mh_ref_create(vm, key, &key_ref), vm, "table-setup");
    check(mh_table_set(vm, tbl, key, mh_int(42)), vm, "table-setup");

    sum = 0;
    t0 = now_ns();
    for (long long i = 0; i < N_TABLE; i++) {
        check(mh_table_get(vm, tbl, key, &out[0]), vm, "table_get");
        if (mh_value_int(out[0], &ival) != MH_OK) FAIL("table_get", "non-int");
        sum += ival;
    }
    report("table_get", now_ns() - t0, N_TABLE, sum);

    t0 = now_ns();
    for (long long i = 0; i < N_TABLE; i++)
        check(mh_table_set(vm, tbl, key, mh_int(i)), vm, "table_set");
    check(mh_table_get(vm, tbl, key, &out[0]), vm, "table_set");
    if (mh_value_int(out[0], &ival) != MH_OK) FAIL("table_set", "non-int");
    report("table_set", now_ns() - t0, N_TABLE, ival);

    /* ---- iteration over a hash-heavy table ------------------------------ */
    check(mh_eval(vm, MH_STR(SRC_BUILD_BIG), MH_STR("bench"), out, 0, &n), vm, "iter-setup");
    mh_value big;
    check(mh_global_get(vm, MH_STR("big"), &big), vm, "iter-setup");
    mh_ref big_ref;
    check(mh_ref_create(vm, big, &big_ref), vm, "iter-setup");
    sum = 0;
    t0 = now_ns();
    for (int pass = 0; pass < N_ITER_PASSES; pass++) {
        mh_table_iter *it;
        check(mh_table_iter_new(vm, big, &it), vm, "iterate");
        for (;;) {
            mh_value k, v;
            int done;
            check(mh_table_iter_next(vm, it, &k, &v, &done), vm, "iterate");
            if (done) break;
            if (mh_value_int(v, &ival) != MH_OK) FAIL("iterate", "non-int value");
            sum += ival;
        }
        check(mh_table_iter_free(vm, it), vm, "iterate");
    }
    report("iterate", now_ns() - t0, (long long)N_ITER_PASSES * BIG_ENTRIES, sum);

    /* ---- ref churn ------------------------------------------------------ */
    t0 = now_ns();
    for (long long i = 0; i < N_REF; i++) {
        mh_value s;
        check(mh_string_new(vm, MH_STR(REF_STRING), &s), vm, "ref");
        mh_ref r;
        check(mh_ref_create(vm, s, &r), vm, "ref");
        check(mh_ref_free(vm, r), vm, "ref");
    }
    report("ref", now_ns() - t0, N_REF, N_REF);

    /* ---- repeated compilation ------------------------------------------- */
    t0 = now_ns();
    for (long long i = 0; i < N_COMPILE; i++) {
        mh_script *s;
        check(mh_compile(vm, MH_STR(SRC_SMALL_CHUNK), MH_STR("recompile"), &s), vm, "compile");
        mh_script_free(s);
    }
    report("compile", now_ns() - t0, N_COMPILE, N_COMPILE);

    /* ---- eval round trip ------------------------------------------------ */
    sum = 0;
    t0 = now_ns();
    for (long long i = 0; i < N_EVAL; i++) {
        check(mh_eval(vm, MH_STR(SRC_EVAL), MH_STR("bench"), out, 1, &n), vm, "eval");
        if (mh_value_int(out[0], &ival) != MH_OK) FAIL("eval", "non-int");
        sum += ival;
    }
    report("eval", now_ns() - t0, N_EVAL, sum);

    report_maxrss();
    if (mh_vm_free(vm) != MH_OK) FAIL("teardown", "mh_vm_free");
    return 0;
}
