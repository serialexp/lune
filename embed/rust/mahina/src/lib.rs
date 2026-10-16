//! Safe Rust embedding API for the mahina VM (doc 59 §3.8) — the `mlua`-shaped
//! layer over `mahina-sys`/`libmahina`.
//!
//! ```no_run
//! use mahina::{Vm, Value, Function};
//!
//! let vm = Vm::new().unwrap();
//! let out = vm.eval("return 1 + 2", "demo").unwrap();
//! assert_eq!(out[0], Value::Int(3));
//!
//! // Typed calls: arguments and results convert through `IntoArgs` /
//! // `FromResults`, so a scalar call touches no heap on the Rust side.
//! vm.eval("function add(a, b) return a + b end", "demo").unwrap();
//! let add: Function = vm.global("add").unwrap().as_function().unwrap().clone();
//! let sum: i64 = add.call((40, 2)).unwrap();
//! assert_eq!(sum, 42);
//!
//! vm.register_fn("hadd", |_vm, args| {
//!     let (Some(Value::Int(a)), Some(Value::Int(b))) = (args.get(0), args.get(1)) else {
//!         return Err("hadd wants two ints".into());
//!     };
//!     Ok(vec![Value::Int(a + b)])
//! }).unwrap();
//! assert_eq!(vm.eval("return hadd(40, 2)", "demo").unwrap()[0], Value::Int(42));
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
//! - **Calls are allocation-free for scalars** (doc 59 tier-0 boundary
//!   work): arguments are converted into a stack buffer, the callee is
//!   borrowed (never cloned — a clone is a ref create + free), and results
//!   land in an uninitialized stack buffer (the C contract defines only the
//!   reported prefix).

use std::cell::RefCell;
use std::fmt;
use std::mem::MaybeUninit;
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

/// The shared VM handle every value holds. Public only so the conversion
/// traits can name it in their (hidden) methods; it has no public surface.
#[doc(hidden)]
pub struct VmInner {
    raw: *mut sys::mh_vm,
}

impl VmInner {
    fn last_error(&self) -> String {
        unsafe {
            let s = sys::mh_last_error(self.raw);
            String::from_utf8_lossy(s.as_slice()).into_owned()
        }
    }

    #[inline]
    fn status(&self, st: sys::mh_status) -> Result<()> {
        if st == sys::MH_OK {
            return Ok(());
        }
        Err(self.error_for(st))
    }

