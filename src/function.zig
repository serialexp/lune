//! Callable heap objects: Lua closures, captured-variable cells (upvalues), and
//! native (host/builtin) functions.
//!
//! A **closure** pairs a shared, immutable `Proto` (the compiled function body)
//! with the upvalue cells it captured at the point it was created. The `Proto`
//! is constant and shared by every closure of the same function; only the
//! upvalues differ per instance.
//!
//! An **upvalue** is a one-slot cell shared between the frame that owns the
//! variable and every closure that captured it. While the owning frame is live
//! the cell is *open* — `loc` carries the **slot index** of the live local in
//! the VM register stack. When the frame returns the cell is *closed*: the
//! current value is copied into the cell's own `loc.closed` and the index is
//! dropped, so the captured variable outlives the frame (the classic Lua
//! open/closed upvalue model). The interpreter owns the open/close timing; this
//! module only provides the cell.
//!
//! A single `*Value` can't address an open cell's value, which is split across
//! the register stack's parallel tag and payload arrays
//! (docs/design/09-soa-register-file.md). So the cell carries one pointer per
//! lane (`tag`, `payload`), aimed at the live slot's lanes while open and at
//! `loc.closed`'s once closed, and `get`/`set` go through them without asking
//! which (LuaJIT's `uv->v`; docs/design/71-tier0-upvalue-access.md).
//!
//! A **native** is a type-erased host function. Its context is passed as
//! `*anyopaque` and its error as `anyerror` *deliberately*, so this module needs
//! no import of the interpreter — that decoupling is the host-effect boundary
//! the determinism design wants (docs/design/02-determinism.md): native effects
//! cross through one narrow, explicit seam.

const std = @import("std");
const object = @import("object.zig");
const value = @import("value.zig");
const bytecode = @import("bytecode.zig");
const system = @import("system.zig");
const GcHeader = object.GcHeader;
const Value = value.Value;
const Proto = bytecode.Proto;

/// A captured-variable cell. See the module docs for the open/closed model.
pub const Upvalue = struct {
    header: GcHeader,
    /// The captured value's two lanes, wherever it lives: the open slot's in
    /// the register stack, or `loc.closed`'s. They change only together with
    /// `loc` (`reopen`, `closeWith`). The register stack is allocated once
    /// and never moves, and neither does a cell, so neither pointer dangles.
    tag: *u8,
    payload: *u64,
    /// Where the captured value lives — see `Loc`.
    loc: Loc,
    /// While open: the coroutine whose stack holds the slot (doc 73 §5.1),
    /// null for the main stack. Marking an open cell marks it, so a closure
    /// over a suspended coroutine's local keeps that stack alive.
    owner: ?*GcHeader = null,

    /// Open ⇒ the value is in the VM register stack at slot `open`. Closed ⇒
    /// the value was copied out of the departed slot and is owned here.
    pub const Loc = union(enum) {
        open: usize,
        closed: Value,
    };

    /// Allocate an *open* upvalue over live stack slot `index`, whose lanes
    /// are `tag` and `payload`. Raw allocation only — GC-linking is the
    /// heap's job (`gc.zig`).
    pub fn createOpen(gpa: std.mem.Allocator, index: usize, tag: *u8, payload: *u64) std.mem.Allocator.Error!*Upvalue {
        const self = try gpa.create(Upvalue);
        self.* = .{ .header = GcHeader.init(.upvalue), .tag = undefined, .payload = undefined, .loc = undefined };
        self.reopen(index, tag, payload);
        return self;
    }

    /// Allocate a *closed* upvalue owning `v`. Used by the keyframe restorer to
    /// build a non-dangling shell before the value/index is wired.
    pub fn createClosed(gpa: std.mem.Allocator, v: Value) std.mem.Allocator.Error!*Upvalue {
        const self = try gpa.create(Upvalue);
        self.* = .{ .header = GcHeader.init(.upvalue), .tag = undefined, .payload = undefined, .loc = undefined };
        self.closeWith(v);
        return self;
    }

    /// Open the cell over live stack slot `index`, whose lanes are `tag` and
    /// `payload`. The keyframe restorer reopens the closed shells it built.
    pub fn reopen(self: *Upvalue, index: usize, tag: *u8, payload: *u64) void {
        self.loc = .{ .open = index };
        self.tag = tag;
        self.payload = payload;
    }

    /// The captured value, wherever it lives.
    pub inline fn get(self: *const Upvalue) Value {
        return .{ .tag = @enumFromInt(self.tag.*), .payload = .{ .bits = self.payload.* } };
    }

    /// Overwrite the captured value, wherever it lives.
    pub inline fn set(self: *Upvalue, v: Value) void {
        self.tag.* = @intFromEnum(v.tag);
        self.payload.* = v.payload.bits;
    }

    pub fn fromHeader(h: *GcHeader) *Upvalue {
        // See `String.fromHeader`: `@alignCast` is a no-op on native and the
        // required alignment assertion on wasm32 (the object is allocated at
        // `@alignOf(Upvalue)`, so the cast always holds at runtime).
        return @alignCast(@fieldParentPtr("header", h));
    }

    pub fn isOpen(self: *const Upvalue) bool {
        return switch (self.loc) {
            .open => true,
            .closed => false,
        };
    }

    /// Close the cell: store `v` (snapshotted from the departing stack slot by the
    /// caller, which owns the stack) and drop the open index.
    pub fn closeWith(self: *Upvalue, v: Value) void {
        self.loc = .{ .closed = v };
        self.owner = null;
        self.tag = @ptrCast(&self.loc.closed.tag);
        self.payload = &self.loc.closed.payload.bits;
    }

    pub fn destroy(self: *Upvalue, gpa: std.mem.Allocator) void {
        gpa.destroy(self);
    }
};

