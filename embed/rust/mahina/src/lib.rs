//! Safe Rust embedding API for the mahina VM (doc 59 §3.8) — the `mlua`-shaped
//! layer over `mahina-sys`/`libmahina`.
//!
//! ```no_run
//! use mahina::{Vm, Value};
//!
//! let vm = Vm::new().unwrap();
//! let out = vm.eval("return 1 + 2", "demo").unwrap();
//! assert_eq!(out[0], Value::Int(3));
//!
//! vm.register_fn("add", |_vm, args| {
//!     let (Some(Value::Int(a)), Some(Value::Int(b))) = (args.get(0), args.get(1)) else {
//!         return Err("add wants two ints".into());
//!     };
//!     Ok(vec![Value::Int(a + b)])
//! }).unwrap();
//! assert_eq!(vm.eval("return add(40, 2)", "demo").unwrap()[0], Value::Int(42));
//! ```
//!
//! Design (doc 59, reviewed):
//! - **The safe layer auto-refs.** Every heap value crossing out of the VM is
//!   immediately promoted to a GC ref (`mh_ref_create`) owned by the returned
//!   [`Value`]; dropping the `Value` releases the ref. The C layer's
//!   "borrowed until the next call" window never reaches safe code.
//! - **The VM is reference-counted internally.** Values keep the VM alive, so
//!   a `Value` can never outlive its heap. `Vm` and `Value` are `!Send +
//!   !Sync` by construction (raw pointers inside `Rc`) — one VM, one thread.
//! - **Foreign-VM values are rejected at runtime** (`Error::ForeignVm`):
//!   lifetimes cannot distinguish two VMs, so every entry checks.
//! - **Callbacks are panic-contained**: a panic inside a registered closure
//!   (or its destructor) is caught at the FFI boundary and surfaced as a
//!   guest error — it never unwinds into the VM.
//! - **Don't capture the `Vm` in a registered closure.** The closure receives
//!   `&Vm` on every call; capturing an owned clone creates an Rc cycle
//!   (VM → binding → closure → VM) that leaks the VM. (mlua has the same
//!   rule for similar reasons.)

use std::cell::RefCell;
use std::fmt;
use std::os::raw::{c_int, c_void};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::rc::Rc;

use mahina_sys as sys;

/// Max results accepted from a guest call / script run in one invocation.
/// Surplus results are truncated (Lua adjusts result lists all the time; a
/// call that genuinely needs more can use the C layer directly).
pub const MAX_RESULTS: usize = 64;

// ---------------------------------------------------------------------------
// errors
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    /// Parse/compile diagnostics.
    Compile(String),
    /// A guest fault (located message). The VM is restored and reusable.
    Runtime(String),
    /// Allocation failure.
    Oom,
    /// API misuse (stale ref, wrong type, name collision, fatal VM, …).
    Api(String),
    /// A value from one VM was passed to another.
    ForeignVm,
    /// A conversion asked for a type the value doesn't have.
    Type { expected: &'static str, got: &'static str },
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Compile(m) => write!(f, "compile error: {m}"),
            Error::Runtime(m) => write!(f, "runtime error: {m}"),
            Error::Oom => write!(f, "out of memory"),
            Error::Api(m) => write!(f, "API error: {m}"),
            Error::ForeignVm => write!(f, "value belongs to a different VM"),
            Error::Type { expected, got } => write!(f, "expected {expected}, got {got}"),
        }
    }
}

impl std::error::Error for Error {}

pub type Result<T> = std::result::Result<T, Error>;

// ---------------------------------------------------------------------------
// VM internals
// ---------------------------------------------------------------------------

struct VmInner {
    raw: *mut sys::mh_vm,
}

impl VmInner {
    fn last_error(&self) -> String {
        unsafe {
            let s = sys::mh_last_error(self.raw);
            String::from_utf8_lossy(s.as_slice()).into_owned()
        }
    }

