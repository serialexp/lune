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
//! the VM register stack, and reads/writes go through the VM (which owns the
//! stack). When the frame returns the cell is *closed*: the current value is
//! copied into the cell's own `loc.closed` and the index is dropped, so the
//! captured variable outlives the frame (the classic Lua open/closed upvalue
//! model). The interpreter owns the open/close timing; this module only provides
//! the cell.
//!
//! An open cell holds an **index**, not a `*Value` into the stack: a raw interior
//! pointer cannot survive the register stack splitting into parallel tag/payload
//! arrays (docs/design/09-soa-register-file.md). The slot index was already
//! tracked by `interp.OpenUpvalue`, so the pointer was redundant. Because an open
//! cell's value lives in the VM stack, value access is **Vm-mediated**
//! (`Vm.upvalGet`/`Vm.upvalSet`) rather than a method here.
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
const GcHeader = object.GcHeader;
const Value = value.Value;
const Proto = bytecode.Proto;

/// A captured-variable cell. See the module docs for the open/closed model.
pub const Upvalue = struct {
    header: GcHeader,
    /// Where the captured value lives — see `Loc`.
    loc: Loc,

    /// Open ⇒ the value is in the VM register stack at slot `open` (the VM owns the
    /// read/write). Closed ⇒ the value was copied out of the departed slot and is
    /// owned here. No `*Value` into the stack — that representation cannot survive
    /// the SoA storage split (module docs / doc 09).
    pub const Loc = union(enum) {
        open: usize,
        closed: Value,
    };

    /// Allocate an *open* upvalue over live stack slot `index`. Raw allocation
    /// only — GC-linking is the heap's job (`gc.zig`).
    pub fn createOpen(gpa: std.mem.Allocator, index: usize) std.mem.Allocator.Error!*Upvalue {
        const self = try gpa.create(Upvalue);
        self.* = .{ .header = GcHeader.init(.upvalue), .loc = .{ .open = index } };
        return self;
    }

    /// Allocate a *closed* upvalue owning `v`. Used by the keyframe restorer to
    /// build a non-dangling shell before the value/index is wired.
    pub fn createClosed(gpa: std.mem.Allocator, v: Value) std.mem.Allocator.Error!*Upvalue {
        const self = try gpa.create(Upvalue);
        self.* = .{ .header = GcHeader.init(.upvalue), .loc = .{ .closed = v } };
        return self;
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
    /// capture nothing). Owned by this closure; freed in `destroy`.
    upvalues: []*Upvalue = &.{},

    /// Allocate a closure for `proto` with room for `n_upvalues` cells (the
    /// caller fills `upvalues[i]`). Raw allocation only; the heap GC-links it.
    pub fn create(
        gpa: std.mem.Allocator,
        proto: *const Proto,
        n_upvalues: usize,
    ) std.mem.Allocator.Error!*Closure {
        const ups: []*Upvalue = if (n_upvalues == 0)
            &.{}
        else
            try gpa.alloc(*Upvalue, n_upvalues);
        errdefer if (n_upvalues != 0) gpa.free(ups);

        const self = try gpa.create(Closure);
        self.* = .{ .header = GcHeader.init(.function), .proto = proto, .upvalues = ups };
        return self;
    }

    pub fn fromHeader(h: *GcHeader) *Closure {
        // `@alignCast`: no-op on native, required wasm32 alignment assertion (see
        // `String.fromHeader`). The object is allocated at `@alignOf(Closure)`.
        return @alignCast(@fieldParentPtr("header", h));
    }

    pub fn destroy(self: *Closure, gpa: std.mem.Allocator) void {
        if (self.upvalues.len != 0) gpa.free(self.upvalues);
        gpa.destroy(self);
    }
};

/// A native (host/builtin) function. Type-erased on purpose (see module docs):
/// the context is the running VM passed as `*anyopaque`, and the error is
/// `anyerror` — a superset of the interpreter's error set, so a native's errors
/// coerce back through the boundary.
pub const NativeFn = *const fn (ctx: *anyopaque, args: []const Value) anyerror!Value;

/// A **multi-result** native. Writes up to `out.len` results into `out` (in
/// order) and returns the count actually produced (`<= out.len`); the VM nil-pads
/// `out[count..]`. The VM only takes this path when the caller wants ≥2 results —
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
    /// `getenv(name)` — an environment-variable read. `clock`-style (the call
    /// site is the boundary): its result is logged per call. The result is a
    /// **heap string** (or nil if unset), so the effect log carries inline string
    /// bytes for this kind (see `effectser.EffectResult`).
    getenv = 2,
    /// `argc()` — the command-line argument count. `clock`-style; int result.
    argc = 3,
    /// `argv(i)` — the i-th command-line argument (heap string, or nil if the
    /// index is out of range). `clock`-style; carries inline string bytes.
    argv = 4,
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

    pub fn create(
        gpa: std.mem.Allocator,
        func: NativeFn,
        name: []const u8,
    ) std.mem.Allocator.Error!*Native {
        const self = try gpa.create(Native);
        self.* = .{ .header = GcHeader.init(.native), .func = func, .name = name };
        return self;
    }

    pub fn fromHeader(h: *GcHeader) *Native {
        // `@alignCast`: no-op on native, required wasm32 alignment assertion (see
        // `String.fromHeader`). The object is allocated at `@alignOf(Native)`.
        return @alignCast(@fieldParentPtr("header", h));
    }

    pub fn destroy(self: *Native, gpa: std.mem.Allocator) void {
        gpa.destroy(self);
    }
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
    // The cell itself only tracks *where* its value lives — open carries a slot
    // index, closed owns the `Value`. Reading/writing an open cell against a live
    // stack is the VM's job (`Vm.upvalGet`/`upvalSet`), exercised e2e elsewhere.
    const uv = try Upvalue.createOpen(testing.allocator, 3);
    defer uv.destroy(testing.allocator);

    try testing.expect(uv.isOpen());
    try testing.expectEqual(@as(usize, 3), uv.loc.open);

    uv.closeWith(Value.int(42)); // snapshot the departing slot's value
    try testing.expect(!uv.isOpen());
    try testing.expectEqual(@as(i64, 42), uv.loc.closed.asInt());

    // A directly-closed cell owns its value from birth.
    const c = try Upvalue.createClosed(testing.allocator, Value.int(7));
    defer c.destroy(testing.allocator);
    try testing.expect(!c.isOpen());
    try testing.expectEqual(@as(i64, 7), c.loc.closed.asInt());
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