/// A Lua closure: a shared prototype plus its captured upvalue cells. A normal
/// (non-`extern`) struct — `header` is the first field, so a `*GcHeader`
/// round-trips via `@fieldParentPtr` regardless of layout.
pub const Closure = struct {
    header: GcHeader,
    proto: *const Proto,
    /// One cell per `proto.upvalues` descriptor (empty for functions that
    /// capture nothing). The pointers live right after the closure, in its
    /// own allocation (LuaJIT's `GCfuncL.uvptr`), so `upvalue(i)` reaches a
    /// cell without loading this slice's pointer.
    upvalues: []*Upvalue = &.{},

    /// Allocate a closure for `proto` with room for `n_upvalues` cells (the
    /// caller fills `upvalues[i]`). Raw allocation only; the heap GC-links it.
    pub fn create(
        gpa: std.mem.Allocator,
        proto: *const Proto,
        n_upvalues: usize,
    ) std.mem.Allocator.Error!*Closure {
        const bytes = try gpa.alignedAlloc(u8, .of(Closure), allocSize(n_upvalues));
        const self: *Closure = @ptrCast(bytes.ptr);
        self.* = .{ .header = GcHeader.init(.function), .proto = proto, .upvalues = self.cells()[0..n_upvalues] };
        return self;
    }

    fn allocSize(n_upvalues: usize) usize {
        return @sizeOf(Closure) + n_upvalues * @sizeOf(*Upvalue);
    }

    inline fn cells(self: *const Closure) [*]*Upvalue {
        const start: [*]align(@alignOf(Closure)) u8 = @ptrCast(@constCast(self));
        return @ptrCast(start + @sizeOf(Closure));
    }

    /// Cell `i`, at a fixed offset from the closure.
    pub inline fn upvalue(self: *const Closure, i: usize) *Upvalue {
        return self.cells()[i];
    }

    pub fn fromHeader(h: *GcHeader) *Closure {
        // `@alignCast`: no-op on native, required wasm32 alignment assertion (see
        // `String.fromHeader`). The object is allocated at `@alignOf(Closure)`.
        return @alignCast(@fieldParentPtr("header", h));
    }

    pub fn destroy(self: *Closure, gpa: std.mem.Allocator) void {
        const start: [*]align(@alignOf(Closure)) u8 = @ptrCast(self);
        gpa.free(start[0..allocSize(self.upvalues.len)]);
    }
};

/// A native (host/builtin) function. Type-erased on purpose (see module docs):
/// the context is the running VM passed as `*anyopaque`, and the error is
/// `anyerror` — a superset of the interpreter's error set, so a native's errors
/// coerce back through the boundary. The result is trusted, not validated:
/// it must be a well-formed `Value` (e.g. a boolean's payload is 0 or 1; see
/// `Value`).
pub const NativeFn = *const fn (ctx: *anyopaque, args: []const Value) anyerror!Value;

/// A **multi-result** native. Writes up to `out.len` results into `out` (in
/// order) and returns how many results it has; the VM nil-pads `out[count..]`.
/// A native whose result count depends on its data (`table.unpack`,
/// `string.codepoint`) may return more than `out.len`, having written only
/// `out.len`: when the caller wants every result, `out` is the rest of the
/// stack, and the VM raises "stack overflow" rather than drop the excess. The VM only takes this path when the caller wants ≥2 results —
/// for 0 or 1 wanted results a multi native is called through its single-result
/// `NativeFn` projection (the *primary* value), so this fn never has to special-
/// case the truncating cases.
///
/// IMPORTANT — aliasing contract: `out` is a slice **into the caller's
/// registers**, beginning at the callee slot, and `args` begins one slot later;
/// the two therefore *overlap* (`out[1..]` covers `args[0..]`). A multi native
/// MUST read everything it needs from `args` **before** writing any of `out`.
/// This is allocation-free by design (results land straight in the destination,
/// mirroring Lua's stack), so it must not be made to copy.
pub const NativeMultiFn = *const fn (ctx: *anyopaque, args: []const Value, out: []Value) anyerror!usize;