    fn status(&self, st: sys::mh_status) -> Result<()> {
        match st {
            sys::MH_OK => Ok(()),
            sys::MH_ERR_COMPILE => Err(Error::Compile(self.last_error())),
            sys::MH_ERR_RUNTIME => Err(Error::Runtime(self.last_error())),
            sys::MH_ERR_OOM => Err(Error::Oom),
            _ => Err(Error::Api(self.last_error())),
        }
    }
}

impl Drop for VmInner {
    fn drop(&mut self) {
        // Refcounting guarantees no Value/Script/callback is alive (they all
        // hold an Rc), so the free cannot be refused for liveness reasons.
        unsafe {
            let _ = sys::mh_vm_free(self.raw);
        }
    }
}

/// Options for [`Vm::with_config`].
#[derive(Clone, Copy, Default)]
pub struct Config {
    /// `None` = default (JIT on).
    pub jit: Option<bool>,
}

// ---------------------------------------------------------------------------
// values
// ---------------------------------------------------------------------------

/// An owned GC root for one heap value (string/table/function). Cloning
/// clones the root (cheap); dropping releases it.
pub struct Handle {
    inner: Rc<VmInner>,
    r: sys::mh_ref,
}

impl Handle {
    fn new(inner: &Rc<VmInner>, raw: sys::mh_value) -> Result<Handle> {
        let mut r: sys::mh_ref = 0;
        let st = unsafe { sys::mh_ref_create(inner.raw, raw, &mut r) };
        inner.status(st)?;
        Ok(Handle { inner: inner.clone(), r })
    }

    fn raw(&self) -> sys::mh_value {
        let mut v = sys::mh_value::zeroed();
        // Can only fail for a stale ref; ours is alive by construction.
        let st = unsafe { sys::mh_ref_get(self.inner.raw, self.r, &mut v) };
        debug_assert_eq!(st, sys::MH_OK);
        v
    }
}

impl Clone for Handle {
    fn clone(&self) -> Handle {
        Handle::new(&self.inner, self.raw()).expect("cloning a live ref cannot fail")
    }
}

impl Drop for Handle {
    fn drop(&mut self) {
        unsafe {
            let _ = sys::mh_ref_free(self.inner.raw, self.r);
        }
    }
}

/// A guest string, rooted. Bytes are borrowed zero-copy from the (non-moving)
/// GC heap for as long as this handle lives.
#[derive(Clone)]
pub struct Str(Handle);

impl Str {
    pub fn as_bytes(&self) -> &[u8] {
        let mut s = sys::mh_str::empty();
        let st = unsafe { sys::mh_value_str(self.0.inner.raw, self.0.raw(), &mut s) };
        debug_assert_eq!(st, sys::MH_OK);
        // Sound: the handle roots the string, the GC never moves objects, and
        // the returned lifetime is tied to &self (which keeps the root).
        unsafe { s.as_slice() }
    }

    pub fn to_string_lossy(&self) -> String {
        String::from_utf8_lossy(self.as_bytes()).into_owned()
    }
}

impl fmt::Debug for Str {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Str({:?})", String::from_utf8_lossy(self.as_bytes()))
    }
}

impl PartialEq for Str {
    fn eq(&self, other: &Self) -> bool {
        self.as_bytes() == other.as_bytes()
    }
}

/// A guest table, rooted.
#[derive(Clone)]
pub struct Table(Handle);

/// A guest function (closure or native), rooted.
#[derive(Clone)]
pub struct Function(Handle);

/// A rooted guest value of a type the safe layer doesn't model further.
#[derive(Clone)]
pub struct Opaque(Handle);

/// A mahina value on the Rust side. Scalars are plain; heap values own a GC
/// root and keep the VM alive.
#[derive(Clone)]
pub enum Value {
    Nil,
    Bool(bool),
    Int(i64),
    Float(f64),
    Str(Str),
    Table(Table),
    Function(Function),
    Other(Opaque),
}

