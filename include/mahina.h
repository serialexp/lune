/* mahina — C embedding API (libmahina), doc 59.
 *
 * The normative ABI contract for embedding the mahina VM in a host
 * application. Kept in lockstep with src/capi.zig (the implementation) and
 * embed/rust/mahina-sys (the Rust mirror); the C smoke test
 * (tests/capi_smoke.c) and the Rust integration tests gate drift.
 *
 * Quick start:
 *
 *   mh_vm *vm;
 *   if (mh_vm_new(NULL, &vm) != MH_OK) abort();
 *   mh_value out[1]; size_t n;
 *   if (mh_eval(vm, MH_STR("return 1 + 2"), MH_STR("demo"), out, 1, &n) == MH_OK)
 *       { int64_t x; mh_value_int(out[0], &x); }
 *   mh_vm_free(vm);
 *
 * THREADING: a VM is single-threaded — one thread at a time, no internal
 * locking. Use one VM per thread (isolate model).
 *
 * VALUE LIFETIME (the one rule to internalize): an mh_value with a heap type
 * (string/table/function) is BORROWED. It stays valid:
 *   - until the next API call on this VM that can allocate or run guest code
 *     (such calls clear the internal "parked results" root when the VM is
 *     idle) — EXCEPT values you pass as arguments to that very call, which
 *     remain valid through and after it; and
 *   - indefinitely, while an mh_ref you created for it is alive.
 * Inside a host callback nothing is cleared, so values obtained there stay
 *  valid for the whole callback. mh_ref_create / the pure accessors
 * (mh_value_type/int/float/bool/truthy/str, mh_last_error, mh_output,
 * mh_collect, mh_mem_stats_get) never invalidate anything.
 *
 * String bytes returned by mh_value_str are borrowed from the (non-moving)
 * GC heap and stay valid exactly as long as the value itself (above).
 *
 * ERRORS: failing calls return an mh_status and store a rendered message
 * retrievable with mh_last_error (borrowed until the next failing call).
 * After MH_ERR_RUNTIME the VM is fully restored and reusable. A rare
 * non-catchable fault (out of memory inside the VM) poisons the VM: every
 * later guest-running call returns MH_ERR_API; free it.
 *
 * SAFETY: like the Lua C API, this boundary is unsafe-by-construction —
 * tag bytes are validated, but a forged heap pointer in an mh_value is
 * undetectable. Build safe wrappers (see embed/rust/mahina) on top.
 */
#ifndef MAHINA_H
#define MAHINA_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---- status / types ---------------------------------------------------- */

typedef enum mh_status {
    MH_OK = 0,
    MH_ERR_COMPILE = 1, /* parse/compile diagnostics in mh_last_error      */
    MH_ERR_RUNTIME = 2, /* guest fault; located message in mh_last_error   */
    MH_ERR_OOM = 3,     /* allocation failure                              */
    MH_ERR_API = 4      /* misuse: bad value/ref/handle, collision, fatal  */
} mh_status;

/* The public value type. Stable; deliberately decoupled from the VM's
 * internal tag ordinals. */
typedef enum mh_type {
    MH_NIL = 0,
    MH_BOOL = 1,
    MH_INT = 2,
    MH_FLOAT = 3,
    MH_STRING = 4,
    MH_TABLE = 5,
    MH_FUNCTION = 6,
    MH_OTHER = 7
} mh_type;

/* Borrowed bytes + length. Never NUL-terminated by contract. */
typedef struct mh_str {
    const uint8_t *ptr;
    size_t len;
} mh_str;

/* Convenience constructor for C string literals. */
#define MH_STR(lit) ((mh_str){(const uint8_t *)(lit), sizeof(lit) - 1})

/* A guest value. 16 bytes, layout-checked on both sides; treat as OPAQUE —
 * construct with mh_nil/mh_bool/mh_int/mh_float/mh_string_new, inspect with
 * mh_value_type and the accessors. Never interpret tag/payload yourself. */
typedef struct mh_value {
    uint8_t _tag;
    uint8_t _pad[7];
    uint64_t _payload;
} mh_value;

/* Opaque handles. */
typedef struct mh_vm mh_vm;
typedef struct mh_script mh_script;
typedef struct mh_table_iter mh_table_iter;

/* A GC root handle (generational — a freed ref is detected, never dangling). */
typedef uint64_t mh_ref;

/* VM creation options. Zero-initialize (or pass NULL) for defaults.
 * jit: 0 = default (on), 1 = on, 2 = off. */
typedef struct mh_config {
    int jit;
} mh_config;

typedef struct mh_mem_stats {
    size_t live_bytes;
    size_t peak_bytes;
    size_t total_bytes;
    size_t live_allocations;
} mh_mem_stats;

/* ---- VM lifecycle ------------------------------------------------------ */

mh_status mh_vm_new(const mh_config *config, mh_vm **out);
/* Refused (MH_ERR_API) while guest code or a host callback is running. */
mh_status mh_vm_free(mh_vm *vm);

mh_str mh_last_error(mh_vm *vm);

/* print/io.write output and warn() output are captured per-VM. */
mh_str mh_output(mh_vm *vm);
void mh_output_clear(mh_vm *vm);
mh_str mh_warnings(mh_vm *vm);
void mh_warnings_clear(mh_vm *vm);