/// The `multi` projection of a native that, as in Lua, returns nothing
/// (`print`, `table.insert`): `select('#', print())` is 0. Its `func`
/// returns `nil`, which is what one wanted result reads anyway; this
/// projection, taken when the caller wants every result or two or more,
/// runs `func` and produces none.
pub fn noResults(comptime func: NativeFn) NativeMultiFn {
    return &struct {
        fn multi(ctx: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
            _ = out;
            _ = try func(ctx, args);
            return 0;
        }
    }.multi;
}

/// Embedding (doc 59 §3.5): an embedder-registered host function. Generic Zig —
/// no C types here (the C adaptation lives entirely in `capi.zig`, per the
/// wrapper-boundary rule). `ctx` is the binding's own userdata (NOT the VM; the
/// VM arrives as the opaque second parameter so this module needn't import
/// `interp`). Writes up to `out.len` results (at most `interp.max_host_results`)
/// and returns the count produced; the VM nil-pads the rest. Unlike
/// `NativeMultiFn`, `out` NEVER aliases `args` and nothing else writes it
/// while the host fn runs, nested VM calls included: the invocation funnel
/// (`Vm.callHostNative`) hands it a private buffer and copies the results out
/// afterwards. So a host fn may write results before it finishes reading args,
/// or before it calls back into the VM. Results are trusted as well-formed
/// `Value`s (a boolean's payload is 0 or 1); the C adapter validates its host's
/// results with `capi.fromC` before they get here.
pub const HostFn = *const fn (ctx: ?*anyopaque, vm: *anyopaque, args: []const Value, out: []Value) anyerror!usize;

/// Embedding (doc 59 §3.5): the per-registration state a host `Native` carries.
/// **Owned by the `Native` heap object**: `Native.destroy` runs `destroy(ctx)`
/// (releasing e.g. a boxed Rust closure the moment the guest drops the last
/// reference, at GC time — not at VM teardown) and frees `name` + the binding
/// itself. Individually heap-allocated so its address is stable for the
/// `Native`'s lifetime. `name` is a gpa-owned copy of the registration name;
/// `Native.name` aliases it, so the bytes live exactly as long as the Native
/// (never a borrowed C pointer, never a GC-interned string that could be swept).
pub const HostBinding = struct {
    call: HostFn,
    ctx: ?*anyopaque = null,
    destroy: ?*const fn (?*anyopaque) void = null,
    name: []u8,
};