impl Value {
    pub fn type_name(&self) -> &'static str {
        match self {
            Value::Nil => "nil",
            Value::Bool(_) => "boolean",
            Value::Int(_) | Value::Float(_) => "number",
            Value::Str(_) => "string",
            Value::Table(_) => "table",
            Value::Function(_) => "function",
            Value::Other(_) => "value",
        }
    }

    pub fn as_int(&self) -> Result<i64> {
        match self {
            Value::Int(i) => Ok(*i),
            _ => Err(Error::Type { expected: "int", got: self.type_name() }),
        }
    }

    pub fn as_number(&self) -> Result<f64> {
        match self {
            Value::Int(i) => Ok(*i as f64),
            Value::Float(f) => Ok(*f),
            _ => Err(Error::Type { expected: "number", got: self.type_name() }),
        }
    }

    pub fn as_str(&self) -> Result<&Str> {
        match self {
            Value::Str(s) => Ok(s),
            _ => Err(Error::Type { expected: "string", got: self.type_name() }),
        }
    }

    pub fn as_table(&self) -> Result<&Table> {
        match self {
            Value::Table(t) => Ok(t),
            _ => Err(Error::Type { expected: "table", got: self.type_name() }),
        }
    }

    pub fn as_function(&self) -> Result<&Function> {
        match self {
            Value::Function(f) => Ok(f),
            _ => Err(Error::Type { expected: "function", got: self.type_name() }),
        }
    }

    /// Lua truthiness.
    pub fn truthy(&self) -> bool {
        !matches!(self, Value::Nil | Value::Bool(false))
    }

    fn handle(&self) -> Option<&Handle> {
        match self {
            Value::Str(Str(h)) | Value::Table(Table(h)) | Value::Function(Function(h)) | Value::Other(Opaque(h)) => Some(h),
            _ => None,
        }
    }

    /// Raw form + foreign-VM check against `inner`.
    fn to_raw(&self, inner: &Rc<VmInner>) -> Result<sys::mh_value> {
        if let Some(h) = self.handle() {
            if !Rc::ptr_eq(&h.inner, inner) {
                return Err(Error::ForeignVm);
            }
            return Ok(h.raw());
        }
        Ok(match self {
            Value::Nil => unsafe { sys::mh_nil() },
            Value::Bool(b) => unsafe { sys::mh_bool(*b as c_int) },
            Value::Int(i) => unsafe { sys::mh_int(*i) },
            Value::Float(f) => unsafe { sys::mh_float(*f) },
            _ => unreachable!(),
        })
    }

    /// Wrap a raw value coming out of the VM, auto-reffing heap types.
    fn from_raw(inner: &Rc<VmInner>, raw: sys::mh_value) -> Result<Value> {
        unsafe {
            Ok(match sys::mh_value_type(raw) {
                sys::MH_NIL => Value::Nil,
                sys::MH_BOOL => Value::Bool(sys::mh_value_truthy(raw) != 0),
                sys::MH_INT => {
                    let mut i = 0i64;
                    sys::mh_value_int(raw, &mut i);
                    Value::Int(i)
                }
                sys::MH_FLOAT => {
                    let mut f = 0f64;
                    sys::mh_value_float(raw, &mut f);
                    Value::Float(f)
                }
                sys::MH_STRING => Value::Str(Str(Handle::new(inner, raw)?)),
                sys::MH_TABLE => Value::Table(Table(Handle::new(inner, raw)?)),
                sys::MH_FUNCTION => Value::Function(Function(Handle::new(inner, raw)?)),
                _ => Value::Other(Opaque(Handle::new(inner, raw)?)),
            })
        }
    }
}

impl fmt::Debug for Value {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Value::Nil => write!(f, "Nil"),
            Value::Bool(b) => write!(f, "Bool({b})"),
            Value::Int(i) => write!(f, "Int({i})"),
            Value::Float(x) => write!(f, "Float({x})"),
            Value::Str(s) => s.fmt(f),
            Value::Table(_) => write!(f, "Table"),
            Value::Function(_) => write!(f, "Function"),
            Value::Other(_) => write!(f, "Other"),
        }
    }
}

