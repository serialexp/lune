//! Raw FFI bindings to `libmahina` — a hand-written mirror of
//! `include/mahina.h` (doc 59). Keep the three in lockstep; the layout tests
//! below and the `mahina` crate's integration tests catch drift.
//!
//! Everything here is `unsafe` plumbing; use the `mahina` crate for the safe
//! API. The one contract worth restating at this layer: a heap-typed
//! `mh_value` is **borrowed** (see mahina.h "VALUE LIFETIME") — root it with
//! `mh_ref_create` before the next guest-running call if you keep it.

#![allow(non_camel_case_types)]

use std::os::raw::{c_int, c_void};

// ---- status / type constants (mirror mh_status / mh_type) -----------------

pub type mh_status = c_int;
pub const MH_OK: mh_status = 0;
pub const MH_ERR_COMPILE: mh_status = 1;
pub const MH_ERR_RUNTIME: mh_status = 2;
pub const MH_ERR_OOM: mh_status = 3;
pub const MH_ERR_API: mh_status = 4;

pub type mh_type = c_int;
pub const MH_NIL: mh_type = 0;
pub const MH_BOOL: mh_type = 1;
pub const MH_INT: mh_type = 2;
pub const MH_FLOAT: mh_type = 3;
pub const MH_STRING: mh_type = 4;
pub const MH_TABLE: mh_type = 5;
pub const MH_FUNCTION: mh_type = 6;
pub const MH_OTHER: mh_type = 7;

// ---- data types ------------------------------------------------------------

/// Borrowed bytes + length (never NUL-terminated).
#[repr(C)]
#[derive(Clone, Copy)]
pub struct mh_str {
    pub ptr: *const u8,
    pub len: usize,
}

impl mh_str {
    pub const fn empty() -> Self {
        mh_str { ptr: std::ptr::null(), len: 0 }
    }
    pub fn from_slice(s: &[u8]) -> Self {
        mh_str { ptr: if s.is_empty() { std::ptr::null() } else { s.as_ptr() }, len: s.len() }
    }
    /// # Safety
    /// `ptr` must be valid for `len` bytes (the usual borrowed contract).
    pub unsafe fn as_slice<'a>(&self) -> &'a [u8] {
        if self.len == 0 {
            &[]
        } else {
            std::slice::from_raw_parts(self.ptr, self.len)
        }
    }
}

/// A guest value: opaque 16 bytes (layout-asserted below). Construct and
/// inspect only through the `mh_*` functions.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct mh_value {
    pub _tag: u8,
    pub _pad: [u8; 7],
    pub _payload: u64,
}

