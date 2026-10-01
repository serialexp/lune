/* mahina — C header-consumer smoke test (doc 59 §3.8).
 *
 * Compiled against include/mahina.h and linked with libmahina.a by
 * `zig build test`, so the HEADER itself is validated — the Zig-side tests
 * exercise the implementation but cannot see the header drift. Checks layout
 * assumptions and one full lifecycle: eval, globals, host fn, call, refs,
 * tables, iteration, errors.
 */
#define _GNU_SOURCE /* memmem */
#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "mahina.h"

/* Layout: the 16-byte value and (ptr,len) string are ABI. */
_Static_assert(sizeof(mh_value) == 16, "mh_value must be 16 bytes");
_Static_assert(sizeof(mh_str) == 2 * sizeof(void *), "mh_str must be ptr+len");

static int add_calls = 0;

static mh_status host_add(mh_vm *vm, void *userdata, const mh_value *args,
                          size_t nargs, mh_value *results, size_t max_results,
                          size_t *nresults) {
    (void)vm;
    (void)userdata;
    int64_t a, b;
    if (nargs < 2 || max_results < 1) return MH_ERR_API;
    if (mh_value_int(args[0], &a) != MH_OK) return MH_ERR_API;
    if (mh_value_int(args[1], &b) != MH_OK) return MH_ERR_API;
    results[0] = mh_int(a + b);
    *nresults = 1;
    add_calls++;
    return MH_OK;
}

int main(void) {
    mh_vm *vm = NULL;
    mh_value out[2];
    size_t n = 0;
    int64_t x = 0;

    assert(mh_vm_new(NULL, &vm) == MH_OK);

    /* eval + int result */
    assert(mh_eval(vm, MH_STR("return 20 + 22"), MH_STR("smoke"), out, 1, &n) == MH_OK);
    assert(n == 1);
    assert(mh_value_type(out[0]) == MH_INT);
    assert(mh_value_int(out[0], &x) == MH_OK && x == 42);

    /* globals + strings */
    assert(mh_global_set(vm, MH_STR("who"), mh_int(7)) == MH_OK);
    assert(mh_eval(vm, MH_STR("return 'id-' .. who"), MH_STR("smoke"), out, 1, &n) == MH_OK);
    mh_str sv;
    assert(mh_value_str(vm, out[0], &sv) == MH_OK);
    assert(sv.len == 4 && memcmp(sv.ptr, "id-7", 4) == 0);

    /* host fn + guest call-out */
    assert(mh_register_fn(vm, MH_STR("add"), host_add, NULL, NULL) == MH_OK);
    assert(mh_eval(vm, MH_STR("return add(40, 2)"), MH_STR("smoke"), out, 1, &n) == MH_OK);
    assert(mh_value_int(out[0], &x) == MH_OK && x == 42 && add_calls == 1);

    /* host→guest call + ref across GC */
    assert(mh_eval(vm, MH_STR("return function(k) return k * 2 end"), MH_STR("smoke"), out, 1, &n) == MH_OK);
    mh_ref fref;
    assert(mh_ref_create(vm, out[0], &fref) == MH_OK);
    assert(mh_collect(vm) == MH_OK);
    mh_value f;
    assert(mh_ref_get(vm, fref, &f) == MH_OK);
    mh_value arg = mh_int(21);
    assert(mh_call(vm, f, &arg, 1, out, 1, &n) == MH_OK && n == 1);
    assert(mh_value_int(out[0], &x) == MH_OK && x == 42);
    assert(mh_ref_free(vm, fref) == MH_OK);
    assert(mh_ref_get(vm, fref, &f) == MH_ERR_API); /* stale ref detected */

    /* tables + iteration */
    mh_value t;
    assert(mh_table_new(vm, &t) == MH_OK);
    assert(mh_table_set(vm, t, mh_int(1), mh_int(10)) == MH_OK);
    assert(mh_table_set(vm, t, mh_int(2), mh_int(20)) == MH_OK);
    int64_t len;
    assert(mh_table_len(vm, t, &len) == MH_OK && len == 2);
    mh_table_iter *it;
    assert(mh_table_iter_new(vm, t, &it) == MH_OK);
    int done = 0;
    size_t steps = 0;
    int64_t sum = 0;
    for (;;) {
        mh_value k, v;
        assert(mh_table_iter_next(vm, it, &k, &v, &done) == MH_OK);
        if (done) break;
        assert(mh_value_int(v, &x) == MH_OK);
        sum += x;
        steps++;
    }
    assert(steps == 2 && sum == 30);
    assert(mh_table_iter_free(vm, it) == MH_OK);

    /* runtime error: message + recovery */
    assert(mh_eval(vm, MH_STR("error('smoke-fault')"), MH_STR("smoke"), out, 0, &n) == MH_ERR_RUNTIME);
    mh_str err = mh_last_error(vm);
    assert(err.len > 0);
    assert(memmem(err.ptr, err.len, "smoke-fault", 11) != NULL);
    assert(mh_eval(vm, MH_STR("return 1"), MH_STR("smoke"), out, 1, &n) == MH_OK);

    /* output capture */
    assert(mh_eval(vm, MH_STR("print('hi')"), MH_STR("smoke"), out, 0, &n) == MH_OK);
    mh_str o = mh_output(vm);
    assert(o.len >= 2 && memmem(o.ptr, o.len, "hi", 2) != NULL);

    assert(mh_vm_free(vm) == MH_OK);
    printf("capi smoke: OK\n");
    return 0;
}