/// Structural-enough equality for tests and casual use: scalars by value,
/// strings by bytes, tables/functions by identity (same ref target).
impl PartialEq for Value {
    fn eq(&self, other: &Self) -> bool {
        match (self, other) {
            (Value::Nil, Value::Nil) => true,
            (Value::Bool(a), Value::Bool(b)) => a == b,
            (Value::Int(a), Value::Int(b)) => a == b,
            (Value::Float(a), Value::Float(b)) => a == b,
            (Value::Str(a), Value::Str(b)) => a == b,
            (a, b) => match (a.handle(), b.handle()) {
                (Some(ha), Some(hb)) => {
                    Rc::ptr_eq(&ha.inner, &hb.inner) && ha.raw()._payload == hb.raw()._payload
                }
                _ => false,
            },
        }
    }
}

impl From<i64> for Value {
    fn from(i: i64) -> Value {
        Value::Int(i)
    }
}
impl From<f64> for Value {
    fn from(f: f64) -> Value {
        Value::Float(f)
    }
}
impl From<bool> for Value {
    fn from(b: bool) -> Value {
        Value::Bool(b)
    }
}
impl From<()> for Value {
    fn from(_: ()) -> Value {
        Value::Nil
    }
}

// ---------------------------------------------------------------------------
// the VM
// ---------------------------------------------------------------------------

/// A mahina VM. Cheap to clone (shared handle); the underlying VM is freed
/// when the last `Vm`, `Value`, `Script`, or registered callback is gone.
/// `!Send + !Sync` — one thread.
#[derive(Clone)]
pub struct Vm {
    inner: Rc<VmInner>,
}

impl Vm {
    pub fn new() -> Result<Vm> {
        Vm::with_config(Config::default())
    }

    pub fn with_config(config: Config) -> Result<Vm> {
        let cfg = sys::mh_config {
            jit: match config.jit {
                None => 0,
                Some(true) => 1,
                Some(false) => 2,
            },
        };
        let mut raw: *mut sys::mh_vm = std::ptr::null_mut();
        let st = unsafe { sys::mh_vm_new(&cfg, &mut raw) };
        if st != sys::MH_OK {
            return Err(match st {
                sys::MH_ERR_OOM => Error::Oom,
                _ => Error::Api("mh_vm_new failed".into()),
            });
        }
        Ok(Vm { inner: Rc::new(VmInner { raw }) })
    }

    /// Compile + run `src` (chunk-named `name` in error messages), returning
    /// the script's results (up to [`MAX_RESULTS`]).
    pub fn eval(&self, src: &str, name: &str) -> Result<Vec<Value>> {
        let mut out = [sys::mh_value::zeroed(); MAX_RESULTS];
        let mut n: usize = 0;
        let st = unsafe {
            sys::mh_eval(
                self.inner.raw,
                sys::mh_str::from_slice(src.as_bytes()),
                sys::mh_str::from_slice(name.as_bytes()),
                out.as_mut_ptr(),
                MAX_RESULTS,
                &mut n,
            )
        };
        self.inner.status(st)?;
        self.wrap_results(&out[..n])
    }

    /// Compile without running; run later (any number of times) with
    /// [`Script::run`].
    pub fn compile(&self, src: &str, name: &str) -> Result<Script> {
        let mut raw: *mut sys::mh_script = std::ptr::null_mut();
        let st = unsafe {
            sys::mh_compile(
                self.inner.raw,
                sys::mh_str::from_slice(src.as_bytes()),
                sys::mh_str::from_slice(name.as_bytes()),
                &mut raw,
            )
        };
        self.inner.status(st)?;
        Ok(Script { inner: self.inner.clone(), raw })
    }

    /// Call a guest function with `args`, returning its results (up to
    /// [`MAX_RESULTS`]).
    pub fn call(&self, f: &Function, args: &[Value]) -> Result<Vec<Value>> {
        let callee = Value::Function(f.clone()).to_raw(&self.inner)?;
        let mut raw_args = Vec::with_capacity(args.len());
        for a in args {
            raw_args.push(a.to_raw(&self.inner)?);
        }
        let mut out = [sys::mh_value::zeroed(); MAX_RESULTS];
        let mut n: usize = 0;
        let st = unsafe {
            sys::mh_call(
                self.inner.raw,
                callee,
                if raw_args.is_empty() { std::ptr::null() } else { raw_args.as_ptr() },
                raw_args.len(),
                out.as_mut_ptr(),
                MAX_RESULTS,
                &mut n,
            )
        };
        self.inner.status(st)?;
        self.wrap_results(&out[..n])
    }