/// Which **recordable builtin** a native is, if any — the JIT's stable,
/// replay-safe identity for a native whose calls the trace recorder knows how
/// to record (doc 23): as a fold-to-constant, a reuse of existing IR shapes,
/// or a dedicated leaf op / runtime callout (e.g. `math.sqrt` → `fsqrt` → one
/// `sqrtsd`). Null ⇒ the native is opaque to the recorder (a `recCall` to it
/// aborts with `.host_barrier`). NOTE: "recordable" is *not* "pure" — `rawset`
/// mutates its table; what every member shares is being **deterministic core**
/// (no host effects, no nondeterministic inputs) so a trace may model it.
///
/// It is an **enum, never a pointer**: the trace bakes in "callee is this builtin"
/// and a `guard_builtin` op (present in both the tier-1a oracle and native code)
/// side-exits to tier-0 when the seeded callee no longer carries this tag. Because
/// the keyframe restorer rebinds natives by registry name, `recorded` rides the
/// registry (set from `interp.base_natives` at install and restore, like `effect`/
/// `multi`) and is replay-stable by construction — no pointer is ever serialized.
/// The ordinals are a stable wire enum (carried in `fsqrt`/`guard_builtin` IR `aux`),
/// so existing values must never be renumbered; append new builtins at the end.
pub const RecordedBuiltin = enum(u8) {
    /// `math.sqrt(x)` — IEEE correctly-rounded square root. `@sqrt(f64)` (tier-0 /
    /// oracle) and native `sqrtsd` agree bit-for-bit under the default MXCSR
    /// (round-to-nearest-even; mahina never calls `fesetround`).
    sqrt = 0,
    // -- arc A of doc 23 (builtin recording breadth). Ordinals appended, never
    // renumbered. A member existing here does NOT mean every call shape records:
    // each recorder arm (trace.zig `recBuiltin`) owns its observed-shape abort
    // matrix, and a registry row only gets its `.recorded` tag once its arm is
    // implemented.
    /// `type(v)` — folds to a konst type-name string under a type guard.
    type = 1,
    /// `tostring(v)` — arc A records the konst-argument fold only (the
    /// allocating `tostr_int` path is arc B).
    tostring = 2,
    /// `tonumber(v[, base])` — konst fold / observed-number pass-through.
    tonumber = 3,
    /// `select('#', …)` — konst `'#'` selector folds to the fixed arg count.
    select = 4,
    /// `rawequal(a, b)` — NaN-safe fold subset (konst×konst, non-float same-ref).
    rawequal = 5,
    /// `rawget(t, k)` — reuses the array/hash get shapes (metatable-free tables).
    rawget = 6,
    /// `rawset(t, k, v)` — reuses the array/hash set shapes.
    rawset = 7,
    /// `rawlen(v)` — table → `alen`; konst string → byte-length fold.
    rawlen = 8,
    /// `math.sin(x)` — `fsin`, a body callout to the one shared `sinRuntime`.
    sin = 9,
    /// `math.cos(x)` — `fcos`, ditto `cosRuntime`.
    cos = 10,
    // -- arc B of doc 23/24. Same append-only discipline.
    /// `math.type(x)` — folds to a konst "integer"/"float"/nil under the same
    /// type pins as `type()` (doc 24 D4 ride-along; lands first, so it takes
    /// ordinal 11 — the doc's provisional 16 is superseded, append-only wins).
    mtype = 11,
    /// `string.len(s)` — `slen` on a proven/guarded string ref (≡ `#s`, code
    /// points). Non-allocating.
    len = 12,
    /// `string.sub(s, i[, j])` — `ssub`, the snew class (doc 24 D4). Character
    /// positions with Lua's clamping rules; a missing `j` records as a konst −1.
    sub = 13,
    /// `string.reverse(s)` — `srev` (snew class).
    reverse = 14,
    /// `string.char(c)` — `schar1`: the ONE-argument fast shape only (an
    /// `IrInstr` can't carry a variadic operand vector — codex #4); more args
    /// abort. Out-of-range `c` side-exits (tier-0 replays and raises).
    char = 15,
    /// `string.rep(s, n)` — `srep2`: the TWO-argument shape only; a separator
    /// argument aborts (codex #4 pinned arity).
    rep = 16,
    // -- doc 26: the rest of the non-pattern string surface.
    /// `string.upper(s)` — `supper` (snew class): full Unicode simple case
    /// mapping via the ONE shared `caseCore`. Heap-only on trace: the session's
    /// Unicode-version pin is a committed-trace invariant (doc 26 D1), so the
    /// kernel never touches effect state.
    upper = 17,
    /// `string.lower(s)` — `slower`, ditto.
    lower = 18,
    /// `string.codepoint(s [, i [, j]])` — `scp`: the SINGLE-result shape only
    /// (`instr.c == 1`; multi-result calls stay a barrier). Pure and
    /// non-allocating; an empty range side-exits (tier-0 renders nil).
    codepoint = 19,
    // -- doc 30: the pattern engine + string→number.
    /// `string.find(s, pat [, init [, plain]])` — plain/no-specials → `sfindp`
    /// + konst-folded end; else `smatch` + scratch projections. Matched
    /// direction only in v1; the pattern must pin (konst or `guard_sid`).
    find = 20,
    /// `string.match(s, pat [, init])` — `smatch` + whole-match/capture
    /// projections, same pinning and direction rules as `find`.
    match = 21,
    /// `@gmatch_iter(state)` — `sgmatch`, the composite iterator step (doc 30
    /// §6): shim-verified pattern identity + B03 state layout, deferred
    /// `sgm_setpos` cursor commit.
    gmatch_iter = 22,
    // -- doc 35: pure math rounding builtins (float→int).
    /// `math.floor(x)` — `ffloor`: Lua 5.4 semantics, returns an integer.
    /// Integer arguments short-circuit (the recorder emits no op); float
    /// arguments emit the `ffloor` IR op with `.ty = .int`.
    floor = 23,
    /// `math.ceil(x)` — `fceil`: same contract as `floor`, opposite direction.
    ceil = 24,
    // -- doc 43 P4.
    /// `assert(v[, message, ...])` — one deduped truthiness pin on `v` (konst /
    /// proven-number / bool → `guard_true`), arguments passed through as
    /// results. Structurally variable-result (returns ALL its arguments), so it
    /// joins `select` on the `all_results` exclusion list; a fixed `c` copies
    /// `min(nargs, c)` argument refs and nil-pads. The message argument is
    /// evaluated but unguarded (observed only on the error path, which is a
    /// side-exit by construction — a falsy `v` raises in tier-0 and aborts
    /// recording).
    assert = 25,
};

/// A builtin with a **tier-0 fast path** (doc 70): `callTail`'s native arm
/// hands the call to `opCallFast`, which computes the common argument shapes
/// straight from the register lanes — no scratch gather, no indirect call, no
/// `in_flight`/`stack_top` cover — and falls back to the native itself for
/// every other shape, so errors and edge cases stay the native's. Independent
/// of `RecordedBuiltin` (that one tracks recorder arms); never serialized, set
/// from the registry at install and at restore.
pub const FastBuiltin = enum(u8) {
    type,
    floor,
    ceil,
    sqrt,
    abs,
    min,
    max,
    /// `select('#', ...)` only; any other selector falls back.
    select,
    rawequal,
    rawget,
    rawlen,
    /// `string.len` of a string; a number argument (coerced, allocating)
    /// falls back.
    len,
    /// Every shape: `arith.toNumber` parses without allocating.
    tonumber,
    /// `math.type`: the cached "integer"/"float", or nil.
    math_type,
};