mh_status mh_mem_stats_get(mh_vm *vm, mh_mem_stats *out);
/* Force a full GC cycle (parked results and refs are roots and survive). */
mh_status mh_collect(mh_vm *vm);

/* ---- compile / run / eval ---------------------------------------------- */
/* Compiled images are owned by the VM until mh_vm_free (like Lua's load());
 * mh_script_free releases only the handle. name labels error messages. */

mh_status mh_compile(mh_vm *vm, mh_str src, mh_str name, mh_script **out);
void mh_script_free(mh_script *script);
mh_status mh_run(mh_vm *vm, mh_script *script, mh_value *results, size_t max_results, size_t *nresults);
mh_status mh_eval(mh_vm *vm, mh_str src, mh_str name, mh_value *results, size_t max_results, size_t *nresults);

/* ---- calling guest functions ------------------------------------------- */
/* Surplus results are truncated to max_results; results[*nresults..] are
 * UNDEFINED (read only the reported prefix). args and results must not
 * overlap. */

mh_status mh_call(mh_vm *vm, mh_value callee, const mh_value *args, size_t nargs,
                  mh_value *results, size_t max_results, size_t *nresults);

/* ---- values ------------------------------------------------------------ */

mh_value mh_nil(void);
mh_value mh_bool(int b);
mh_value mh_int(int64_t i);
mh_value mh_float(double f);
/* Intern host bytes as a guest string (result parked). */
mh_status mh_string_new(mh_vm *vm, mh_str bytes, mh_value *out);

mh_type mh_value_type(mh_value v);
int mh_value_truthy(mh_value v); /* Lua truthiness */
mh_status mh_value_int(mh_value v, int64_t *out);   /* int tag only        */
mh_status mh_value_float(mh_value v, double *out);  /* int or float tag    */
mh_status mh_value_bool(mh_value v, int *out);      /* bool tag only       */
/* Borrowed string bytes (see VALUE LIFETIME above). */
mh_status mh_value_str(mh_vm *vm, mh_value v, mh_str *out);

/* ---- globals ------------------------------------------------------------ */

mh_status mh_global_get(mh_vm *vm, mh_str name, mh_value *out);
mh_status mh_global_set(mh_vm *vm, mh_str name, mh_value val);

/* ---- refs (long-lived GC roots) ----------------------------------------- */

mh_status mh_ref_create(mh_vm *vm, mh_value v, mh_ref *out);
mh_status mh_ref_get(mh_vm *vm, mh_ref ref, mh_value *out);
mh_status mh_ref_free(mh_vm *vm, mh_ref ref);

/* ---- host functions ------------------------------------------------------
 * Called from guest code. Write up to max_results into results, set
 * *nresults, return MH_OK. Any other return raises a (pcall-catchable)
 * guest error carrying the message last staged with mh_error_set. args and
 * results never alias. Reentrancy: you may call back into the VM through
 * the vm handle; you may NOT mh_vm_free it here. A registered name must not
 * collide with a builtin ("print", "string.format", "string", ...); shape
 * is "name" or "module.field". userdata is released by destroy (if given)
 * when the function is garbage-collected or the VM is freed. */

typedef mh_status (*mh_host_fn)(mh_vm *vm, void *userdata,
                                const mh_value *args, size_t nargs,
                                mh_value *results, size_t max_results,
                                size_t *nresults);
typedef void (*mh_host_fn_destroy)(void *userdata);

mh_status mh_register_fn(mh_vm *vm, mh_str name, mh_host_fn fn,
                         void *userdata, mh_host_fn_destroy destroy);
/* Stage the error message for a failing return from the current callback. */
void mh_error_set(mh_vm *vm, mh_str msg);

/* ---- tables -------------------------------------------------------------- */
/* get/set follow guest semantics (__index/__newindex metamethods run, and
 * may therefore fault like any guest code). len is the raw border (#t). */

mh_status mh_table_new(mh_vm *vm, mh_value *out);
mh_status mh_table_get(mh_vm *vm, mh_value tbl, mh_value key, mh_value *out);
mh_status mh_table_set(mh_vm *vm, mh_value tbl, mh_value key, mh_value val);
mh_status mh_table_len(mh_vm *vm, mh_value tbl, int64_t *out);
mh_status mh_table_metatable_get(mh_vm *vm, mh_value tbl, mh_value *out); /* nil if none */
mh_status mh_table_metatable_set(mh_vm *vm, mh_value tbl, mh_value mt);   /* nil clears  */

/* Iteration: the deterministic key order (array part ascending, then hash
 * keys in canonical order — next()'s order) is snapshotted at iter_new;
 * each step is O(1). Values are read live; keys deleted since iter_new are
 * skipped, insertions are not observed. */
mh_status mh_table_iter_new(mh_vm *vm, mh_value tbl, mh_table_iter **out);
mh_status mh_table_iter_next(mh_vm *vm, mh_table_iter *iter, mh_value *key, mh_value *val, int *done);
mh_status mh_table_iter_free(mh_vm *vm, mh_table_iter *iter);

#ifdef __cplusplus
}
#endif

#endif /* MAHINA_H */
