/* bench/embed — guest->host call probe per loop shape (doc 63 Phase 0).
 *
 * The other direction from hostcall_probe.c: a guest loop calling host
 * functions, the case doc 63 compiles. One shape per run, so `perf stat`
 * measures exactly that shape:
 *
 *   tracecall_probe <shape> <iters>
 *
 * Per-iteration cost = (counts at <iters>) - (counts at 0), divided by
 * <iters>; the 0-iteration run absorbs VM creation and script compile.
 * Run with MH_NOJIT=1 for tier-0, without it for the JIT. `tracecall.py`
 * drives every shape in both modes and checks their checksums agree.
 *
 * Shapes (doc 63 §8):
 *   min      §1's loop: s = s + host_id(i), host_id a global
 *   minl     the same with host_id hoisted into a local
 *   gid      control: a guest function instead of a host one
 *   a0 a4 a8 0/4/8 int arguments, 1 result
 *   w4 w8 w16  4/8/16 locals carried across the call (window size)
 *   s1 s4    1/4 globals read per iteration (seeds)
 *   wide     §8's budget shape: 8 carried locals, one global, one table
 *            store per iteration
 *   cb       a host that calls back into a guest function every call
 *   tw       a host that writes a guest table every call
 *   two      two loops (two anchors) calling the same host, which only
 *            returns its argument for the first 10 rounds (500 calls per
 *            loop, 1000 in all) and calls back into the guest from then
 *            on: the calm warm-up
 *            lets both loops' traces form before the host disturbs.
 *            N must be a multiple of 100 (N host calls)
 *   fail     a host whose guest callback fails every call, caught by pcall
 *   nest     a host that returns its argument, except on iteration 1000,
 *            where it first runs a long guest loop (work(100000)): one
 *            disturbing call after a calm warm-up, so the loop has traced
 *            by then. `nestq` is the same loop with no disturbing call;
 *            nest(1000) - nestq(1000) is the one disturbing call's cost
 *            (both runs end right after it)
 *
 * Informational, never a gate (global Rule #22).
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "mahina.h"

static const char script[] =
    "G1, G2, G3, G4 = 1, 2, 3, 4\n"
    "T = {}\n"
    "function gid_f(x) return x end\n"
    "function gcb(x) return x end\n"
    "function gfail(x) error('boom') end\n"
    "function work(m) local s = 0 for k = 1, m do s = s + k end return s end\n"
    "function min(n) local s = 0 for i = 1, n do s = s + host_id(i) end return s end\n"
    "function minl(n) local h = host_id local s = 0 for i = 1, n do s = s + h(i) end return s end\n"
    "function gid(n) local s = 0 for i = 1, n do s = s + gid_f(i) end return s end\n"
    "function a0(n) local h = host_zero local s = 0 for i = 1, n do s = s + h() + i end return s end\n"
    "function a4(n) local h = host_last local s = 0 for i = 1, n do s = s + h(i, i, i, i) end return s end\n"
    "function a8(n) local h = host_last local s = 0\n"
    "  for i = 1, n do s = s + h(i, i, i, i, i, i, i, i) end return s end\n"
    "function w4(n) local h = host_id local a, b, c, d = 1, 2, 3, 4\n"
    "  for i = 1, n do a, b, c, d = b, c, d, a + h(i) end return a + b + c + d end\n"
    "function w8(n) local h = host_id local a, b, c, d, e, f, g, k = 1, 2, 3, 4, 5, 6, 7, 8\n"
    "  for i = 1, n do a, b, c, d, e, f, g, k = b, c, d, e, f, g, k, a + h(i) end\n"
    "  return a + b + c + d + e + f + g + k end\n"
    "function w16(n) local h = host_id\n"
    "  local a, b, c, d, e, f, g, k = 1, 2, 3, 4, 5, 6, 7, 8\n"
    "  local a2, b2, c2, d2, e2, f2, g2, k2 = 1, 2, 3, 4, 5, 6, 7, 8\n"
    "  for i = 1, n do\n"
    "    a, b, c, d, e, f, g, k, a2, b2, c2, d2, e2, f2, g2, k2 =\n"
    "      b, c, d, e, f, g, k, a2, b2, c2, d2, e2, f2, g2, k2, a + h(i)\n"
    "  end\n"
    "  return a + b + c + d + e + f + g + k + a2 + b2 + c2 + d2 + e2 + f2 + g2 + k2 end\n"
    "function s1(n) local h = host_id local s = 0 for i = 1, n do s = s + h(i) + G1 end return s end\n"
    "function s4(n) local h = host_id local s = 0\n"
    "  for i = 1, n do s = s + h(i) + G1 + G2 + G3 + G4 end return s end\n"
    "function wide(n) local h = host_id local t = {} local a, b, c, d, e, f, g, k = 1, 2, 3, 4, 5, 6, 7, 8\n"
    "  for i = 1, n do a, b, c, d, e, f, g, k = b, c, d, e, f, g, k, a + h(i) + G1 t[i % 16 + 1] = k end\n"
    "  return a + b + c + d + e + f + g + k + (t[1] or 0) end\n"
    "function cb(n) local h = host_cb local s = 0 for i = 1, n do s = s + h(i) end return s end\n"
    "function tw(n) local h = host_tw local s = 0 for i = 1, n do s = s + h(i) end return s + (T[1] or 0) end\n"
    "function two(n) local s = 0\n"
    "  for j = 1, n // 100 do\n"
    "    local on = j > 10\n"
    "    for i = 1, 50 do s = s + host_late(i, on) end\n"
    "    for i = 1, 50 do s = s + host_late(i, on) end\n"
    "  end return s end\n"
    "function fail(n) local s = 0 for i = 1, n do if not pcall(host_cbfail, i) then s = s + 1 end end return s end\n"
    "function nest(n) local h = host_nest local s = 0 for i = 1, n do s = s + h(i, 1000) end return s end\n"
    "function nestq(n) local h = host_nest local s = 0 for i = 1, n do s = s + h(i, 0) end return s end\n";

/* Guest values the hosts reach, rooted for the whole run. */
typedef struct probe_refs {
    mh_ref gcb, gfail, work, tbl;
} probe_refs;