/// Which **nondeterministic input** a native represents, if any. A native with a
/// non-null `EffectKind` is a record/replay boundary: in `record` mode its result
/// is logged, in `replay` mode it is *not called* and the logged result is fed
/// back (`interp.Vm.performEffect`). The ordinals are a stable wire enum — they
/// are what `schema.Effect.kind` carries — so existing values must never be
/// renumbered. `print` is pure-output, so it has *no* `EffectKind` (null).
/// Lives here because `Native` is the carrier and this module is dependency-light
/// (no import cycle with `interp`).
pub const EffectKind = enum(u8) {
    /// `clock()` — the host wall/monotonic clock. The canonical first effect.
    clock = 0,
    /// The one nondeterministic seed behind `random()`. Acquired lazily on the
    /// first `random()` call and recorded once; the VM's PRNG reproduces the whole
    /// draw stream from it on replay (so `random()` itself logs nothing per call).
    random_seed = 1,
    /// `os.getenv(name)` — an environment-variable read. `clock`-style (the call
    /// site is the boundary): its result is logged per call. The result is a
    /// **heap string** (or nil if unset), so the effect log carries inline string
    /// bytes for this kind (see `effectser.EffectResult`).
    getenv = 2,
    // 3 and 4 were the bare `argc()`/`argv()` (removed, doc 65 Q3).
    /// `loadfile`/`dofile` file content — a file read is a nondeterministic input
    /// (the filesystem differs between machines/runs). `clock`-style (the read is
    /// the boundary): the result is the file's **bytes as a heap string**, or `nil`
    /// if the file could not be opened, so the effect log carries inline string
    /// bytes for this kind too (like `getenv`/`argv`). The *path* is ordinary
    /// program data — only the content is the effect.
    file_read = 5,
    /// The active Unicode version behind `string.upper`/`string.lower` (S-C,
    /// design doc 06). NOT a nondeterministic host input — it is a compiled-in
    /// constant — but it is *recorded* so a replay that needs a Unicode version
    /// this binary wasn't built with refuses instead of silently diverging when
    /// the case table churns. Acquired lazily on the first `upper`/`lower` and
    /// recorded **once** per session (like `random_seed`); the int result is the
    /// packed `major<<16|minor<<8|patch` version. On replay it is read back and
    /// asserted equal to the compiled version (else a fatal `UnicodeVersionMismatch`).
    unicode_version = 6,
    // Doc 65 §4.2: the `io`/`os` host operations. Each logs only its result
    // (the arguments are program data); a failure logs its error class.
    /// `io.open`, `io.tmpfile`: the handle id (an int), or a failure.
    file_open = 7,
    /// One `read` format, or one `lines` step: a string, a number, `nil` at
    /// EOF, the bytes of a `b`-mode read, or a failure.
    file_read_op = 8,
    /// `write`: `nil` on success, or a failure.
    file_write = 9,
    /// `seek`: the new position (an int), or a failure.
    file_seek = 10,
    /// `flush`, `setvbuf`, `close`: `nil` on success, or a failure.
    file_control = 11,
    /// `os.remove`, `os.rename`: `nil` on success, or a failure.
    fs_mutate = 12,
    /// `os.tmpname`: the name (a string), or a failure.
    fs_tmpname = 13,
    /// `os.time()`: the wall clock, integer seconds since the epoch.
    wall_clock = 14,
    /// The local zone at one instant, for `os.date`/`os.time(t)` in local
    /// time: a byte record (`system.LocalZone.encode`) of the offset east of
    /// UTC, whether daylight saving is in effect, and the abbreviation.
    local_zone = 15,
    /// The `io` error mode (doc 65 §4.4: 0 = raise, 1 = Lua's returns). Not a
    /// host input, but it changes what a program observes for the same logged
    /// results, so it is pinned once per session like `unicode_version` and a
    /// replay under the other mode refuses (`IoErrorModeMismatch`).
    io_error_mode = 16,
    // Doc 73 §7.6: an `aio` operation finishing. The program's waits take
    // the completions in the order they are logged, whatever order the
    // host's threads finished them in.
    /// The id of the operation that finished (an int); its `aio_result`
    /// follows.
    aio_complete = 17,
    /// How it ended: `nil` (a sleep or write finished), the bytes a read
    /// gave, or a failure.
    aio_result = 18,
};