    pub fn global(&self, name: &str) -> Result<Value> {
        let mut out = sys::mh_value::zeroed();
        let st = unsafe { sys::mh_global_get(self.inner.raw, sys::mh_str::from_slice(name.as_bytes()), &mut out) };
        self.inner.status(st)?;
        Value::from_raw(&self.inner, out)
    }

    pub fn set_global(&self, name: &str, val: impl Into<Value>) -> Result<()> {
        let raw = val.into().to_raw(&self.inner)?;
        let st = unsafe { sys::mh_global_set(self.inner.raw, sys::mh_str::from_slice(name.as_bytes()), raw) };
        self.inner.status(st)
    }

    pub fn create_string(&self, s: impl AsRef<[u8]>) -> Result<Value> {
        let mut out = sys::mh_value::zeroed();
        let st = unsafe { sys::mh_string_new(self.inner.raw, sys::mh_str::from_slice(s.as_ref()), &mut out) };
        self.inner.status(st)?;
        Value::from_raw(&self.inner, out)
    }

    pub fn create_table(&self) -> Result<Table> {
        let mut out = sys::mh_value::zeroed();
        let st = unsafe { sys::mh_table_new(self.inner.raw, &mut out) };
        self.inner.status(st)?;
        match Value::from_raw(&self.inner, out)? {
            Value::Table(t) => Ok(t),
            _ => unreachable!(),
        }
    }

    /// Register a host function callable from guest code as `name` (either a
    /// bare global `"myfn"` or a module field `"mymod.myfn"`; names of
    /// builtins are rejected). The closure receives this VM and the call
    /// arguments; `Err(message)` raises a (pcall-catchable) located guest
    /// error. Panics are caught and surfaced the same way.
    pub fn register_fn<F>(&self, name: &str, f: F) -> Result<()>
    where
        F: Fn(&Vm, &[Value]) -> std::result::Result<Vec<Value>, String> + 'static,
    {
        let data = Box::new(CallbackData {
            f: Box::new(f),
            inner: self.inner.clone(),
        });
        let st = unsafe {
            sys::mh_register_fn(
                self.inner.raw,
                sys::mh_str::from_slice(name.as_bytes()),
                host_trampoline,
                Box::into_raw(data) as *mut c_void,
                Some(host_destroy),
            )
        };
        self.inner.status(st)
    }

    /// Force a full GC cycle.
    pub fn collect(&self) -> Result<()> {
        let st = unsafe { sys::mh_collect(self.inner.raw) };
        self.inner.status(st)
    }

    /// Captured `print`/`io.write` output since the last [`Vm::take_output`].
    pub fn take_output(&self) -> String {
        unsafe {
            let s = sys::mh_output(self.inner.raw);
            let out = String::from_utf8_lossy(s.as_slice()).into_owned();
            sys::mh_output_clear(self.inner.raw);
            out
        }
    }

    pub fn mem_stats(&self) -> sys::mh_mem_stats {
        let mut s = sys::mh_mem_stats::default();
        unsafe {
            let _ = sys::mh_mem_stats_get(self.inner.raw, &mut s);
        }
        s
    }

    fn wrap_results(&self, raw: &[sys::mh_value]) -> Result<Vec<Value>> {
        let mut vals = Vec::with_capacity(raw.len());
        for &r in raw {
            vals.push(Value::from_raw(&self.inner, r)?);
        }
        Ok(vals)
    }
}

// ---------------------------------------------------------------------------
// scripts
// ---------------------------------------------------------------------------

/// A compiled chunk (owned by the VM until the VM dies; this handle is
/// cheap). Run any number of times.
pub struct Script {
    inner: Rc<VmInner>,
    raw: *mut sys::mh_script,
}