static mh_status host_id(mh_vm *vm, void *ud, const mh_value *args, size_t nargs,
                         mh_value *results, size_t max_results, size_t *nresults) {
    (void)vm, (void)ud, (void)max_results;
    results[0] = nargs ? args[0] : mh_int(0);
    *nresults = 1;
    return MH_OK;
}

static mh_status host_zero(mh_vm *vm, void *ud, const mh_value *args, size_t nargs,
                           mh_value *results, size_t max_results, size_t *nresults) {
    (void)vm, (void)ud, (void)args, (void)nargs, (void)max_results;
    results[0] = mh_int(0);
    *nresults = 1;
    return MH_OK;
}

static mh_status host_last(mh_vm *vm, void *ud, const mh_value *args, size_t nargs,
                           mh_value *results, size_t max_results, size_t *nresults) {
    (void)vm, (void)ud, (void)max_results;
    results[0] = nargs ? args[nargs - 1] : mh_int(0);
    *nresults = 1;
    return MH_OK;
}

/* Calls back into the guest `gcb(x)` on every call. */
static mh_status host_cb(mh_vm *vm, void *ud, const mh_value *args, size_t nargs,
                         mh_value *results, size_t max_results, size_t *nresults) {
    (void)max_results;
    if (nargs < 1) return MH_ERR_API;
    probe_refs *r = ud;
    mh_value f;
    mh_status st = mh_ref_get(vm, r->gcb, &f);
    if (st != MH_OK) return st;
    size_t n;
    st = mh_call(vm, f, args, 1, results, 1, &n);
    if (st != MH_OK) return st;
    *nresults = n;
    return MH_OK;
}

/* Writes the guest table `T[x % 16 + 1] = x` on every call. */
static mh_status host_tw(mh_vm *vm, void *ud, const mh_value *args, size_t nargs,
                         mh_value *results, size_t max_results, size_t *nresults) {
    (void)max_results;
    if (nargs < 1) return MH_ERR_API;
    probe_refs *r = ud;
    mh_value t;
    mh_status st = mh_ref_get(vm, r->tbl, &t);
    if (st != MH_OK) return st;
    int64_t x;
    if (mh_value_int(args[0], &x) != MH_OK) return MH_ERR_API;
    st = mh_table_set(vm, t, mh_int(x % 16 + 1), args[0]);
    if (st != MH_OK) return st;
    results[0] = args[0];
    *nresults = 1;
    return MH_OK;
}

/* Calls the guest `gfail(x)`, which raises; fails with it. */
static mh_status host_cbfail(mh_vm *vm, void *ud, const mh_value *args, size_t nargs,
                             mh_value *results, size_t max_results, size_t *nresults) {
    (void)max_results, (void)nresults;
    if (nargs < 1) return MH_ERR_API;
    probe_refs *r = ud;
    mh_value f;
    mh_status st = mh_ref_get(vm, r->gfail, &f);
    if (st != MH_OK) return st;
    size_t n;
    st = mh_call(vm, f, args, 1, results, 0, &n);
    if (st == MH_OK) return MH_ERR_API; /* gfail must fail */
    mh_error_set(vm, MH_STR("cbfail"));
    return MH_ERR_RUNTIME;
}