pub const Native = struct {
    header: GcHeader,
    func: NativeFn,
    /// Debug/identity name (e.g. "print"). Not semantically meaningful.
    name: []const u8 = "?",
    /// Non-null ⇒ this native is a nondeterministic-input effect of the given
    /// kind (record/replay boundary). Null ⇒ a pure host call (e.g. `print`).
    /// Set from the `interp.base_natives` registry at install and at restore, so
    /// install and replay can never disagree about what is an effect.
    effect: ?EffectKind = null,
    /// Non-null ⇒ this native can also produce **multiple** results; the VM calls
    /// it through this fn when ≥2 results are wanted (otherwise it uses `func`, the
    /// primary-value projection). Set from the registry like `effect`. A native is
    /// never both an effect and multi-result (effects log a single value).
    multi: ?NativeMultiFn = null,
    /// Non-null ⇒ this native is a deterministic builtin the trace recorder
    /// knows how to record (see `RecordedBuiltin`). Set from the registry like
    /// `effect`/`multi`, so install and replay can never disagree.
    recorded: ?RecordedBuiltin = null,
    /// Embedding (doc 59 §3.5): non-null ⇒ an embedder-registered host function;
    /// the VM's native invocation funnel routes through `host.call` instead of
    /// `func`/`multi`. Owned by this Native (freed in `destroy`). Invariant:
    /// `host != null ⇒ recorded == null and effect == null and multi == null`
    /// (host fns are recorder-opaque — automatic trace barrier — and own their
    /// whole result protocol); asserted at creation in `capi`.
    host: ?*HostBinding = null,
    /// Doc 63 §5.9: how many calls of this host function moved
    /// `Heap.host_epoch` (a callback, a table write, a collection…),
    /// saturating. Maintained by `Vm.callHostNative` in every tier, on
    /// success and on failure. JIT-only state: the recorder and
    /// `guard_native` refuse a native once it reaches the threshold, which
    /// changes which tier runs a call, never its result. 0 for non-host
    /// natives.
    disturbs: u8 = 0,
    /// How a tier-0 `.call` invokes this native (doc 70): the call arm
    /// switches on it, instead of testing `host`, `effect` and `multi` in
    /// turn. Set with `protocolOf` wherever those fields are set (the
    /// registry rows' values are precomputed, `interp.base_templates`); the
    /// call arm asserts that it agrees with the fields.
    protocol: CallProtocol = .plain,
    /// How `itern` steps a generic `for` with this native as its iterator
    /// (doc 66). Set from the registry like `protocol`.
    itern: IternLane = .call,
    /// Values bound to this native, as Lua's C-closure upvalues
    /// (`lua_pushcclosure`): the state a library function returned to the
    /// program carries, such as `coroutine.wrap`'s coroutine. The running
    /// native reaches them through `Vm.calledNative`. Empty for a registry
    /// native; otherwise held right after the native in its own allocation
    /// (`createBound`), like `Closure.upvalues`, and traced by the collector.
    bound: []Value = &.{},

    pub const CallProtocol = union(enum(u8)) {
        /// `func`, one result.
        plain,
        /// `multi` when two or more results are wanted, else `func`.
        multi,
        /// Through the record/replay boundary (`effect`).
        effect,
        /// An embedder host function (`host`).
        host,
        /// A builtin with a tier-0 fast path (`FastBuiltin`): the fast
        /// body first, then `multi`/`func` for the shapes it doesn't take.
        fast: FastBuiltin,
    };

    /// The protocol of a native with these fields. A host function owns
    /// its whole protocol and an effect is single-result, so neither has a
    /// fast path.
    pub fn protocolOf(host: bool, effect: bool, fast: ?FastBuiltin, multi: bool) CallProtocol {
        std.debug.assert(fast == null or !(host or effect));
        if (host) return .host;
        if (effect) return .effect;
        if (fast) |which| return .{ .fast = which };
        if (multi) return .multi;
        return .plain;
    }

    /// Whether `protocol` agrees with `host`, `effect` and `multi` (which
    /// fast path, if any, is the registry's to say).
    pub fn protocolConsistent(self: *const Native) bool {
        const fast: ?FastBuiltin = switch (self.protocol) {
            .fast => |which| which,
            else => null,
        };
        return std.meta.eql(self.protocol, protocolOf(self.host != null, self.effect != null, fast, self.multi != null));
    }

    pub fn create(
        gpa: std.mem.Allocator,
        func: NativeFn,
        name: []const u8,
    ) std.mem.Allocator.Error!*Native {
        const self = try gpa.create(Native);
        self.* = .{ .header = GcHeader.init(.native), .func = func, .name = name };
        return self;
    }

    /// A copy of `template` (an unlinked registry native) with `n_bound`
    /// nil bound values for the caller to fill. Raw allocation only; the
    /// heap GC-links it.
    pub fn createBound(gpa: std.mem.Allocator, template: *const Native, n_bound: usize) std.mem.Allocator.Error!*Native {
        std.debug.assert(template.bound.len == 0 and template.host == null);
        const bytes = try gpa.alignedAlloc(u8, .of(Native), boundAllocSize(n_bound));
        const self: *Native = @ptrCast(bytes.ptr);
        self.* = template.*;
        self.header = GcHeader.init(.native);
        const start: [*]align(@alignOf(Native)) u8 = @ptrCast(self);
        const cells: [*]Value = @ptrCast(@alignCast(start + @sizeOf(Native)));
        self.bound = cells[0..n_bound];
        @memset(self.bound, Value.nil());
        return self;
    }

    fn boundAllocSize(n_bound: usize) usize {
        comptime std.debug.assert(@sizeOf(Native) % @alignOf(Value) == 0);
        return @sizeOf(Native) + n_bound * @sizeOf(Value);
    }

    pub fn fromHeader(h: *GcHeader) *Native {
        // `@alignCast`: no-op on native, required wasm32 alignment assertion (see
        // `String.fromHeader`). The object is allocated at `@alignOf(Native)`.
        return @alignCast(@fieldParentPtr("header", h));
    }

    pub fn destroy(self: *Native, gpa: std.mem.Allocator) void {
        // A host binding dies with its Native (doc 59 §3.5): run the embedder's
        // destructor (e.g. dropping a boxed Rust closure) and free the owned
        // name + binding. GC-time, so a guest dropping the last reference to a
        // registered function releases the host resources promptly.
        if (self.host) |hb| {
            if (hb.destroy) |d| d(hb.ctx);
            gpa.free(hb.name);
            gpa.destroy(hb);
        }
        if (self.bound.len == 0) return gpa.destroy(self);
        const start: [*]align(@alignOf(Native)) u8 = @ptrCast(self);
        gpa.free(start[0..boundAllocSize(self.bound.len)]);
    }
};