impl mh_value {
    pub const fn zeroed() -> Self {
        mh_value { _tag: 0, _pad: [0; 7], _payload: 0 }
    }
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct mh_config {
    /// 0 = default (JIT on), 1 = on, 2 = off.
    pub jit: c_int,
}

#[repr(C)]
#[derive(Clone, Copy, Default, Debug)]
pub struct mh_mem_stats {
    pub live_bytes: usize,
    pub peak_bytes: usize,
    pub total_bytes: usize,
    pub live_allocations: usize,
}

/// Opaque handles.
#[repr(C)]
pub struct mh_vm {
    _private: [u8; 0],
}
#[repr(C)]
pub struct mh_script {
    _private: [u8; 0],
}
#[repr(C)]
pub struct mh_table_iter {
    _private: [u8; 0],
}

pub type mh_ref = u64;

pub type mh_host_fn = unsafe extern "C" fn(
    vm: *mut mh_vm,
    userdata: *mut c_void,
    args: *const mh_value,
    nargs: usize,
    results: *mut mh_value,
    max_results: usize,
    nresults: *mut usize,
) -> mh_status;

pub type mh_host_fn_destroy = unsafe extern "C" fn(userdata: *mut c_void);

// ---- functions --------------------------------------------------------------

extern "C" {
    pub fn mh_vm_new(config: *const mh_config, out: *mut *mut mh_vm) -> mh_status;
    pub fn mh_vm_free(vm: *mut mh_vm) -> mh_status;

    pub fn mh_last_error(vm: *mut mh_vm) -> mh_str;
    pub fn mh_output(vm: *mut mh_vm) -> mh_str;
    pub fn mh_output_clear(vm: *mut mh_vm);
    pub fn mh_warnings(vm: *mut mh_vm) -> mh_str;
    pub fn mh_warnings_clear(vm: *mut mh_vm);
    pub fn mh_mem_stats_get(vm: *mut mh_vm, out: *mut mh_mem_stats) -> mh_status;
    pub fn mh_collect(vm: *mut mh_vm) -> mh_status;

    pub fn mh_compile(vm: *mut mh_vm, src: mh_str, name: mh_str, out: *mut *mut mh_script) -> mh_status;
    pub fn mh_script_free(script: *mut mh_script);
    pub fn mh_run(
        vm: *mut mh_vm,
        script: *mut mh_script,
        results: *mut mh_value,
        max_results: usize,
        nresults: *mut usize,
    ) -> mh_status;
    pub fn mh_eval(
        vm: *mut mh_vm,
        src: mh_str,
        name: mh_str,
        results: *mut mh_value,
        max_results: usize,
        nresults: *mut usize,
    ) -> mh_status;

    pub fn mh_call(
        vm: *mut mh_vm,
        callee: mh_value,
        args: *const mh_value,
        nargs: usize,
        results: *mut mh_value,
        max_results: usize,
        nresults: *mut usize,
    ) -> mh_status;

    pub fn mh_nil() -> mh_value;
    pub fn mh_bool(b: c_int) -> mh_value;
    pub fn mh_int(i: i64) -> mh_value;
    pub fn mh_float(f: f64) -> mh_value;
    pub fn mh_string_new(vm: *mut mh_vm, bytes: mh_str, out: *mut mh_value) -> mh_status;

    pub fn mh_value_type(v: mh_value) -> mh_type;
    pub fn mh_value_truthy(v: mh_value) -> c_int;
    pub fn mh_value_int(v: mh_value, out: *mut i64) -> mh_status;
    pub fn mh_value_float(v: mh_value, out: *mut f64) -> mh_status;
    pub fn mh_value_bool(v: mh_value, out: *mut c_int) -> mh_status;
    pub fn mh_value_str(vm: *mut mh_vm, v: mh_value, out: *mut mh_str) -> mh_status;

    pub fn mh_global_get(vm: *mut mh_vm, name: mh_str, out: *mut mh_value) -> mh_status;
    pub fn mh_global_set(vm: *mut mh_vm, name: mh_str, val: mh_value) -> mh_status;

    pub fn mh_ref_create(vm: *mut mh_vm, v: mh_value, out: *mut mh_ref) -> mh_status;
    pub fn mh_ref_get(vm: *mut mh_vm, r: mh_ref, out: *mut mh_value) -> mh_status;
    pub fn mh_ref_free(vm: *mut mh_vm, r: mh_ref) -> mh_status;

    pub fn mh_register_fn(
        vm: *mut mh_vm,
        name: mh_str,
        f: mh_host_fn,
        userdata: *mut c_void,
        destroy: Option<mh_host_fn_destroy>,
    ) -> mh_status;
    pub fn mh_error_set(vm: *mut mh_vm, msg: mh_str);

    pub fn mh_table_new(vm: *mut mh_vm, out: *mut mh_value) -> mh_status;
    pub fn mh_table_get(vm: *mut mh_vm, tbl: mh_value, key: mh_value, out: *mut mh_value) -> mh_status;
    pub fn mh_table_set(vm: *mut mh_vm, tbl: mh_value, key: mh_value, val: mh_value) -> mh_status;
    pub fn mh_table_len(vm: *mut mh_vm, tbl: mh_value, out: *mut i64) -> mh_status;
    pub fn mh_table_metatable_get(vm: *mut mh_vm, tbl: mh_value, out: *mut mh_value) -> mh_status;
    pub fn mh_table_metatable_set(vm: *mut mh_vm, tbl: mh_value, mt: mh_value) -> mh_status;

    pub fn mh_table_iter_new(vm: *mut mh_vm, tbl: mh_value, out: *mut *mut mh_table_iter) -> mh_status;
    pub fn mh_table_iter_next(
        vm: *mut mh_vm,
        iter: *mut mh_table_iter,
        key: *mut mh_value,
        val: *mut mh_value,
        done: *mut c_int,
    ) -> mh_status;
    pub fn mh_table_iter_free(vm: *mut mh_vm, iter: *mut mh_table_iter) -> mh_status;
}

// ---- layout tests ------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use std::mem::{align_of, offset_of, size_of};

    #[test]
    fn layouts_match_the_header() {
        assert_eq!(size_of::<mh_value>(), 16);
        assert_eq!(align_of::<mh_value>(), 8);
        assert_eq!(offset_of!(mh_value, _payload), 8);
        assert_eq!(size_of::<mh_str>(), 2 * size_of::<usize>());
    }

    #[test]
    fn smoke_lifecycle_through_raw_ffi() {
        unsafe {
            let mut vm: *mut mh_vm = std::ptr::null_mut();
            assert_eq!(mh_vm_new(std::ptr::null(), &mut vm), MH_OK);
            let mut out = [mh_value::zeroed()];
            let mut n: usize = 0;
            let st = mh_eval(
                vm,
                mh_str::from_slice(b"return 40 + 2"),
                mh_str::from_slice(b"sys-smoke"),
                out.as_mut_ptr(),
                1,
                &mut n,
            );
            assert_eq!(st, MH_OK);
            assert_eq!(n, 1);
            let mut x: i64 = 0;
            assert_eq!(mh_value_int(out[0], &mut x), MH_OK);
            assert_eq!(x, 42);
            assert_eq!(mh_vm_free(vm), MH_OK);
        }
    }
}