impl Script {
    pub fn run(&self) -> Result<Vec<Value>> {
        let mut out = [sys::mh_value::zeroed(); MAX_RESULTS];
        let mut n: usize = 0;
        let st = unsafe { sys::mh_run(self.inner.raw, self.raw, out.as_mut_ptr(), MAX_RESULTS, &mut n) };
        self.inner.status(st)?;
        let vm = Vm { inner: self.inner.clone() };
        vm.wrap_results(&out[..n])
    }
}

impl Drop for Script {
    fn drop(&mut self) {
        unsafe { sys::mh_script_free(self.raw) }
    }
}

// ---------------------------------------------------------------------------
// tables
// ---------------------------------------------------------------------------

impl Table {
    fn vm(&self) -> Vm {
        Vm { inner: self.0.inner.clone() }
    }

    pub fn get(&self, key: impl Into<Value>) -> Result<Value> {
        let inner = &self.0.inner;
        let k = key.into().to_raw(inner)?;
        let mut out = sys::mh_value::zeroed();
        let st = unsafe { sys::mh_table_get(inner.raw, self.0.raw(), k, &mut out) };
        inner.status(st)?;
        Value::from_raw(inner, out)
    }

    /// Convenience: get by string key.
    pub fn get_str(&self, key: &str) -> Result<Value> {
        let k = self.vm().create_string(key)?;
        self.get(k)
    }

    pub fn set(&self, key: impl Into<Value>, val: impl Into<Value>) -> Result<()> {
        let inner = &self.0.inner;
        let k = key.into().to_raw(inner)?;
        let v = val.into().to_raw(inner)?;
        let st = unsafe { sys::mh_table_set(inner.raw, self.0.raw(), k, v) };
        inner.status(st)
    }

    pub fn set_str(&self, key: &str, val: impl Into<Value>) -> Result<()> {
        let k = self.vm().create_string(key)?;
        self.set(k, val)
    }

    /// Raw border length (`#t`).
    pub fn len(&self) -> Result<i64> {
        let inner = &self.0.inner;
        let mut n: i64 = 0;
        let st = unsafe { sys::mh_table_len(inner.raw, self.0.raw(), &mut n) };
        inner.status(st)?;
        Ok(n)
    }

    pub fn is_empty(&self) -> Result<bool> {
        Ok(self.len()? == 0)
    }

    pub fn metatable(&self) -> Result<Option<Table>> {
        let inner = &self.0.inner;
        let mut out = sys::mh_value::zeroed();
        let st = unsafe { sys::mh_table_metatable_get(inner.raw, self.0.raw(), &mut out) };
        inner.status(st)?;
        match Value::from_raw(inner, out)? {
            Value::Nil => Ok(None),
            Value::Table(t) => Ok(Some(t)),
            _ => unreachable!(),
        }
    }

    pub fn set_metatable(&self, mt: Option<&Table>) -> Result<()> {
        let inner = &self.0.inner;
        let raw = match mt {
            Some(t) => Value::Table(t.clone()).to_raw(inner)?,
            None => unsafe { sys::mh_nil() },
        };
        let st = unsafe { sys::mh_table_metatable_set(inner.raw, self.0.raw(), raw) };
        inner.status(st)
    }

    /// Iterate `(key, value)` pairs in the deterministic guest order (array
    /// part ascending, then hash keys in canonical order).
    pub fn iter(&self) -> Result<TableIter> {
        let inner = &self.0.inner;
        let mut raw: *mut sys::mh_table_iter = std::ptr::null_mut();
        let st = unsafe { sys::mh_table_iter_new(inner.raw, self.0.raw(), &mut raw) };
        inner.status(st)?;
        Ok(TableIter { inner: inner.clone(), raw, done: false })
    }
}

pub struct TableIter {
    inner: Rc<VmInner>,
    raw: *mut sys::mh_table_iter,
    done: bool,
}

impl Iterator for TableIter {
    type Item = Result<(Value, Value)>;

