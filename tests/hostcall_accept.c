/* mahina — host fixture for the doc 60 §6.3 build acceptance
 * (tools/hostcall-acceptance.sh).
 *
 * Linked with libmahina.a into a PIE, and also against a shared library
 * built from the whole archive. It makes one host call into a guest
 * function that calls back into the host, so a debugger stopped in the
 * fallback entry, in a guest handler, or in the callback sees each path's
 * frames (§3.3's table). It exits 0 only when the call returns the expected
 * value, so the run itself also checks both links work.
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
    mh_value f, out[1];
    size_t n = 0;
    int64_t x = 0;

    if (mh_vm_new(NULL, &vm) != MH_OK) return 2;
    if (mh_register_fn(vm, MH_STR("cb"), host_cb, NULL, NULL) != MH_OK) return 3;
    if (mh_eval(vm, MH_STR("function f(x) return cb(x) + 1 end"), MH_STR("accept"), NULL, 0, &n) != MH_OK)
        return 4;
    if (mh_global_get(vm, MH_STR("f"), &f) != MH_OK) return 5;

    mh_value arg = mh_int(40);
    if (mh_call(vm, f, &arg, 1, out, 1, &n) != MH_OK) return 6;
    if (n != 1 || mh_value_int(out[0], &x) != MH_OK || x != 42) return 7;

    mh_vm_free(vm);
    puts("hostcall-accept: ok");
    return 0;
}