/// How `itern` steps a generic `for` whose iterator is a native (doc 66):
/// the call it stands for, or a call-free step of the iterator's own.
/// `opItern` tests for `next` itself and leaves for any other iterator
/// through a table indexed by this byte, so a lane costs the other
/// iterators nothing.
pub const IternLane = enum(u8) {
    /// The call `itern a, c` replaced (`opIternCall`).
    call,
    /// `ipairs`'s iterator, `@ipairs_iter` (`opIternInext`).
    inext,
};

/// One built-in native, as a *registry descriptor* (distinct from the heap
/// `Native` object above). `name` is the native's **serialized identity** — the
/// key the keyframe restorer (`keyframeser.zig`) looks up to rebind it — so it
/// must be unique across the registry; for a module function it is qualified
/// (`"string.format"`). When `module` is set the native is installed as a field
/// of that module's global table (under `field`) instead of as a bare global; a
/// plain entry (`module == null`) installs under `name`. `effect` null = pure
/// host call.
///
/// Lives here (not in `interp.zig`) so a dependency-light stdlib module —
/// e.g. `src/stdlib/math.zig` — can declare its own `[]const BaseNative` slice
/// by importing only `function`/`value`, never `interp`. `interp.base_natives`
/// is then just the comptime concatenation of those per-library slices, and the
/// library *code* never piles into the interpreter core.
pub const BaseNative = struct {
    name: []const u8,
    func: NativeFn,
    effect: ?EffectKind = null,
    /// Optional multi-result implementation (see `NativeMultiFn`). When set, `func`
    /// is the single-result *primary projection* the VM uses for 0/1 wanted
    /// results, and this is used when ≥2 are wanted.
    multi: ?NativeMultiFn = null,
    /// Non-null ⇒ a deterministic builtin the recorder can record (see `RecordedBuiltin`).
    recorded: ?RecordedBuiltin = null,
    /// Non-null ⇒ a builtin with a tier-0 fast path (see `FastBuiltin`).
    fast: ?FastBuiltin = null,
    /// `itern`'s lane for this native as a generic-`for` iterator.
    itern: IternLane = .call,
    /// If set, install into this module table (a global table) rather than as a
    /// top-level global. The unknown-global lint then knows `module` (not `name`).
    module: ?[]const u8 = null,
    /// Key within the module table (required iff `module` is set), e.g. `"format"`.
    field: ?[]const u8 = null,
    /// A native that is registered for **snapshot/restore only** — it lives in
    /// `base_natives` (so the keyframe restorer rebinds it by name) but has no
    /// global/module install slot, so `installBaseLib` skips it and the
    /// unknown-global lint ignores it. The owning library creates its heap `Native`
    /// itself (by the same `name`) and places it wherever it belongs — e.g. the
    /// default `package.searchers` array. Without this seam such a native would be
    /// unrestorable (`UnknownNative`) since the restorer resolves only by registry name.
    manual: bool = false,
    /// How many values a native made from this row carries
    /// (`Native.bound`, `Heap.newBoundNative`), and, for keyframe restore,
    /// whether a snapshot's are ones it can run with: a restored native
    /// whose bound values fail it is a malformed snapshot.
    bound: u8 = 0,
    bound_ok: ?*const fn (bound: []const Value) bool = null,
    /// The host-system groups this native belongs to (doc 65 §5.2); empty for
    /// one every VM has. A grouped native is installed by `Vm.enableSystem`,
    /// not `installBaseLib`, once any one of its groups is on — `io.read`
    /// serves stdin (`stdio`) and files (`files`) alike.
    groups: system.Groups = .none,
    /// Doc 73 §7.6: an `aio` native. It needs an asynchronous host as well
    /// as its groups, so `Vm.enableAio` installs it, not `enableSystem`.
    aio: bool = false,
};

