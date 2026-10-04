/* mahina — host fixture for the doc 60 §6.3 build acceptance
 * (tools/hostcall-acceptance.sh).
 *
 * Linked with libmahina.a into a PIE, and also against a shared library
 * built from the whole archive. It makes three host calls, one per path of
 * §3.3's table, so a debugger stopped in each sees that path's frames:
 *   1. an admitted call into a guest function that calls back into the host
 *      (stops in the entry itself, in a guest handler, and in the callback);
 *   2. an admitted call whose eight heap results overflow the inline park
 *      (a stop in the park helper);
 *   3. a call with more arguments than the entry admits (a stop in the
 *      fallback).
 * Then it makes the result-overflow call again, an admitted call whose guest
 * raises, the callback call again, and the fallback call again: the DWARF
 * leg single-steps the entry through each of those four, which between them
 * reach every CFI region of the entry (pre-commit, prologue, body, both
 * epilogue exits, and the overflow block after the first one).
 * It exits 0 only when every call returns the expected values, so the run
 * itself also checks both links work.
 */
#include <stdio.h>

#include "mahina.h"

/* The debugger stops here, under the guest frame that called it. Kept out
 * of line so the stop has a frame of its own. */
__attribute__((noinline)) static mh_status host_cb(mh_vm *vm, void *userdata,
                                                   const mh_value *args, size_t nargs,
                                                   mh_value *results, size_t max_results,
                                                   size_t *nresults) {
    (void)vm;
    (void)userdata;
    int64_t x;
    if (nargs < 1 || max_results < 1) return MH_ERR_API;
    if (mh_value_int(args[0], &x) != MH_OK) return MH_ERR_API;
    results[0] = mh_int(x + 1);
    *nresults = 1;
    return MH_OK;
}

int main(void) {
    mh_vm *vm = NULL;
    mh_value f, many, count, boom, out[8];
    size_t n = 0;
    int64_t x = 0;

    if (mh_vm_new(NULL, &vm) != MH_OK) return 2;
    if (mh_register_fn(vm, MH_STR("cb"), host_cb, NULL, NULL) != MH_OK) return 3;
    if (mh_eval(vm,
                MH_STR("function f(x) return cb(x) + 1 end\n"
                       "function many() return 's1', 's2', 's3', 's4', 's5', 's6', 's7', 's8' end\n"
                       "function count(...) return select('#', ...) end\n"
                       "function boom() error('accept') end"),
                MH_STR("accept"), NULL, 0, &n) != MH_OK)
        return 4;
    if (mh_global_get(vm, MH_STR("f"), &f) != MH_OK) return 5;
    if (mh_global_get(vm, MH_STR("many"), &many) != MH_OK) return 5;
    if (mh_global_get(vm, MH_STR("count"), &count) != MH_OK) return 5;
    if (mh_global_get(vm, MH_STR("boom"), &boom) != MH_OK) return 5;

    /* 1. Admitted, with a callback. */
    mh_value arg = mh_int(40);
    if (mh_call(vm, f, &arg, 1, out, 1, &n) != MH_OK) return 6;
    if (n != 1 || mh_value_int(out[0], &x) != MH_OK || x != 42) return 7;

    /* 2. Admitted; the callee and eight strings overflow the inline park. */
    if (mh_call(vm, many, NULL, 0, out, 8, &n) != MH_OK) return 8;
    if (n != 8 || mh_value_type(out[7]) != MH_STRING) return 9;

    /* 3. Nine arguments: past the entry's limit, so H1 runs it. */
    mh_value nine[9];
    for (int i = 0; i < 9; i++) nine[i] = mh_int(i);
    if (mh_call(vm, count, nine, 9, out, 1, &n) != MH_OK) return 10;
    if (n != 1 || mh_value_int(out[0], &x) != MH_OK || x != 9) return 11;

    /* 4-7. For the instruction-by-instruction walks: the overflow path, the
     * error path, the plain success path and the fallback. */
    if (mh_call(vm, many, NULL, 0, out, 8, &n) != MH_OK || n != 8) return 12;
    if (mh_call(vm, boom, NULL, 0, out, 1, &n) != MH_ERR_RUNTIME || n != 0) return 13;
    if (mh_call(vm, f, &arg, 1, out, 1, &n) != MH_OK || n != 1) return 14;
    if (mh_call(vm, count, nine, 9, out, 1, &n) != MH_OK || n != 1) return 15;

    mh_vm_free(vm);
    puts("hostcall-accept: ok");
    return 0;
}