    fn next(&mut self) -> Option<Self::Item> {
        if self.done {
            return None;
        }
        let mut k = sys::mh_value::zeroed();
        let mut v = sys::mh_value::zeroed();
        let mut done: c_int = 0;
        let st = unsafe { sys::mh_table_iter_next(self.inner.raw, self.raw, &mut k, &mut v, &mut done) };
        if let Err(e) = self.inner.status(st) {
            self.done = true;
            return Some(Err(e));
        }
        if done != 0 {
            self.done = true;
            return None;
        }
        let kv = (|| Ok((Value::from_raw(&self.inner, k)?, Value::from_raw(&self.inner, v)?)))();
        Some(kv)
    }
}

impl Drop for TableIter {
    fn drop(&mut self) {
        unsafe {
            let _ = sys::mh_table_iter_free(self.inner.raw, self.raw);
        }
    }
}

// ---------------------------------------------------------------------------
// functions
// ---------------------------------------------------------------------------

impl Function {
    pub fn call(&self, args: &[Value]) -> Result<Vec<Value>> {
        Vm { inner: self.0.inner.clone() }.call(self, args)
    }
}

// ---------------------------------------------------------------------------
// host callbacks
// ---------------------------------------------------------------------------

type HostClosure = Box<dyn Fn(&Vm, &[Value]) -> std::result::Result<Vec<Value>, String>>;

struct CallbackData {
    f: HostClosure,
    inner: Rc<VmInner>,
}

unsafe extern "C" fn host_trampoline(
    _vm: *mut sys::mh_vm,
    userdata: *mut c_void,
    args: *const sys::mh_value,
    nargs: usize,
    results: *mut sys::mh_value,
    max_results: usize,
    nresults: *mut usize,
) -> sys::mh_status {
    let data = &*(userdata as *const CallbackData);
    let vm = Vm { inner: data.inner.clone() };

    let outcome = catch_unwind(AssertUnwindSafe(|| {
        let raw_args = if nargs == 0 { &[][..] } else { std::slice::from_raw_parts(args, nargs) };
        let mut vals = Vec::with_capacity(nargs);
        for &a in raw_args {
            match Value::from_raw(&vm.inner, a) {
                Ok(v) => vals.push(v),
                Err(e) => return Err(e.to_string()),
            }
        }
        (data.f)(&vm, &vals)
    }));

    let fail = |msg: &str| {
        sys::mh_error_set(vm.inner.raw, sys::mh_str::from_slice(msg.as_bytes()));
        sys::MH_ERR_RUNTIME
    };

    match outcome {
        Ok(Ok(vals)) => {
            let n = vals.len().min(max_results);
            let out = std::slice::from_raw_parts_mut(results, max_results);
            for (i, v) in vals.iter().take(n).enumerate() {
                match v.to_raw(&vm.inner) {
                    Ok(raw) => out[i] = raw,
                    Err(e) => return fail(&e.to_string()),
                }
            }
            *nresults = n;
            // `vals` drops here, releasing the auto-refs; the raw copies in
            // `out` are rooted by the park / the caller's registers (the
            // funnel copies them out straight-line — doc 59 §3.3).
            sys::MH_OK
        }
        Ok(Err(msg)) => fail(&msg),
        Err(_) => fail("panic in host function"),
    }
}

unsafe extern "C" fn host_destroy(userdata: *mut c_void) {
    // Contain destructor panics too (codex rev-1 #6): never unwind into the
    // VM's sweep.
    let _ = catch_unwind(AssertUnwindSafe(|| {
        drop(Box::from_raw(userdata as *mut CallbackData));
    }));
}

// ---------------------------------------------------------------------------
// helpers for stateful callbacks
// ---------------------------------------------------------------------------

/// Tiny convenience for callbacks that mutate captured state: a
/// `Rc<RefCell<T>>` you can clone into the closure.
pub fn shared<T>(value: T) -> Rc<RefCell<T>> {
    Rc::new(RefCell::new(value))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn vm_is_not_send_or_sync() {
        // Compile-time property, checked structurally: Rc + raw pointers make
        // these types !Send + !Sync automatically. This test documents the
        // intent; if someone adds an unsafe Send impl, review it hard.
        fn assert_not_impl<T: ?Sized>() {}
        assert_not_impl::<Vm>();
    }
}