/* host_late(x, on): returns x; when `on` is truthy it gets x by calling
 * back into the guest `gcb(x)` instead. */
static mh_status host_late(mh_vm *vm, void *ud, const mh_value *args, size_t nargs,
                           mh_value *results, size_t max_results, size_t *nresults) {
    if (nargs < 2) return MH_ERR_API;
    if (!mh_value_truthy(args[1])) return host_id(vm, ud, args, 1, results, max_results, nresults);
    return host_cb(vm, ud, args, 1, results, max_results, nresults);
}

/* host_nest(x, at): returns x; when x == at it first runs the guest
 * `work(100000)` and checks its sum. */
static mh_status host_nest(mh_vm *vm, void *ud, const mh_value *args, size_t nargs,
                           mh_value *results, size_t max_results, size_t *nresults) {
    (void)max_results;
    if (nargs < 2) return MH_ERR_API;
    probe_refs *r = ud;
    int64_t x, at;
    if (mh_value_int(args[0], &x) != MH_OK || mh_value_int(args[1], &at) != MH_OK) return MH_ERR_API;
    if (x == at) {
        mh_value f, out;
        mh_status st = mh_ref_get(vm, r->work, &f);
        if (st != MH_OK) return st;
        mh_value m = mh_int(100000);
        size_t n;
        st = mh_call(vm, f, &m, 1, &out, 1, &n);
        if (st != MH_OK) return st;
        int64_t sum;
        if (n != 1 || mh_value_int(out, &sum) != MH_OK || sum != 5000050000LL) return MH_ERR_API;
    }
    results[0] = args[0];
    *nresults = 1;
    return MH_OK;
}

static int fail_with(mh_vm *vm, const char *what) {
    mh_str e = mh_last_error(vm);
    fprintf(stderr, "%s: %.*s\n", what, (int)e.len, (const char *)e.ptr);
    return 1;
}

static int ref_global(mh_vm *vm, const char *name, mh_ref *out) {
    mh_value v;
    if (mh_global_get(vm, (mh_str){(const uint8_t *)name, strlen(name)}, &v) != MH_OK) return 0;
    return mh_ref_create(vm, v, out) == MH_OK;
}

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

    probe_refs refs = {0};
    static const struct {
        const char *name;
        mh_host_fn fn;
    } hosts[] = {
        {"host_id", host_id},       {"host_zero", host_zero},     {"host_last", host_last},
        {"host_cb", host_cb},       {"host_tw", host_tw},         {"host_cbfail", host_cbfail},
        {"host_nest", host_nest},   {"host_late", host_late},
    };
    for (size_t i = 0; i < sizeof hosts / sizeof hosts[0]; i++) {
        mh_str name = {(const uint8_t *)hosts[i].name, strlen(hosts[i].name)};
        if (mh_register_fn(vm, name, hosts[i].fn, &refs, NULL) != MH_OK) return fail_with(vm, "register");
    }

    size_t n;
    mh_value out[1];
    if (mh_eval(vm, MH_STR(script), MH_STR("probe"), out, 0, &n) != MH_OK) return fail_with(vm, "script");
    if (!ref_global(vm, "gcb", &refs.gcb) || !ref_global(vm, "gfail", &refs.gfail) ||
        !ref_global(vm, "work", &refs.work) || !ref_global(vm, "T", &refs.tbl))
        return fail_with(vm, "refs");

    mh_value fn;
    if (mh_global_get(vm, (mh_str){(const uint8_t *)shape, strlen(shape)}, &fn) != MH_OK ||
        mh_value_type(fn) != MH_FUNCTION) {
        fprintf(stderr, "unknown shape %s\n", shape);
        return 2;
    }
    mh_value arg = mh_int(iters);
    if (mh_call(vm, fn, &arg, 1, out, 1, &n) != MH_OK) return fail_with(vm, shape);
    int64_t check = 0;
    if (n != 1 || mh_value_int(out[0], &check) != MH_OK) {
        fprintf(stderr, "%s: non-int result\n", shape);
        return 1;
    }
    printf("%s %lld\n", shape, (long long)check);
    mh_vm_free(vm);
    return 0;
}