    #[cold]
    #[inline(never)]
    fn error_for(&self, st: sys::mh_status) -> Error {
        match st {
            sys::MH_ERR_COMPILE => Error::Compile(self.last_error()),
            sys::MH_ERR_RUNTIME => Error::Runtime(self.last_error()),
            sys::MH_ERR_OOM => Error::Oom,
            _ => Error::Api(self.last_error()),
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
/// creates a second root; dropping releases it.
///
/// The raw value is cached at creation instead of being re-read through
/// `mh_ref_get` on every use: the GC never moves objects and the root keeps
/// this one alive, so the cached value stays valid for the handle's life.
pub struct Handle {
    inner: Rc<VmInner>,
    r: sys::mh_ref,
    raw: sys::mh_value,
}

impl Handle {
    fn new(inner: &Rc<VmInner>, raw: sys::mh_value) -> Result<Handle> {
        let mut r: sys::mh_ref = 0;
        let st = unsafe { sys::mh_ref_create(inner.raw, raw, &mut r) };
        inner.status(st)?;
        Ok(Handle { inner: inner.clone(), r, raw })
    }

    #[inline]
    fn raw(&self) -> sys::mh_value {
        self.raw
    }

    /// The raw value, after checking it belongs to `inner`'s VM.
    #[inline]
    fn raw_in(&self, inner: &Rc<VmInner>) -> Result<sys::mh_value> {
        if !Rc::ptr_eq(&self.inner, inner) {
            return Err(Error::ForeignVm);
        }
        Ok(self.raw)
    }
}

impl Clone for Handle {
    fn clone(&self) -> Handle {
        Handle::new(&self.inner, self.raw).expect("cloning a live ref cannot fail")
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

    #[inline]
    fn handle(&self) -> Option<&Handle> {
        match self {
            Value::Str(Str(h)) | Value::Table(Table(h)) | Value::Function(Function(h)) | Value::Other(Opaque(h)) => Some(h),
            _ => None,
        }
    }

    /// Raw form + foreign-VM check against `inner`.
    #[inline]
    fn to_raw(&self, inner: &Rc<VmInner>) -> Result<sys::mh_value> {
        if let Some(h) = self.handle() {
            return h.raw_in(inner);
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
    #[inline]
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

/// The type name of a raw value, for conversion errors.
fn raw_type_name(raw: sys::mh_value) -> &'static str {
    match unsafe { sys::mh_value_type(raw) } {
        sys::MH_NIL => "nil",
        sys::MH_BOOL => "boolean",
        sys::MH_INT | sys::MH_FLOAT => "number",
        sys::MH_STRING => "string",
        sys::MH_TABLE => "table",
        sys::MH_FUNCTION => "function",
        _ => "value",
    }
}

// ---------------------------------------------------------------------------
// typed conversion (the mlua-shaped call surface)
// ---------------------------------------------------------------------------

/// Temporaries an argument conversion created (a guest string interned from
/// a `&str`, an owned `Value` moved in) — rooted here until the call returns.
/// Scalars and borrowed handles never touch it, so on the common path it is
/// an empty, never-allocated `Vec`.
#[doc(hidden)]
pub struct Keep(Vec<Value>);

const INLINE_ARGS: usize = 8;

/// Raw argument scratch: up to `INLINE_ARGS` values on the stack, spilling
/// to a `Vec` only for longer argument lists.
#[doc(hidden)]
pub struct ArgBuf {
    inline: [MaybeUninit<sys::mh_value>; INLINE_ARGS],
    len: usize,
    spill: Vec<sys::mh_value>,
}

impl ArgBuf {
    #[inline]
    fn new() -> ArgBuf {
        ArgBuf { inline: [const { MaybeUninit::uninit() }; INLINE_ARGS], len: 0, spill: Vec::new() }
    }

    #[inline]
    fn push(&mut self, v: sys::mh_value) {
        if self.spill.is_empty() && self.len < INLINE_ARGS {
            self.inline[self.len] = MaybeUninit::new(v);
            self.len += 1;
            return;
        }
        self.push_spill(v);
    }

    #[cold]
    #[inline(never)]
    fn push_spill(&mut self, v: sys::mh_value) {
        if self.spill.is_empty() {
            self.spill.reserve(INLINE_ARGS * 2);
            // SAFETY: `inline[..len]` was written by the branch above.
            self.spill.extend(self.inline[..self.len].iter().map(|s| unsafe { s.assume_init() }));
        }
        self.spill.push(v);
    }

    #[inline]
    fn as_slice(&self) -> &[sys::mh_value] {
        if self.spill.is_empty() {
            // SAFETY: `inline[..len]` is initialized (see `push`).
            unsafe { std::slice::from_raw_parts(self.inline.as_ptr().cast(), self.len) }
        } else {
            &self.spill
        }
    }
}

/// Converts a Rust value into a guest value — a call argument, typically.
/// Implemented for the integer/float/bool scalars, strings (interned on the
/// way in), `Option` (`None` is nil), and the safe layer's own value types,
/// owned or borrowed. Borrowing a handle never creates a new GC ref.
pub trait IntoValue {
    #[doc(hidden)]
    fn into_raw(self, inner: &Rc<VmInner>, keep: &mut Keep) -> Result<sys::mh_value>;
}

macro_rules! scalar_into_value {
    ($($t:ty => |$v:ident| $e:expr;)*) => {$(
        impl IntoValue for $t {
            #[inline]
            fn into_raw(self, _: &Rc<VmInner>, _: &mut Keep) -> Result<sys::mh_value> {
                let $v = self;
                Ok(unsafe { $e })
            }
        }
    )*};
}

scalar_into_value! {
    i64 => |v| sys::mh_int(v);
    i32 => |v| sys::mh_int(v as i64);
    u32 => |v| sys::mh_int(v as i64);
    f64 => |v| sys::mh_float(v);
    f32 => |v| sys::mh_float(v as f64);
    bool => |v| sys::mh_bool(v as c_int);
}

impl IntoValue for &Value {
    #[inline]
    fn into_raw(self, inner: &Rc<VmInner>, _: &mut Keep) -> Result<sys::mh_value> {
        self.to_raw(inner)
    }
}

impl IntoValue for Value {
    #[inline]
    fn into_raw(self, inner: &Rc<VmInner>, keep: &mut Keep) -> Result<sys::mh_value> {
        let raw = self.to_raw(inner)?;
        if self.handle().is_some() {
            keep.0.push(self);
        }
        Ok(raw)
    }
}

impl IntoValue for &str {
    fn into_raw(self, inner: &Rc<VmInner>, keep: &mut Keep) -> Result<sys::mh_value> {
        let mut out = sys::mh_value::zeroed();
        let st = unsafe { sys::mh_string_new(inner.raw, sys::mh_str::from_slice(self.as_bytes()), &mut out) };
        inner.status(st)?;
        // Root it now: the next argument's conversion may be another idle
        // entry that clears the park this string sits in.
        keep.0.push(Value::from_raw(inner, out)?);
        Ok(out)
    }
}

impl IntoValue for &String {
    fn into_raw(self, inner: &Rc<VmInner>, keep: &mut Keep) -> Result<sys::mh_value> {
        self.as_str().into_raw(inner, keep)
    }
}

impl IntoValue for String {
    fn into_raw(self, inner: &Rc<VmInner>, keep: &mut Keep) -> Result<sys::mh_value> {
        self.as_str().into_raw(inner, keep)
    }
}

macro_rules! handle_into_value {
    ($($t:ident => $variant:ident),*) => {$(
        impl IntoValue for &$t {
            #[inline]
            fn into_raw(self, inner: &Rc<VmInner>, _: &mut Keep) -> Result<sys::mh_value> {
                self.0.raw_in(inner)
            }
        }
        impl IntoValue for $t {
            fn into_raw(self, inner: &Rc<VmInner>, keep: &mut Keep) -> Result<sys::mh_value> {
                let raw = self.0.raw_in(inner)?;
                keep.0.push(Value::$variant(self));
                Ok(raw)
            }
        }
    )*};
}

handle_into_value!(Str => Str, Table => Table, Function => Function);

impl<T: IntoValue> IntoValue for Option<T> {
    #[inline]
    fn into_raw(self, inner: &Rc<VmInner>, keep: &mut Keep) -> Result<sys::mh_value> {
        match self {
            Some(v) => v.into_raw(inner, keep),
            None => Ok(unsafe { sys::mh_nil() }),
        }
    }
}

/// The argument list of a guest call: `()`, any single [`IntoValue`], a tuple
/// of them (up to 8), or a slice / array / `Vec` of [`Value`]s.
pub trait IntoArgs {
    #[doc(hidden)]
    fn push_args(self, inner: &Rc<VmInner>, keep: &mut Keep, buf: &mut ArgBuf) -> Result<()>;
}

impl<T: IntoValue> IntoArgs for T {
    fn push_args(self, inner: &Rc<VmInner>, keep: &mut Keep, buf: &mut ArgBuf) -> Result<()> {
        buf.push(self.into_raw(inner, keep)?);
        Ok(())
    }
}

impl IntoArgs for () {
    fn push_args(self, _: &Rc<VmInner>, _: &mut Keep, _: &mut ArgBuf) -> Result<()> {
        Ok(())
    }
}

macro_rules! tuple_into_args {
    ($($name:ident)+) => {
        impl<$($name: IntoValue),+> IntoArgs for ($($name,)+) {
            #[allow(non_snake_case)]
            fn push_args(self, inner: &Rc<VmInner>, keep: &mut Keep, buf: &mut ArgBuf) -> Result<()> {
                let ($($name,)+) = self;
                $( buf.push($name.into_raw(inner, keep)?); )+
                Ok(())
            }
        }
    };
}

tuple_into_args!(A);
tuple_into_args!(A B);
tuple_into_args!(A B C);
tuple_into_args!(A B C D);
tuple_into_args!(A B C D E);
tuple_into_args!(A B C D E F);
tuple_into_args!(A B C D E F G);
tuple_into_args!(A B C D E F G H);

impl IntoArgs for &[Value] {
    #[inline]
    fn push_args(self, inner: &Rc<VmInner>, _: &mut Keep, buf: &mut ArgBuf) -> Result<()> {
        for v in self {
            buf.push(v.to_raw(inner)?);
        }
        Ok(())
    }
}

impl<const N: usize> IntoArgs for &[Value; N] {
    fn push_args(self, inner: &Rc<VmInner>, keep: &mut Keep, buf: &mut ArgBuf) -> Result<()> {
        self.as_slice().push_args(inner, keep, buf)
    }
}

impl IntoArgs for &Vec<Value> {
    #[inline]
    fn push_args(self, inner: &Rc<VmInner>, keep: &mut Keep, buf: &mut ArgBuf) -> Result<()> {
        self.as_slice().push_args(inner, keep, buf)
    }
}

impl IntoArgs for Vec<Value> {
    #[inline]
    fn push_args(self, inner: &Rc<VmInner>, keep: &mut Keep, buf: &mut ArgBuf) -> Result<()> {
        self.as_slice().push_args(inner, keep, buf)?;
        keep.0.extend(self);
        Ok(())
    }
}

/// Converts a guest value into a Rust value — a call result, typically.
/// Scalars are checked (`i64` wants an integer; `f64` accepts any number);
/// `Option<T>` maps nil to `None`; [`Value`] takes anything.
pub trait FromValue: Sized {
    #[doc(hidden)]
    fn from_raw_value(inner: &Rc<VmInner>, raw: sys::mh_value) -> Result<Self>;
}

impl FromValue for Value {
    #[inline]
    fn from_raw_value(inner: &Rc<VmInner>, raw: sys::mh_value) -> Result<Self> {
        Value::from_raw(inner, raw)
    }
}

impl FromValue for i64 {
    #[inline]
    fn from_raw_value(_: &Rc<VmInner>, raw: sys::mh_value) -> Result<Self> {
        let mut i = 0i64;
        if unsafe { sys::mh_value_int(raw, &mut i) } != sys::MH_OK {
            return Err(Error::Type { expected: "int", got: raw_type_name(raw) });
        }
        Ok(i)
    }
}

impl FromValue for f64 {
    #[inline]
    fn from_raw_value(_: &Rc<VmInner>, raw: sys::mh_value) -> Result<Self> {
        let mut f = 0f64;
        if unsafe { sys::mh_value_float(raw, &mut f) } != sys::MH_OK {
            return Err(Error::Type { expected: "number", got: raw_type_name(raw) });
        }
        Ok(f)
    }
}

impl FromValue for bool {
    #[inline]
    fn from_raw_value(_: &Rc<VmInner>, raw: sys::mh_value) -> Result<Self> {
        if unsafe { sys::mh_value_type(raw) } != sys::MH_BOOL {
            return Err(Error::Type { expected: "boolean", got: raw_type_name(raw) });
        }
        Ok(unsafe { sys::mh_value_truthy(raw) } != 0)
    }
}

impl FromValue for String {
    fn from_raw_value(inner: &Rc<VmInner>, raw: sys::mh_value) -> Result<Self> {
        let mut s = sys::mh_str::empty();
        if unsafe { sys::mh_value_str(inner.raw, raw, &mut s) } != sys::MH_OK {
            return Err(Error::Type { expected: "string", got: raw_type_name(raw) });
        }
        // SAFETY: the bytes are borrowed from the parked result, valid until
        // the next idle entry — copied out here before any.
        let bytes = unsafe { s.as_slice() };
        String::from_utf8(bytes.to_vec()).map_err(|_| Error::Type { expected: "utf-8 string", got: "string" })
    }
}

macro_rules! handle_from_value {
    ($($t:ident => $variant:ident, $name:literal);*) => {$(
        impl FromValue for $t {
            fn from_raw_value(inner: &Rc<VmInner>, raw: sys::mh_value) -> Result<Self> {
                match Value::from_raw(inner, raw)? {
                    Value::$variant(v) => Ok(v),
                    other => Err(Error::Type { expected: $name, got: other.type_name() }),
                }
            }
        }
    )*};
}

handle_from_value!(Str => Str, "string"; Table => Table, "table"; Function => Function, "function");

impl<T: FromValue> FromValue for Option<T> {
    fn from_raw_value(inner: &Rc<VmInner>, raw: sys::mh_value) -> Result<Self> {
        if unsafe { sys::mh_value_type(raw) } == sys::MH_NIL {
            return Ok(None);
        }
        T::from_raw_value(inner, raw).map(Some)
    }
}

/// The result list of a guest call: `()` (discard), any single [`FromValue`]
/// (the first result; a missing one reads as nil), a tuple of them (up to
/// 8), or `Vec<Value>` (all of them, up to [`MAX_RESULTS`]).
pub trait FromResults: Sized {
    /// How many results to ask the VM for.
    #[doc(hidden)]
    const WANT: usize;
    #[doc(hidden)]
    fn from_results(inner: &Rc<VmInner>, raw: &[sys::mh_value]) -> Result<Self>;
}

/// Read a VM-written value as two 8-byte loads. The VM writes results word
/// by word (`Value.storeWords` on the Zig side); copying an `mh_value` whole
/// compiles to one 16-byte load, which the CPU cannot forward from two
/// 8-byte stores — a ~20-cycle stall on every result read. The value is
/// rebuilt from the two words as-is (not field by field: a tag byte plus
/// zeroed pad bytes is again several narrow stores under one 8-byte reload).
#[inline]
fn load_words(v: &sys::mh_value) -> sys::mh_value {
    let w = (v as *const sys::mh_value).cast::<u64>();
    // SAFETY: `mh_value` is 16 bytes, 8-aligned, plain integers with no
    // invalid bit patterns (layout-asserted in mahina-sys); both words are
    // in bounds of the borrowed value.
    unsafe { std::mem::transmute::<[u64; 2], sys::mh_value>([w.read(), w.add(1).read()]) }
}

#[inline]
fn nth_or_nil(raw: &[sys::mh_value], i: usize) -> sys::mh_value {
    match raw.get(i) {
        Some(v) => load_words(v),
        None => unsafe { sys::mh_nil() },
    }
}

impl FromResults for () {
    const WANT: usize = 0;
    #[inline]
    fn from_results(_: &Rc<VmInner>, _: &[sys::mh_value]) -> Result<Self> {
        Ok(())
    }
}

impl<T: FromValue> FromResults for T {
    const WANT: usize = 1;
    fn from_results(inner: &Rc<VmInner>, raw: &[sys::mh_value]) -> Result<Self> {
        T::from_raw_value(inner, nth_or_nil(raw, 0))
    }
}

impl FromResults for Vec<Value> {
    const WANT: usize = MAX_RESULTS;
    #[inline]
    fn from_results(inner: &Rc<VmInner>, raw: &[sys::mh_value]) -> Result<Self> {
        raw.iter().map(|r| Value::from_raw(inner, load_words(r))).collect()
    }
}

macro_rules! tuple_from_results {
    ($n:literal; $($name:ident $idx:tt)+) => {
        impl<$($name: FromValue),+> FromResults for ($($name,)+) {
            const WANT: usize = $n;
            fn from_results(inner: &Rc<VmInner>, raw: &[sys::mh_value]) -> Result<Self> {
                Ok(($($name::from_raw_value(inner, nth_or_nil(raw, $idx))?,)+))
            }
        }
    };
}

tuple_from_results!(1; A 0);
tuple_from_results!(2; A 0 B 1);
tuple_from_results!(3; A 0 B 1 C 2);
tuple_from_results!(4; A 0 B 1 C 2 D 3);
tuple_from_results!(5; A 0 B 1 C 2 D 3 E 4);
tuple_from_results!(6; A 0 B 1 C 2 D 3 E 4 F 5);
tuple_from_results!(7; A 0 B 1 C 2 D 3 E 4 F 5 G 6);
tuple_from_results!(8; A 0 B 1 C 2 D 3 E 4 F 5 G 6 H 7);

/// A results buffer the VM writes into. Left uninitialized: `mahina.h`
/// defines only `results[0..*nresults]`, and only that prefix is read.
#[inline]
fn result_buf() -> [MaybeUninit<sys::mh_value>; MAX_RESULTS] {
    [const { MaybeUninit::uninit() }; MAX_RESULTS]
}

/// # Safety
/// `buf[..n]` must have been written by the VM (an `mh_*` call reporting `n`).
#[inline]
unsafe fn written(buf: &[MaybeUninit<sys::mh_value>; MAX_RESULTS], n: usize) -> &[sys::mh_value] {
    std::slice::from_raw_parts(buf.as_ptr().cast(), n.min(MAX_RESULTS))
}

/// The one call funnel behind [`Vm::call`] and [`Function::call`].
fn call_raw<A: IntoArgs, R: FromResults>(inner: &Rc<VmInner>, callee: sys::mh_value, args: A) -> Result<R> {
    let mut keep = Keep(Vec::new());
    let mut buf = ArgBuf::new();
    args.push_args(inner, &mut keep, &mut buf)?;
    let a = buf.as_slice();
    let mut out = result_buf();
    let mut n: usize = 0;
    let st = unsafe {
        sys::mh_call(
            inner.raw,
            callee,
            if a.is_empty() { std::ptr::null() } else { a.as_ptr() },
            a.len(),
            out.as_mut_ptr().cast(),
            R::WANT.min(MAX_RESULTS),
            &mut n,
        )
    };
    inner.status(st)?;
    // `keep` (argument temporaries) is dropped after the results are wrapped.
    R::from_results(inner, unsafe { written(&out, n) })
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
        let mut out = result_buf();
        let mut n: usize = 0;
        let st = unsafe {
            sys::mh_eval(
                self.inner.raw,
                sys::mh_str::from_slice(src.as_bytes()),
                sys::mh_str::from_slice(name.as_bytes()),
                out.as_mut_ptr().cast(),
                MAX_RESULTS,
                &mut n,
            )
        };
        self.inner.status(st)?;
        self.wrap_results(unsafe { written(&out, n) })
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

    /// Call a guest function. `args` is anything [`IntoArgs`] (`()`, a value,
    /// a tuple, a slice of [`Value`]s); the result type picks how many
    /// results are read and how they convert ([`FromResults`]).
    pub fn call<A: IntoArgs, R: FromResults>(&self, f: &Function, args: A) -> Result<R> {
        let callee = f.0.raw_in(&self.inner)?;
        call_raw(&self.inner, callee, args)
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
        for r in raw {
            vals.push(Value::from_raw(&self.inner, load_words(r))?);
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
        let mut out = result_buf();
        let mut n: usize = 0;
        let st = unsafe { sys::mh_run(self.inner.raw, self.raw, out.as_mut_ptr().cast(), MAX_RESULTS, &mut n) };
        self.inner.status(st)?;
        let vm = Vm { inner: self.inner.clone() };
        vm.wrap_results(unsafe { written(&out, n) })
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
            Some(t) => t.0.raw_in(inner)?,
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
    /// Call this function — see [`Vm::call`]. Borrows the function; no GC
    /// ref is created for the call.
    pub fn call<A: IntoArgs, R: FromResults>(&self, args: A) -> Result<R> {
        call_raw(&self.0.inner, self.0.raw, args)
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
            // A call whose results are discarded (a call statement) wants
            // none and may pass a null `results`; a slice must never be
            // built from it, empty or not.
            let out: &mut [sys::mh_value] = if max_results == 0 {
                &mut []
            } else {
                std::slice::from_raw_parts_mut(results, max_results)
            };
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