/// A built-in **constant** installed as a field of a module table — e.g.
/// `math.pi`, `math.maxinteger`. Constants are non-heap `Value`s (numbers), so
/// they are expressible as comptime literals and a stdlib module can declare its
/// own `[]const ModuleConst` slice the same way it declares natives. Installed by
/// `interp.Vm.installBaseLib` alongside the natives.
pub const ModuleConst = struct {
    /// Module table to install into (e.g. `"math"`). Created on first use.
    module: []const u8,
    /// Key within the module table (e.g. `"pi"`).
    field: []const u8,
    /// The constant's value. Must be a non-heap `Value` (number/bool/nil) so it is
    /// a valid comptime literal with no heap dependency.
    value: Value,
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "closure embeds its header at offset 0 and round-trips" {
    var proto = Proto{ .code = &.{}, .name = "p" };
    const cl = try Closure.create(testing.allocator, &proto, 0);
    defer cl.destroy(testing.allocator);

    try testing.expectEqual(object.ObjectType.function, cl.header.type);
    try testing.expectEqual(@as(*Closure, cl), Closure.fromHeader(&cl.header));
    try testing.expectEqual(@as(usize, 0), cl.upvalues.len);
}

test "upvalue cell state machine: open index → closed value" {
    // A two-lane stand-in for the register stack.
    var tags: [4]u8 = @splat(0);
    var payloads: [4]u64 = @splat(0);
    const stack_val = Value.int(5);
    tags[3] = @intFromEnum(stack_val.tag);
    payloads[3] = stack_val.payload.bits;

    const uv = try Upvalue.createOpen(testing.allocator, 3, &tags[3], &payloads[3]);
    defer uv.destroy(testing.allocator);
    try testing.expect(uv.isOpen());
    try testing.expectEqual(@as(usize, 3), uv.loc.open);
    // Open: `get`/`set` reach the slot's lanes.
    try testing.expectEqual(@as(i64, 5), uv.get().asInt());
    uv.set(Value.int(6));
    try testing.expectEqual(Value.int(6).payload.bits, payloads[3]);

    uv.closeWith(Value.int(42)); // snapshot the departing slot's value
    try testing.expect(!uv.isOpen());
    try testing.expectEqual(@as(i64, 42), uv.loc.closed.asInt());
    // Closed: `get`/`set` reach `loc.closed`, and the slot is left alone.
    try testing.expectEqual(@as(i64, 42), uv.get().asInt());
    uv.set(Value.float(1.5));
    try testing.expectEqual(@as(f64, 1.5), uv.loc.closed.asFloat());
    try testing.expectEqual(Value.int(6).payload.bits, payloads[3]);

    // Reopened (the keyframe restorer), the lanes follow the slot again.
    uv.reopen(1, &tags[1], &payloads[1]);
    uv.set(Value.int(9));
    try testing.expectEqual(Value.int(9).payload.bits, payloads[1]);
    try testing.expectEqual(@as(i64, 9), uv.get().asInt());

    // A directly-closed cell owns its value from birth.
    const c = try Upvalue.createClosed(testing.allocator, Value.int(7));
    defer c.destroy(testing.allocator);
    try testing.expect(!c.isOpen());
    try testing.expectEqual(@as(i64, 7), c.loc.closed.asInt());
    try testing.expectEqual(@as(i64, 7), c.get().asInt());
}

test "closure cells live inline: upvalue(i) is upvalues[i]" {
    var proto = Proto{ .code = &.{}, .name = "p" };
    const cl = try Closure.create(testing.allocator, &proto, 3);
    defer cl.destroy(testing.allocator);
    var cells: [3]*Upvalue = undefined;
    for (&cells, 0..) |*c, k| {
        c.* = try Upvalue.createClosed(testing.allocator, Value.int(@intCast(k)));
        cl.upvalues[k] = c.*;
    }
    defer for (cells) |c| c.destroy(testing.allocator);
    try testing.expectEqual(@as(usize, 3), cl.upvalues.len);
    for (cells, 0..) |c, k| try testing.expectEqual(c, cl.upvalue(k));
}

fn dummyNative(ctx: *anyopaque, args: []const Value) anyerror!Value {
    _ = ctx;
    return Value.int(@intCast(args.len));
}

test "native holds a callable and round-trips through its header" {
    const n = try Native.create(testing.allocator, &dummyNative, "dummy");
    defer n.destroy(testing.allocator);
    try testing.expectEqual(object.ObjectType.native, n.header.type);
    try testing.expectEqualStrings("dummy", n.name);
    const args = [_]Value{ Value.nil(), Value.nil() };
    try testing.expectEqual(@as(i64, 2), (try n.func(@ptrCast(n), &args)).asInt());
}
