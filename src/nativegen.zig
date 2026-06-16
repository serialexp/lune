//! Tier-1b native codegen — the IR-lowering half (the encoder is `x64.zig`).
//!
//! This module turns a hot integer trace into real x86-64 machine code, writes it
//! to an executable page, and hands back a callable function pointer. Commit 2 (this
//! file's first slice) is just the **executable-memory** plumbing + a smoke test;
//! the trace compiler (`compile`) lands in the next commit.
//!
//! ## Target-gating
//!
//! Native codegen is **x86-64 / Linux only** — it emits raw machine code and flips a
//! page to executable, neither of which exists in the `wasm32-freestanding` build
//! that also imports `root.zig`. Every OS-specific reference (`std.posix.mmap`,
//! `std.os.linux.mprotect`) lives inside a function guarded by
//! `if (comptime !is_x64_linux) return error.UnsupportedTarget;`, so on any other
//! target those branches are comptime-pruned and never analyzed. The `x64` encoder
//! itself is target-independent (a pure byte buffer) and compiles everywhere.

const std = @import("std");
const builtin = @import("builtin");
const x64 = @import("x64.zig");
const trace = @import("trace.zig");
const value = @import("value.zig");
const table = @import("table.zig");
const arr = @import("array.zig");
const Value = value.Value;
const Trace = trace.Trace;

/// Frozen in-memory layout the lane-aware native array path (Phase B) encodes
/// against. Every constant is imported from the table/array modules via
/// `@offsetOf`, never a literal — a layout change in `table.zig`/`array.zig` is
/// reflected here at comptime, and a regression fails to compile rather than
/// silently miscompiling a load/store address. Reaching a packed slot from a
/// `*Table` is `ArrLayout.array_base + ArrLayout.<field>`.
const ArrLayout = struct {
    /// `*Table` → embedded `ArrayPart`.
    const array_base = table.Table.array_off;
    /// `ArrayPart` field offsets (from `array_base`).
    const lane = arr.ArrayPart.Layout.lane;
    const len = arr.ArrayPart.Layout.len;
    const data = arr.ArrayPart.Layout.data;
    const present = arr.ArrayPart.Layout.present;
};

comptime {
    // Sanity (evaluated at file scope, so it always runs and marks ArrLayout
    // used): the array sits past an 8-byte GcHeader, lane is the first
    // ArrayPart byte, and the pointer/len fields are usize-aligned. These are
    // the assumptions the native address math (B2+) relies on.
    std.debug.assert(ArrLayout.array_base >= @sizeOf(@import("object.zig").GcHeader));
    std.debug.assert(ArrLayout.lane == 0);
    std.debug.assert(ArrLayout.len % @alignOf(usize) == 0);
    std.debug.assert(ArrLayout.data % @alignOf(usize) == 0);
    std.debug.assert(ArrLayout.present % @alignOf(usize) == 0);
}

/// True only where we can actually emit and run native code.
pub const is_x64_linux = builtin.cpu.arch == .x86_64 and builtin.os.tag == .linux;

const page_align = std.heap.page_size_min;

pub const MapError = error{
    /// Built for a target without native codegen (e.g. wasm) — callers fall back
    /// to the tier-1a IR-interpreter.
    UnsupportedTarget,
    MmapFailed,
    MprotectFailed,
};

/// An `mmap`'d, executable page holding emitted machine code. `entry()` reinterprets
/// its base as a function pointer; `deinit()` returns the page to the kernel.
pub const ExecPage = struct {
    /// The whole mapped region (page-rounded). Owned; freed by `deinit`.
    mem: []align(page_align) u8,
    /// Bytes of actual code at the start of `mem`.
    len: usize,

    /// Reinterpret the page base as a C-ABI function pointer of type `Fn`.
    /// Caller guarantees the emitted code matches `Fn`'s signature.
    pub fn entry(self: ExecPage, comptime Fn: type) *const Fn {
        return @ptrCast(self.mem.ptr);
    }

    pub fn deinit(self: *ExecPage) void {
        if (comptime is_x64_linux) std.posix.munmap(self.mem);
        self.* = undefined;
    }
};

/// Copy `code` into a fresh page and make it executable (W^X: mapped RW, written,
/// then flipped to R+X). Returns a callable `ExecPage`. `code` must be non-empty.
pub fn mapExecutable(code: []const u8) MapError!ExecPage {
    if (comptime !is_x64_linux) return error.UnsupportedTarget;
    std.debug.assert(code.len > 0);

    const posix = std.posix;

    const page = std.heap.pageSize();
    const len = std.mem.alignForward(usize, code.len, page);

    // Map writable + readable (not yet executable).
    const mem = posix.mmap(
        null,
        len,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    ) catch return error.MmapFailed;
    errdefer posix.munmap(mem);

    @memcpy(mem[0..code.len], code);

    // Flip to read + execute. After this the page is no longer writable (W^X).
    // Raw syscall + errno (mirrors std.Thread's stack-guard mprotect).
    switch (posix.errno(posix.system.mprotect(mem.ptr, mem.len, .{ .READ = true, .EXEC = true }))) {
        .SUCCESS => {},
        else => return error.MprotectFailed,
    }

    return .{ .mem = mem, .len = code.len };
}

// ---------------------------------------------------------------------------
// The integer-trace compiler
// ---------------------------------------------------------------------------

const Reg = x64.Reg;
const object = @import("object.zig");
const TAG_INT: u8 = @intFromEnum(value.Tag.int);
const TAG_BOOL: u8 = @intFromEnum(value.Tag.boolean);
const TAG_HEAP: u8 = @intFromEnum(value.Tag.heap_ref);
/// `ObjectType.table` ordinal — the byte at `GcHeader.type` for a table.
const TABLE_TYPE: u8 = @intFromEnum(object.ObjectType.table);
/// Offset of `GcHeader.type` (the first header byte) from a `*GcHeader`.
const HEADER_TYPE_OFF: i32 = @offsetOf(object.GcHeader, "type");
/// The only narrow lane the native array path lowers in Phase B2/B3 (bool sieve).
/// Every other lane (`.value`, i8…f64) bails to tier-1a here — `proveKinds`
/// rejects an `aref`/`aload`/`guard_lane` whose `aux` is not this.
const BOOL_LANE: i32 = @intFromEnum(arr.Lane.boolean);

/// The proven kind of each SSA ref.
///   - `none`  — produces no usable value (a guard / the `loop` marker);
///               referencing it as an operand is a bail.
///   - `int` / `bool` — a boxed scalar that may be carried, flushed, or stored.
///   - `ptr`   — a raw `*GcHeader` (a `guard_table`-covered table `slot_load`).
///               Classified `invariant`, loaded once; **must never** reach
///               `exit_stores` (the deopt flush boxes as TAG_INT — C2).
///   - `aref`  — the paired `(table, index)` addressing token produced by `aref`
///               (its register holds `idx0 = index-1`). A distinct kind so it can
///               neither feed arithmetic nor be flushed to a slot.
const Kind = enum { none, int, bool, ptr, aref };

/// A compiled trace: an executable page whose entry is
/// `fn(regs: [*]Value) callconv(.c) usize` — `regs` base in rdi, the cleanly
/// committed iteration count (`completed`) returned in rax. Semantically identical
/// to `irinterp.execute(t, regs, scratch)`.
pub const CompiledTrace = struct {
    page: ExecPage,

    pub const EntryFn = fn ([*]Value) callconv(.c) usize;

    /// Run the trace over `regs` (mutated in place at each loop commit, exactly as
    /// the IR-interpreter does). Returns the committed-iteration count.
    pub fn run(self: CompiledTrace, regs: []Value) usize {
        return self.page.entry(EntryFn)(regs.ptr);
    }

    pub fn deinit(self: *CompiledTrace) void {
        self.page.deinit();
        self.* = undefined;
    }
};

/// Per-trace memoized native-codegen status (a tri-state, so "not yet attempted"
/// never aliases "known unsupported"). Lives on the cached `Trace`; lazily resolved
/// on the first native dispatch and then terminal — a `.compiled` page runs forever,
/// an `.unsupported` trace stays on tier-1a forever. Runtime-only (not serialized).
pub const NativeState = union(enum) {
    /// Native compilation has not been attempted yet.
    unattempted,
    /// The trace is outside the proven-int/bool subset (or this is an off-target
    /// build): it runs on the tier-1a IR-interpreter. Never retried.
    unsupported,
    /// Successfully lowered to an executable page.
    compiled: CompiledTrace,

    /// Free any owned executable page and reset to `unattempted`.
    pub fn deinit(self: *NativeState) void {
        switch (self.*) {
            .compiled => |*c| c.deinit(),
            .unattempted, .unsupported => {},
        }
        self.* = .unattempted;
    }
};

/// Try to compile `t` to native code. Returns `null` to **bail** — for any reason:
/// an off-target build, a value/op outside the proven-int/bool subset, malformed
/// IR, or an assembly/mapping failure. A `null` is never fatal: the caller falls
/// back to the tier-1a IR-interpreter. Success transfers ownership of an executable
/// page to the returned `CompiledTrace` (free it with `deinit`).
pub fn compile(gpa: std.mem.Allocator, t: *const Trace) ?CompiledTrace {
    if (comptime !is_x64_linux) return null;

    const n = t.instrs.len;
    // A well-formed trace is non-empty and ends in exactly one `loop`. Re-checked
    // here because `assertWellFormed` is gone in release builds (never trust the IR).
    if (n == 0 or n > 0xFFFF or t.instrs[n - 1].op != .loop) return null;

    const kinds = gpa.alloc(Kind, n) catch return null;
    defer gpa.free(kinds);
    const slot_of = gpa.alloc(i32, n) catch return null;
    defer gpa.free(slot_of);

    if (!proveKinds(gpa, t, kinds, slot_of)) return null;

    // cut-2: the register allocator + single-snapshot deopt. A `null` is a bail (the
    // trace runs on tier-1a) — e.g. a type-unstable carried slot the hoisted guard
    // can't catch.
    var alloc = analyze(gpa, t, kinds, slot_of) orelse return null;
    defer alloc.deinit(gpa);

    var asm_buf = x64.Assembler.init(gpa);
    defer asm_buf.deinit();
    lower(gpa, t, kinds, &alloc, &asm_buf) catch return null;
    asm_buf.resolve();

    const page = mapExecutable(asm_buf.code.items) catch return null;
    return .{ .page = page };
}

/// Forward type-proof over the linear SSA. Fills `kinds` (and `slot_of`, the
/// register slot of each `slot_load`) and returns `true` iff every value is a
/// proven `int`/`bool` produced by a supported op — otherwise `false` (bail).
fn proveKinds(gpa: std.mem.Allocator, t: *const Trace, kinds: []Kind, slot_of: []i32) bool {
    const n = t.instrs.len;
    @memset(kinds, .none);
    @memset(slot_of, -1);

    // Pass A: record each slot_load's register slot, and which slot_loads a
    // `guard_int` covers. A guard on a *slot_load* is the type check we hoist to a
    // single tag-check in the prologue (lowering reads the tag straight from
    // `regs[slot]`), so mark it. A guard on a *derived* value (e.g. an `add`/`mul`
    // result) is not hoisted: it is validated in Pass B against the value's
    // already-proven kind and lowered to nothing — a derived int (int-op-of-ints)
    // can never fail the guard. So we no longer bail on a non-slot_load operand.
    const guarded = gpa.alloc(bool, n) catch return false;
    defer gpa.free(guarded);
    @memset(guarded, false);
    // Parallel to `guarded`, but for `guard_table`: a slot_load it covers is the
    // table value → classified `.ptr` (invariant, loaded once).
    const table_guarded = gpa.alloc(bool, n) catch return false;
    defer gpa.free(table_guarded);
    @memset(table_guarded, false);
    // Per-aref: has a `guard_bounds` on this aref been proven before we reach a
    // `guard_present`/`aload`? [I4 / review] `present` is non-null only when
    // `len > 0`, which a passing `guard_bounds` (idx0 <u len) implies — so the
    // bitmap `bt` and the data load are memory-safe ONLY behind a dominating
    // bounds check. The recorder emits that order; this enforces it on the IR we
    // were handed (a malformed/deserialized trace must not segfault).
    const bounds_ok = gpa.alloc(bool, n) catch return false;
    defer gpa.free(bounds_ok);
    @memset(bounds_ok, false);

    for (t.instrs, 0..) |ins, i| {
        switch (ins.op) {
            .slot_load => {
                if (ins.aux < 0 or ins.aux > 0xFFFF) return false;
                slot_of[i] = ins.aux;
            },
            .guard_int => {
                const r = ins.a;
                if (r >= i) return false; // not linear SSA → malformed
                if (t.instrs[r].op == .slot_load) guarded[r] = true;
            },
            .guard_table => {
                const r = ins.a;
                if (r >= i) return false; // not linear SSA → malformed
                // A table guard only ever covers the table-bearing slot_load; the
                // native path hoists it to a prologue heap/type check.
                if (t.instrs[r].op != .slot_load) return false;
                table_guarded[r] = true;
            },
            else => {},
        }
    }

    // Pass B: assign kinds, validating operands and constants as we go.
    for (t.instrs, 0..) |ins, i| {
        switch (ins.op) {
            .slot_load => {
                if (guarded[i]) {
                    kinds[i] = .int;
                } else if (table_guarded[i]) {
                    kinds[i] = .ptr; // guard_table-covered → invariant table pointer
                } else {
                    return false; // unguarded → cannot prove a kind
                }
            },
            .konst => {
                if (ins.aux < 0 or ins.aux >= t.consts.len) return false;
                kinds[i] = switch (t.consts[@intCast(ins.aux)].tag) {
                    .int => .int,
                    .boolean => .bool,
                    else => return false, // float / nil / heap const → bail
                };
            },
            .add, .sub, .mul, .band, .bor, .bxor => {
                if (kinds[ins.a] != .int or kinds[ins.b] != .int) return false;
                kinds[i] = .int;
            },
            .neg, .bnot => {
                if (kinds[ins.a] != .int) return false;
                kinds[i] = .int;
            },
            .eq, .ne, .lt, .le => {
                if (kinds[ins.a] != .int or kinds[ins.b] != .int) return false;
                kinds[i] = .bool;
            },
            .guard_int => {
                // Passes trivially iff the operand is already proven int — a guarded
                // slot_load (set .int above) or a derived int (int-op-of-ints). Then
                // it is redundant and lowers to nothing. A guard on a .bool (e.g. a
                // compare result) or any unproven value can't be discharged → bail.
                if (kinds[ins.a] != .int) return false;
                kinds[i] = .none;
            },
            .guard_true, .guard_false => {
                const k = kinds[ins.a];
                if (k != .int and k != .bool) return false;
                kinds[i] = .none;
            },
            // --- lane-aware array read path (B2) ---------------------------------
            // guard_table / guard_lane: cover the table slot_load (proven .ptr).
            // guard_lane additionally pins the lane; the native path only lowers
            // the bool lane, so any other lane bails here.
            .guard_table => {
                if (ins.a >= i) return false;
                if (kinds[ins.a] != .ptr) return false;
                kinds[i] = .none;
            },
            .guard_lane => {
                if (ins.a >= i) return false;
                if (kinds[ins.a] != .ptr) return false;
                if (ins.aux != BOOL_LANE) return false; // non-bool lane → tier-1a
                kinds[i] = .none;
            },
            // aref pairs (table, index); its register carries idx0 = index-1. A
            // distinct `.aref` kind so it can neither feed arithmetic nor be flushed.
            .aref => {
                if (ins.a >= i or ins.b >= i) return false;
                if (kinds[ins.a] != .ptr or kinds[ins.b] != .int) return false;
                if (ins.aux != BOOL_LANE) return false;
                kinds[i] = .aref;
            },
            // guard_bounds (idx0 <u len): the bounds proof for this aref. Marks the
            // aref bounds-checked so a later guard_present/aload may touch memory.
            .guard_bounds => {
                if (ins.a >= i) return false;
                if (kinds[ins.a] != .aref) return false;
                bounds_ok[ins.a] = true;
                kinds[i] = .none;
            },
            // guard_present (bt the bitmap): only safe behind a dominating bounds
            // check on the same aref (else `present` may be null / idx0 OOB).
            .guard_present => {
                if (ins.a >= i) return false;
                if (kinds[ins.a] != .aref) return false;
                if (!bounds_ok[ins.a]) return false; // [I4] bounds must dominate
                kinds[i] = .none;
            },
            // aload decodes the bool-lane slot to a boolean (movzx of the value bit).
            // Likewise gated on a dominating bounds check (the data load is indexed
            // by idx0, which must be proven in range).
            .aload => {
                if (ins.a >= i) return false;
                if (kinds[ins.a] != .aref) return false;
                if (ins.aux != BOOL_LANE) return false;
                if (!bounds_ok[ins.a]) return false; // [I4] bounds must dominate
                kinds[i] = .bool;
            },
            .loop => {
                if (i != n - 1) return false; // loop must be terminal
                kinds[i] = .none;
            },
            // Everything else (div/idiv/mod/pow/shl/shr/not/guard_float/
            // guard_number) is deferred — bail to tier-1a.
            else => return false,
        }
    }

    // Every loop-carried writeback must reference a *boxable scalar* (int/bool) so
    // the deopt flush knows its tag. [C2] A `.ptr` (raw table pointer) or `.aref`
    // (addressing token) in `exit_stores` would be flushed as a bogus TAG_INT and
    // corrupt the slot — reject both here, not just `.none`.
    for (t.exit_stores) |st| {
        if (st.ref >= n) return false;
        if (kinds[st.ref] != .int and kinds[st.ref] != .bool) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// cut-2: register allocation + single-snapshot deopt — the analysis half
//
// `analyze` is a forward linear-scan over the linear SSA that (a) classifies each
// tier-0 slot the trace touches, (b) computes per-ref liveness, and (c) assigns
// every value a `Loc` (a CPU register or a frame spill slot). It is *pure analysis*:
// `lower` consumes its output in later commits. Landed first as a measured no-op so
// the risky logic rides under the existing differential oracle.
// ---------------------------------------------------------------------------

/// Where a value lives during the loop body.
const Loc = union(enum) {
    reg: Reg,
    spill: u32, // frame slot index; byte displacement = index * 8
};

/// How a slot participates in the loop, deciding its prologue/back-edge/EXIT handling.
const SlotClass = enum {
    /// slot_loaded AND in exit_stores: read+write loop-carried. Gets a home; flushed
    /// to regs[] on a side-exit; reassigned at the back-edge shuffle.
    carried,
    /// slot_loaded, NOT in exit_stores: read-only, loop-invariant. Loaded once into a
    /// home; never written back (untouched ⇒ coherent).
    invariant,
    /// in exit_stores, NOT slot_loaded (e.g. `flag = i<limit`). No home; committed to
    /// regs[] at the back-edge (cut-1 style); never touched at EXIT.
    write_only,
};

/// Compile-time facts about one tier-0 slot.
const SlotInfo = struct {
    slot: u16,
    class: SlotClass,
    kind: Kind, // box tag at commit/flush (int/ptr for carried/invariant; store_ref's for write_only)
    home: Loc, // valid for carried/invariant
    load_ref: i32, // the slot_load ref, or -1
    store_ref: i32, // the exit_store ref feeding it, or -1
    /// For a `.ptr` (table) invariant slot: the bool-lane ordinal its `guard_lane`
    /// pins, checked once in the prologue. `-1` for non-`.ptr` slots.
    lane: i32,
    /// win 2: the store_ref transient was allocated *into* home, so the op updates the
    /// home in place and the back-edge shuffle move for this slot self-elides. Only set
    /// for `carried` slots passing the safety predicate (see `analyzeInner`).
    coalesced: bool,
};

/// The allocator's output — the sole input `lower` needs (later commits).
const Alloc = struct {
    loc: []Loc, // [n] location of each ref's value (slot_load refs resolve to their home)
    last_use: []u32, // [n] index of the last instruction reading each ref
    slot_id_of_ref: []i32, // [n] slots[] index for a slot_load ref, else -1
    slots: []SlotInfo,
    spill_count: u32, // frame slots used (homes + transients); frame = spill_count*8
    used_callee_saved: u16, // bitmask of callee-saved GPRs used (must be push/pop'd)

    fn deinit(self: *Alloc, gpa: std.mem.Allocator) void {
        gpa.free(self.loc);
        gpa.free(self.last_use);
        gpa.free(self.slot_id_of_ref);
        gpa.free(self.slots);
        self.* = undefined;
    }
};

/// 1<<reg as a 16-bit register-set bit.
fn regBit(r: Reg) u16 {
    return @as(u16, 1) << @intFromEnum(r);
}

/// Allocatable GPRs, in preference order: caller-saved first (no prologue save), then
/// callee-saved (push/pop'd). Excludes rax/rcx (scratch), rbx (completed), rsp, rdi
/// (regs base).
const ALLOC_ORDER = [_]Reg{ .rdx, .rsi, .r8, .r9, .r10, .r11, .rbp, .r12, .r13, .r14, .r15 };
const CALLEE_SAVED_MASK: u16 = regBit(.rbp) | regBit(.r12) | regBit(.r13) | regBit(.r14) | regBit(.r15);

const AnalyzeError = std.mem.Allocator.Error || error{
    /// cut-2 cannot represent this trace (type-instability, etc.). The caller bails;
    /// the cut-1 stack-slot path (or tier-1a) handles it correctly.
    Bail,
};

/// True iff `op` produces a register-resident value that gets its own location (i.e. a
/// transient: konst / arithmetic / compare). slot_loads resolve to a slot home; guards
/// and the loop marker produce no value.
fn isTransient(op: trace.IrOp) bool {
    return switch (op) {
        .konst, .add, .sub, .mul, .band, .bor, .bxor, .neg, .bnot, .eq, .ne, .lt, .le => true,
        // aref materializes idx0 in a register; aload materializes the decoded bool.
        .aref, .aload => true,
        else => false,
    };
}

/// True iff the op's two operands may be swapped without changing the result. Used
/// both for operand coalescing (either operand's dying register may be reused) and to
/// let the ALU emitter avoid a staging move when the in-register operand is `b`.
fn isCommutative(op: trace.IrOp) bool {
    return switch (op) {
        .add, .mul, .band, .bor, .bxor, .eq, .ne => true,
        else => false, // sub, lt, le are order-sensitive
    };
}

/// The operand refs an instruction reads (matching `proveKinds`/`lower` exactly).
fn operandReads(ins: trace.IrInstr) struct { a: bool, b: bool } {
    return switch (ins.op) {
        .add, .sub, .mul, .band, .bor, .bxor, .eq, .ne, .lt, .le => .{ .a = true, .b = true },
        .neg, .bnot, .guard_int, .guard_true, .guard_false => .{ .a = true, .b = false },
        // aref reads table (a, an invariant home) + index (b). aload/guards reach the
        // table through aref.a, so they read only the aref token (a).
        .aref => .{ .a = true, .b = true },
        .aload, .guard_bounds, .guard_present, .guard_table, .guard_lane => .{ .a = true, .b = false },
        else => .{ .a = false, .b = false },
    };
}

/// Whether two `Loc`s name the same physical home (register or spill slot).
fn locEql(x: Loc, y: Loc) bool {
    return Place.eql(locToPlace(x), locToPlace(y));
}

/// Ops whose result can be computed *into* a destination home in place (win 2). A
/// compare result is Bool, never carried (type-stability bails), and konst has no
/// operand to anchor the home — so only arithmetic/bitwise + unary qualify.
fn isCoalescibleOp(op: trace.IrOp) bool {
    return switch (op) {
        .add, .sub, .mul, .band, .bor, .bxor, .neg, .bnot => true,
        else => false,
    };
}

/// Find a slot in the list or append a fresh (unclassified) entry; returns its index.
fn findOrAddSlot(slots: *std.ArrayListUnmanaged(SlotInfo), gpa: std.mem.Allocator, slot: u16) !usize {
    for (slots.items, 0..) |s, id| {
        if (s.slot == slot) return id;
    }
    try slots.append(gpa, .{
        .slot = slot,
        .class = undefined,
        .kind = .none,
        .home = undefined,
        .load_ref = -1,
        .store_ref = -1,
        .lane = -1,
        .coalesced = false,
    });
    return slots.items.len - 1;
}

/// See module header. Returns `null` to bail (cut-2 cannot compile this trace); the
/// caller falls back. Runs only on a `proveKinds`-accepted trace, so every op is in the
/// supported subset and `kinds`/`slot_of` are filled.
fn analyze(gpa: std.mem.Allocator, t: *const Trace, kinds: []const Kind, slot_of: []const i32) ?Alloc {
    return analyzeInner(gpa, t, kinds, slot_of) catch |e| switch (e) {
        error.Bail, error.OutOfMemory => null,
    };
}

fn analyzeInner(gpa: std.mem.Allocator, t: *const Trace, kinds: []const Kind, slot_of: []const i32) AnalyzeError!Alloc {
    const n = t.instrs.len;

    var slots: std.ArrayListUnmanaged(SlotInfo) = .empty;
    errdefer slots.deinit(gpa);

    const slot_id_of_ref = try gpa.alloc(i32, n);
    errdefer gpa.free(slot_id_of_ref);
    @memset(slot_id_of_ref, -1);

    // --- classification: gather slot_loads, then exit_stores ---
    for (t.instrs, 0..) |ins, i| {
        if (ins.op != .slot_load) continue;
        const slot: u16 = @intCast(slot_of[i]); // validated >= 0 in proveKinds
        const id = try findOrAddSlot(&slots, gpa, slot);
        slots.items[id].load_ref = @intCast(i);
        slot_id_of_ref[i] = @intCast(id);
    }
    for (t.exit_stores) |st| {
        const id = try findOrAddSlot(&slots, gpa, st.slot);
        slots.items[id].store_ref = st.ref;
    }
    for (slots.items) |*s| {
        const loaded = s.load_ref >= 0;
        const stored = s.store_ref >= 0;
        if (loaded and stored) {
            s.class = .carried;
            s.kind = .int; // the load is guarded int
            // [RV-3] type-stability: a carried slot stored as non-int would pass our
            // hoisted (once) guard_int forever while the oracle re-checks every
            // iteration and deopts. Reject so the trace stays on tier-1a.
            if (kinds[@intCast(s.store_ref)] != .int) return error.Bail;
            // [RV-4 / review P0] A carried slot is treated as int end-to-end: the
            // prologue tag-checks TAG_INT and the deopt flush boxes TAG_INT. If the
            // *load* proved `.ptr` (a guard_table-covered table) the table/lane
            // prologue checks would be skipped and the int payload dereferenced as a
            // `*GcHeader` → type confusion. A `.ptr` slot must be read-only
            // (`invariant`); a carried one bails to tier-1a.
            if (kinds[@intCast(s.load_ref)] != .int) return error.Bail;
        } else if (loaded) {
            s.class = .invariant;
            // int OR ptr (a guard_table-covered table slot, read-only loop-invariant).
            s.kind = kinds[@intCast(s.load_ref)];
        } else {
            s.class = .write_only;
            s.kind = kinds[@intCast(s.store_ref)];
        }
    }
    // A `.ptr` (table) invariant slot needs the bool-lane its `guard_lane` pins, so
    // the prologue can check it once. Locate the guard_lane covering the slot_load.
    for (slots.items) |*s| {
        if (s.kind != .ptr) continue;
        const lr: u16 = @intCast(s.load_ref);
        var found = false;
        for (t.instrs) |g| {
            if (g.op == .guard_lane and g.a == lr) {
                s.lane = g.aux;
                found = true;
                break;
            }
        }
        // proveKinds only set .ptr via a guard_table; a guard_lane must accompany it
        // (the recorder always emits both). Defensive: bail rather than miscompile.
        if (!found) return error.Bail;
    }

    // --- liveness: last_use, single backward pass; carried/write store_refs live to the marker ---
    const last_use = try gpa.alloc(u32, n);
    errdefer gpa.free(last_use);
    for (last_use, 0..) |*lu, i| lu.* = @intCast(i); // live at least at its own def
    {
        var i: usize = n;
        while (i > 0) {
            i -= 1;
            const ins = t.instrs[i];
            const rd = operandReads(ins);
            if (rd.a and last_use[ins.a] < i) last_use[ins.a] = @intCast(i);
            if (rd.b and last_use[ins.b] < i) last_use[ins.b] = @intCast(i);
        }
    }
    // The value feeding any exit_store must survive to the back-edge shuffle/commit.
    for (t.exit_stores) |st| {
        if (last_use[st.ref] < n - 1) last_use[st.ref] = @intCast(n - 1);
    }

    // --- allocation: pin slot homes, then linear-scan the transients ---
    const loc = try gpa.alloc(Loc, n);
    errdefer gpa.free(loc);
    for (loc) |*l| l.* = .{ .spill = 0 }; // placeholder for value-less refs (guards/loop)

    var free: u16 = comptime blk: {
        var m: u16 = 0;
        for (ALLOC_ORDER) |r| m |= regBit(r);
        break :blk m;
    };
    var spill_count: u32 = 0;
    var used_callee: u16 = 0;
    var home_reg_mask: u16 = 0;

    for (slots.items) |*s| {
        if (s.class == .write_only) continue;
        if (pickReg(&free)) |r| {
            s.home = .{ .reg = r };
            home_reg_mask |= regBit(r);
            used_callee |= regBit(r) & CALLEE_SAVED_MASK;
        } else {
            s.home = .{ .spill = spill_count };
            spill_count += 1;
        }
    }
    // Resolve slot_load refs to their slot home.
    for (t.instrs, 0..) |ins, i| {
        if (ins.op != .slot_load) continue;
        loc[i] = slots.items[@intCast(slot_id_of_ref[i])].home;
    }

    // --- home coalescing (win 2): allocate a carried slot's store_ref transient INTO
    // the slot's home, so the op updates the home in place AND the back-edge shuffle
    // self-elides. Gated by a safety predicate (cuts-2's single-snapshot model assumes
    // homes are written only at the back-edge; an in-place update breaks that unless no
    // side-exit follows it). Must run BEFORE the linear scan so it sees loc[j] fixed.
    const is_coalesced_home = try gpa.alloc(bool, n);
    defer gpa.free(is_coalesced_home);
    @memset(is_coalesced_home, false);
    {
        // The last side-exiting instruction. Mid-iteration exits are guard_true/
        // guard_false AND the array read guards guard_bounds/guard_present (guard_int/
        // guard_table/guard_lane are hoisted to the prologue, so they never side-exit
        // mid-body). An in-place home update that PRECEDES any of these would be
        // committed by the deopt flush even though the iteration aborted — so home
        // coalescing must be blocked past the last of them. Trace order is
        // straight-line, so index order == dominance: "after" == strictly greater index.
        var last_body_guard: i64 = -1;
        for (t.instrs, 0..) |ins, idx| {
            switch (ins.op) {
                .guard_true, .guard_false, .guard_bounds, .guard_present => last_body_guard = @intCast(idx),
                else => {},
            }
        }
        for (slots.items, 0..) |*s, sid| {
            if (s.class != .carried) continue;
            const j: usize = @intCast(s.store_ref);
            const def = t.instrs[j];
            if (!isCoalescibleOp(def.op)) continue;
            // (1) no side-exit follows the in-place update.
            if (@as(i64, @intCast(j)) <= last_body_guard) continue;
            // [RV] imul has no [mem],reg store form → a spilled-home mul can't go in place.
            if (def.op == .mul and s.home != .reg) continue;
            // (2) S's OLD value is fully dead by j: no slot_load(S) ref is read after j.
            // (The operand read at j itself has last_use == j ≤ j, which is fine.)
            var old_live = false;
            for (0..n) |r2| {
                if (slot_id_of_ref[r2] == @as(i32, @intCast(sid)) and last_use[r2] > j) {
                    old_live = true;
                    break;
                }
            }
            if (old_live) continue;
            // (3) home(S) holds an operand at the op: left operand is home (any op), or a
            // commutative op's right operand is home. Unary requires its sole operand.
            const a_home = operandReads(def).a and locEql(loc[def.a], s.home);
            const b_home = operandReads(def).b and locEql(loc[def.b], s.home);
            const op_ok = a_home or (b_home and isCommutative(def.op));
            if (!op_ok) continue;
            // Coalesce: pin the transient into the home, mark the slot, and extend the
            // transient's live range to the loop marker so the scan never frees the home
            // [RV: the coalesced value IS snapshot state from j onward].
            loc[j] = s.home;
            s.coalesced = true;
            is_coalesced_home[j] = true;
            if (last_use[j] < n - 1) last_use[j] = @intCast(n - 1);
        }
    }

    // Linear scan over transient defs in index order; active set ≤ pool size.
    var active: [ALLOC_ORDER.len]struct { reg: Reg, last: u32 } = undefined;
    var active_len: usize = 0;
    for (t.instrs, 0..) |ins, i| {
        if (!isTransient(ins.op)) continue;
        // expire transients whose last use precedes i
        var w: usize = 0;
        for (active[0..active_len]) |e| {
            if (e.last < i) {
                free |= regBit(e.reg);
            } else {
                active[w] = e;
                w += 1;
            }
        }
        active_len = w;

        // A win-2 transient is already pinned to its slot home — never reallocate it.
        if (is_coalesced_home[i]) continue;

        // --- operand coalescing (win 1): reuse a *dying* operand's register for the
        // result, emitting an in-place `op dst, b` instead of staging through rax.
        // The operand must (a) live in a register, (b) NOT be a slot home — reusing a
        // home would clobber a loop-carried value mid-iteration [RV: location-based,
        // not slot_id<0, so it stays correct once win-2 puts transients in homes] —
        // and (c) die exactly here (last_use == i). For commutative ops either operand
        // qualifies; otherwise only `a` (the destructive-write target).
        const rd = operandReads(ins);
        var coalesced: ?Reg = null;
        const cands = [2]struct { ref: usize, ok: bool }{
            .{ .ref = ins.a, .ok = rd.a },
            .{ .ref = ins.b, .ok = rd.b and isCommutative(ins.op) },
        };
        for (cands) |c| {
            if (!c.ok) continue;
            if (loc[c.ref] != .reg) continue;
            const r = loc[c.ref].reg;
            if (home_reg_mask & regBit(r) != 0) continue;
            if (last_use[c.ref] != i) continue;
            // Repurpose the operand's active entry for the result's live range.
            for (active[0..active_len]) |*e| {
                if (e.reg == r) {
                    e.last = last_use[i];
                    coalesced = r;
                    break;
                }
            }
            if (coalesced != null) break;
        }
        if (coalesced) |r| {
            loc[i] = .{ .reg = r };
        } else if (pickReg(&free)) |r| {
            loc[i] = .{ .reg = r };
            used_callee |= regBit(r) & CALLEE_SAVED_MASK;
            active[active_len] = .{ .reg = r, .last = last_use[i] };
            active_len += 1;
        } else {
            loc[i] = .{ .spill = spill_count };
            spill_count += 1;
        }
    }

    // --- invariant assertions (compiled out in release; the structural guardrail) ---
    if (std.debug.runtime_safety) {
        // homes are register-disjoint
        var seen: u16 = 0;
        for (slots.items) |s| {
            if (s.class == .write_only) continue;
            if (s.home == .reg) {
                const b = regBit(s.home.reg);
                std.debug.assert(seen & b == 0);
                seen |= b;
            }
        }
        // no transient register aliases a home register — except a win-2 transient,
        // which is deliberately pinned INTO its slot's home.
        for (t.instrs, 0..) |ins, i| {
            if (!isTransient(ins.op)) continue;
            if (is_coalesced_home[i]) continue;
            if (loc[i] == .reg) std.debug.assert(home_reg_mask & regBit(loc[i].reg) == 0);
        }
        // every exit_store ref has a concrete location (it always does)
        for (t.exit_stores) |st| {
            const l = loc[st.ref];
            std.debug.assert(l == .reg or l == .spill);
        }
    }

    return .{
        .loc = loc,
        .last_use = last_use,
        .slot_id_of_ref = slot_id_of_ref,
        .slots = try slots.toOwnedSlice(gpa),
        .spill_count = spill_count,
        .used_callee_saved = used_callee,
    };
}

/// Pop the first free register in `ALLOC_ORDER` preference, clearing its bit. Null if none.
fn pickReg(free: *u16) ?Reg {
    for (ALLOC_ORDER) |r| {
        const b = regBit(r);
        if (free.* & b != 0) {
            free.* &= ~b;
            return r;
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// cut-2: lowering helpers — a `Place` is where a value sits (a register or a frame
// slot at an rsp displacement). The body keeps slot homes in registers and transients
// in frame slots (commit B); commit C moves transients to registers too.
// ---------------------------------------------------------------------------

const Place = union(enum) {
    reg: Reg,
    mem: i32, // rsp-relative byte displacement

    fn eql(x: Place, y: Place) bool {
        if (std.meta.activeTag(x) != std.meta.activeTag(y)) return false;
        return switch (x) {
            .reg => x.reg == y.reg,
            .mem => x.mem == y.mem,
        };
    }
};

/// Map an allocation `Loc` to a `Place`: a register stays a register; a spill slot
/// becomes a frame displacement `[rsp + idx*8]`.
fn locToPlace(l: Loc) Place {
    return switch (l) {
        .reg => |r| .{ .reg = r },
        .spill => |idx| .{ .mem = @as(i32, @intCast(idx)) * 8 },
    };
}

/// The home of a carried/invariant slot: its assigned register or spill slot.
fn slotHomePlace(s: SlotInfo) Place {
    return locToPlace(s.home);
}

/// Where ref `r`'s value lives — its linear-scan-assigned register or frame slot.
/// A `slot_load` ref resolves to its slot home (its `loc` was set to that home).
fn placeOfRef(alloc: *const Alloc, r: usize) Place {
    return locToPlace(alloc.loc[r]);
}

fn placeToReg(a: *x64.Assembler, dst: Reg, src: Place) !void {
    switch (src) {
        .reg => |r| if (r != dst) try a.movRegReg(dst, r),
        .mem => |d| try a.movRegMem(dst, .rsp, d),
    }
}

fn regToPlace(a: *x64.Assembler, dst: Place, src: Reg) !void {
    switch (dst) {
        .reg => |r| if (r != src) try a.movRegReg(r, src),
        .mem => |d| try a.movMemReg(.rsp, d, src),
    }
}

/// Ensure a ref's value is in a CPU register usable as a memory *base*, returning
/// that register. A register home is used directly; a spilled home is loaded into
/// `scratch` (rax). Used for the invariant table pointer at each array op.
fn refBaseReg(a: *x64.Assembler, alloc: *const Alloc, ref: usize, scratch: Reg) !Reg {
    switch (placeOfRef(alloc, ref)) {
        .reg => |r| return r,
        .mem => |d| {
            try a.movRegMem(scratch, .rsp, d);
            return scratch;
        },
    }
}

/// Like `refBaseReg`, but for a slot's home `Place` (used for the prologue table
/// checks, where the slot is referenced by its home, not an SSA ref).
fn refHomeBaseReg(a: *x64.Assembler, s: SlotInfo, scratch: Reg) !Reg {
    switch (slotHomePlace(s)) {
        .reg => |r| return r,
        .mem => |d| {
            try a.movRegMem(scratch, .rsp, d);
            return scratch;
        },
    }
}

/// Emit `dst <op> src` where `dst` is a register and `src` is a Place — reg→reg ALU
/// or the load-form `op r64, [mem]` when the operand is spilled (avoids staging it
/// through scratch). Only binary arithmetic/bitwise ops reach here.
fn emitAluRegPlace(a: *x64.Assembler, op: trace.IrOp, dst: Reg, src: Place) !void {
    switch (src) {
        .reg => |r| switch (op) {
            .add => try a.addRegReg(dst, r),
            .sub => try a.subRegReg(dst, r),
            .mul => try a.imulRegReg(dst, r),
            .band => try a.andRegReg(dst, r),
            .bor => try a.orRegReg(dst, r),
            .bxor => try a.xorRegReg(dst, r),
            else => unreachable,
        },
        .mem => |d| switch (op) {
            .add => try a.addRegMem(dst, .rsp, d),
            .sub => try a.subRegMem(dst, .rsp, d),
            .mul => try a.imulRegMem(dst, .rsp, d),
            .band => try a.andRegMem(dst, .rsp, d),
            .bor => try a.orRegMem(dst, .rsp, d),
            .bxor => try a.xorRegMem(dst, .rsp, d),
            else => unreachable,
        },
    }
}

/// Lower a binary ALU op `dst = pa <op> pb` reading operands in place.
///   - register dst: keep `pa` in dst (elided when operand/home-coalesced so `pa==dst`)
///     then `op dst, pb`; a commutative op may instead keep the in-register `pb`.
///   - spilled dst: in-place store form `op [dst], pb_reg` when `pa==dst` (the win-2
///     coalesced home), else stage `a` in rax and write back. imul has no store form,
///     so a spilled in-place `mul` is never produced (analyze keeps such homes in regs).
fn emitBinAlu(a: *x64.Assembler, op: trace.IrOp, dst: Place, pa: Place, pb: Place) !void {
    switch (dst) {
        .reg => |R| {
            if (pa == .reg and pa.reg == R) {
                try emitAluRegPlace(a, op, R, pb);
            } else if (isCommutative(op) and pb == .reg and pb.reg == R) {
                try emitAluRegPlace(a, op, R, pa);
            } else {
                // R holds neither operand: materialize `a`, then `op R, b`. For
                // non-commutative ops `pb.reg == R` is impossible (a still-live operand
                // keeps its register), so the staging move never clobbers `b`.
                try placeToReg(a, R, pa);
                try emitAluRegPlace(a, op, R, pb);
            }
        },
        .mem => |D| {
            if (Place.eql(pa, dst)) {
                // In-place spilled home (win 2): `op [dst], b`. Load b to rcx if spilled.
                std.debug.assert(op != .mul); // no imul store form
                const src_reg: Reg = switch (pb) {
                    .reg => |r| r,
                    .mem => |bd| blk: {
                        try a.movRegMem(.rcx, .rsp, bd);
                        break :blk .rcx;
                    },
                };
                switch (op) {
                    .add => try a.addMemReg(.rsp, D, src_reg),
                    .sub => try a.subMemReg(.rsp, D, src_reg),
                    .band => try a.andMemReg(.rsp, D, src_reg),
                    .bor => try a.orMemReg(.rsp, D, src_reg),
                    .bxor => try a.xorMemReg(.rsp, D, src_reg),
                    else => unreachable,
                }
            } else {
                // General spilled dst: compute in rax, write back.
                try placeToReg(a, .rax, pa);
                try emitAluRegPlace(a, op, .rax, pb);
                try a.movMemReg(.rsp, D, .rax);
            }
        },
    }
}

/// Lower a comparison `dst = pa <cc> pb` reading operands in place. Needs a register
/// on the left of `cmp`; stages `a` through rax only when it is spilled. The Bool
/// result lands in `dst` via setcc+movzx.
fn emitCompare(a: *x64.Assembler, op: trace.IrOp, dst: Place, pa: Place, pb: Place) !void {
    const lhs: Reg = switch (pa) {
        .reg => |r| r,
        .mem => |d| blk: {
            try a.movRegMem(.rax, .rsp, d);
            break :blk .rax;
        },
    };
    switch (pb) {
        .reg => |r| try a.cmpRegReg(lhs, r),
        .mem => |d| try a.cmpRegMem(lhs, .rsp, d),
    }
    const cc: x64.Cond = switch (op) {
        .eq => .e,
        .ne => .ne,
        .lt => .l,
        .le => .le,
        else => unreachable,
    };
    switch (dst) {
        .reg => |R| {
            try a.setcc(cc, R);
            try a.movzxRegReg8(R, R); // zero-extend the 0/1 byte to the full register
        },
        .mem => |D| {
            try a.setcc(cc, .rax);
            try a.movzxRegReg8(.rax, .rax);
            try a.movMemReg(.rsp, D, .rax);
        },
    }
}

/// `dst <- src` between two Places. A mem→mem move routes through rax.
fn movePlace(a: *x64.Assembler, dst: Place, src: Place) !void {
    if (Place.eql(dst, src)) return;
    switch (dst) {
        .reg => |r| try placeToReg(a, r, src),
        .mem => |d| switch (src) {
            .reg => |sr| try a.movMemReg(.rsp, d, sr),
            .mem => |sd| {
                try a.movRegMem(.rax, .rsp, sd);
                try a.movMemReg(.rsp, d, .rax);
            },
        },
    }
}

const Move = struct { dst: Place, src: Place };

/// Emit a parallel move (the back-edge PHI shuffle): all `dst <- src` happen as if
/// simultaneously. Acyclic moves go first (Kahn); each remaining disjoint cycle is
/// broken with rcx (saving the cycle's start value), fully, before the next. rax is
/// the mem↔mem scratch inside `movePlace`; the two never collide.
fn emitParallelMove(a: *x64.Assembler, moves: []Move, done: []bool) !void {
    @memset(done, false);
    var left = moves.len;

    var progress = true;
    while (progress and left > 0) {
        progress = false;
        for (moves, 0..) |m, i| {
            if (done[i]) continue;
            var blocked = false;
            for (moves, 0..) |o, j| {
                if (done[j] or j == i) continue;
                if (Place.eql(o.src, m.dst)) {
                    blocked = true;
                    break;
                }
            }
            if (blocked) continue;
            try movePlace(a, m.dst, m.src);
            done[i] = true;
            left -= 1;
            progress = true;
        }
    }

    for (moves, 0..) |_, start| {
        if (done[start]) continue;
        try placeToReg(a, .rcx, moves[start].dst); // save the cycle's start value
        var cur = start;
        while (true) {
            const m = moves[cur];
            done[cur] = true;
            left -= 1;
            var nxt: ?usize = null;
            for (moves, 0..) |o, j| {
                if (done[j]) continue;
                if (Place.eql(o.dst, m.src)) {
                    nxt = j;
                    break;
                }
            }
            if (nxt) |j| {
                try movePlace(a, m.dst, m.src);
                cur = j;
            } else {
                try regToPlace(a, m.dst, .rcx); // m.src is the saved cycle start
                break;
            }
        }
    }
    std.debug.assert(left == 0);
}

/// Restore the stack/callee-saved state and return. Shared by both epilogues.
fn emitTeardown(a: *x64.Assembler, frame: i32, callee: []const Reg) !void {
    if (frame > 0) try a.addRegImm32(.rsp, frame);
    var k = callee.len;
    while (k > 0) {
        k -= 1;
        try a.pop(callee[k]);
    }
    try a.pop(.rbx);
    try a.ret();
}

/// Lower a proven trace to machine code (cut-2). ABI: rdi = regs base, rbx = committed
/// counter, rax/rcx = scratch. Loop-carried/invariant slots live in registers across
/// iterations (loaded + type-guarded once in the prologue); `regs[]` is written only on
/// a side-exit (the single snapshot) or for write-only slots at the back-edge.
fn lower(gpa: std.mem.Allocator, t: *const Trace, kinds: []const Kind, alloc: *const Alloc, a: *x64.Assembler) !void {
    // Callee-saved registers we clobber — as a home OR as a transient — must be
    // preserved across the call. `used_callee_saved` already ORs both; iterate a fixed
    // order so push/pop pair up. (Homing only the slot homes here was a latent bug: a
    // linear-scan transient landing in rbp/r12–r15 was clobbered unsaved → SEGV on
    // return once the host actually relied on that register.)
    var callee: [ALLOC_ORDER.len]Reg = undefined;
    var callee_len: usize = 0;
    for (ALLOC_ORDER) |r| {
        if ((regBit(r) & CALLEE_SAVED_MASK) != 0 and (alloc.used_callee_saved & regBit(r)) != 0) {
            callee[callee_len] = r;
            callee_len += 1;
        }
    }

    // Frame = compacted spill area (homes + transients that missed a register), padded so
    // the total below-entry delta (rbx + callee pushes + frame) stays 16-byte aligned [RV-6].
    const pushes = 1 + callee_len; // rbx + callee-saved homes
    const frame: i32 = @intCast(std.mem.alignForward(usize, pushes * 8 + alloc.spill_count * 8, 16) - pushes * 8);

    // Prologue: save rbx + callee-saved homes, completed = 0, reserve the frame.
    try a.push(.rbx);
    for (callee[0..callee_len]) |r| try a.push(r);
    try a.xorRegReg(.rbx, .rbx);
    if (frame > 0) try a.subRegImm32(.rsp, frame);

    const loop_top = try a.label();
    const deopt_exit = try a.label();
    const prologue_fail = try a.label();

    // [RV-1] Hoisted type guards (all first → no home is live if one fails), then the
    // hoisted slot loads. A guard failure here returns 0 without touching regs[].
    // An int slot checks TAG_INT; a `.ptr` (table) slot checks TAG_HEAP (its
    // table-type + lane are verified below, after the pointer is loaded).
    for (alloc.slots) |s| {
        if (s.class == .write_only) continue;
        const tag: u8 = if (s.kind == .ptr) TAG_HEAP else TAG_INT;
        try a.cmpByteMemImm(.rdi, @as(i32, s.slot) * 16, tag);
        try a.jcc(.ne, prologue_fail);
    }
    for (alloc.slots) |s| {
        if (s.class == .write_only) continue;
        const off: i32 = @as(i32, s.slot) * 16 + 8;
        switch (slotHomePlace(s)) {
            .reg => |r| try a.movRegMem(r, .rdi, off),
            .mem => |d| {
                try a.movRegMem(.rax, .rdi, off);
                try a.movMemReg(.rsp, d, .rax);
            },
        }
    }
    // [C2-prologue] For each `.ptr` table slot the pointer is now in its home; verify
    // the object is a table and its array lane matches the recorded lane — once, here,
    // since neither changes within a native run (the read path never widens). A miss
    // returns 0 (regs[] untouched). The bool-lane is the only lane proveKinds admits.
    for (alloc.slots) |s| {
        if (s.class == .write_only or s.kind != .ptr) continue;
        const preg = try refHomeBaseReg(a, s, .rax);
        try a.cmpByteMemImm(preg, HEADER_TYPE_OFF, TABLE_TYPE);
        try a.jcc(.ne, prologue_fail);
        try a.cmpByteMemImm(preg, ArrLayout.array_base + ArrLayout.lane, @intCast(s.lane));
        try a.jcc(.ne, prologue_fail);
    }

    a.bind(loop_top);

    for (t.instrs, 0..) |ins, i| {
        switch (ins.op) {
            // slot_load: hoisted to the prologue (loop-invariant). guard_int: either
            // hoisted (slot_load operand → one prologue tag-check) or a proven-int
            // derived guard that's statically redundant — both emit nothing here.
            // guard_table/guard_lane: hoisted to the prologue table checks (the lane
            // never changes within a native run) — nothing here either.
            .slot_load, .guard_int, .guard_table, .guard_lane => {},
            .konst => {
                const bits = t.consts[@intCast(ins.aux)].payload.bits;
                switch (placeOfRef(alloc, i)) {
                    .reg => |r| try a.movRegImm64(r, @bitCast(bits)),
                    .mem => |d| {
                        try a.movRegImm64(.rax, @bitCast(bits));
                        try a.movMemReg(.rsp, d, .rax);
                    },
                }
            },
            .add, .sub, .mul, .band, .bor, .bxor => {
                try emitBinAlu(a, ins.op, placeOfRef(alloc, i), placeOfRef(alloc, ins.a), placeOfRef(alloc, ins.b));
            },
            .neg, .bnot => {
                const dst = placeOfRef(alloc, i);
                const pa = placeOfRef(alloc, ins.a);
                switch (dst) {
                    .reg => |R| {
                        if (!(pa == .reg and pa.reg == R)) try placeToReg(a, R, pa);
                        if (ins.op == .neg) try a.negReg(R) else try a.notReg(R);
                    },
                    .mem => |D| {
                        if (Place.eql(pa, dst)) {
                            // In-place spilled home (win 2): neg/not via rcx round-trip
                            // (F7 has no [mem] form in this encoder).
                            try a.movRegMem(.rcx, .rsp, D);
                            if (ins.op == .neg) try a.negReg(.rcx) else try a.notReg(.rcx);
                            try a.movMemReg(.rsp, D, .rcx);
                        } else {
                            try placeToReg(a, .rax, pa);
                            if (ins.op == .neg) try a.negReg(.rax) else try a.notReg(.rax);
                            try a.movMemReg(.rsp, D, .rax);
                        }
                    },
                }
            },
            .eq, .ne, .lt, .le => {
                try emitCompare(a, ins.op, placeOfRef(alloc, i), placeOfRef(alloc, ins.a), placeOfRef(alloc, ins.b));
            },
            // --- lane-aware array read path (B2, bool lane) ----------------------
            // aref: materialize idx0 = index - 1 (the 0-based packed index) into the
            // aref token's own location. The table pointer is reached lazily by each
            // consumer through `aref.a` (the invariant table home), so aref itself
            // touches only the index.
            .aref => {
                const dst = placeOfRef(alloc, i);
                const idxp = placeOfRef(alloc, ins.b);
                switch (dst) {
                    .reg => |R| {
                        try placeToReg(a, R, idxp);
                        try a.subRegImm32(R, 1);
                    },
                    .mem => |D| {
                        try placeToReg(a, .rax, idxp);
                        try a.subRegImm32(.rax, 1);
                        try a.movMemReg(.rsp, D, .rax);
                    },
                }
            },
            // guard_bounds: idx0 <u len, else side-exit. [I3] the single idx0 from aref
            // is shared by bounds/present/aload. [I4] precedes guard_present.
            .guard_bounds => {
                const aref_ins = t.instrs[ins.a];
                const tbreg = try refBaseReg(a, alloc, aref_ins.a, .rax);
                const ireg = try refBaseReg(a, alloc, ins.a, .rcx);
                try a.cmpRegMem(ireg, tbreg, ArrLayout.array_base + ArrLayout.len);
                try a.jcc(.ae, deopt_exit); // idx0 >=u len (covers negative/zero key too)
            },
            // guard_present: the slot's presence bit must be set; a hole would read as
            // nil, which the bool kind can't hold. `bt [present], idx0` → CF=bit.
            .guard_present => {
                const aref_ins = t.instrs[ins.a];
                const tbreg = try refBaseReg(a, alloc, aref_ins.a, .rax);
                try a.movRegMem(.rax, tbreg, ArrLayout.array_base + ArrLayout.present);
                const ireg = try refBaseReg(a, alloc, ins.a, .rcx);
                try a.btMemReg(.rax, 0, ireg);
                try a.jcc(.ae, deopt_exit); // CF==0 → hole → side-exit
            },
            // aload (bool lane): value bit = `bt [data], idx0`; materialize CF as a
            // clean 0/1 boolean into the aload's location (setcc + movzx).
            .aload => {
                const aref_ins = t.instrs[ins.a];
                const tbreg = try refBaseReg(a, alloc, aref_ins.a, .rax);
                try a.movRegMem(.rax, tbreg, ArrLayout.array_base + ArrLayout.data);
                const ireg = try refBaseReg(a, alloc, ins.a, .rcx);
                try a.btMemReg(.rax, 0, ireg);
                // Materialize CF as a clean 0/1 in `al` (reg 0 — always REX-safe), then
                // movzx to a full register and home it. Going through al avoids `setcc`
                // on a high-encoding dst (sil/dil/bpl), which the encoder can't address.
                try a.setcc(.b, .rax);
                try a.movzxRegReg8(.rax, .rax);
                try regToPlace(a, placeOfRef(alloc, i), .rax);
            },
            .guard_true => switch (kinds[ins.a]) {
                .int => {}, // every int is truthy → guard always passes (no-op)
                .bool => {
                    switch (placeOfRef(alloc, ins.a)) {
                        .reg => |r| try a.cmpRegImm32(r, 0),
                        .mem => |d| try a.cmpQwordMemImm8(.rsp, d, 0),
                    }
                    try a.jcc(.e, deopt_exit); // false (0) → side-exit
                },
                .none, .ptr, .aref => unreachable, // proveKinds restricts to int/bool
            },
            .guard_false => switch (kinds[ins.a]) {
                .int => try a.jmp(deopt_exit), // an int is never falsy → always side-exit
                .bool => {
                    switch (placeOfRef(alloc, ins.a)) {
                        .reg => |r| try a.cmpRegImm32(r, 0),
                        .mem => |d| try a.cmpQwordMemImm8(.rsp, d, 0),
                    }
                    try a.jcc(.ne, deopt_exit); // true (≠0) → side-exit
                },
                .none, .ptr, .aref => unreachable, // proveKinds restricts to int/bool
            },
            .loop => {
                // [RV-2] write-only slots commit to regs[] BEFORE the shuffle, so the
                // shuffle can't clobber a write-only source that aliases a carried home.
                for (alloc.slots) |s| {
                    if (s.class != .write_only) continue;
                    const base: i32 = @as(i32, s.slot) * 16;
                    const tag: i32 = if (s.kind == .bool) TAG_BOOL else TAG_INT;
                    try placeToReg(a, .rax, placeOfRef(alloc, @intCast(s.store_ref)));
                    try a.movMemImm32(.rdi, base, tag);
                    try a.movMemReg(.rdi, base + 8, .rax);
                }
                // PHI shuffle: carried home(slot) <- store_ref location. A win-2
                // coalesced slot already updated its home in place (the move would be a
                // self-move), so it is dropped from the parallel move entirely.
                var nmoves: usize = 0;
                for (alloc.slots) |s| {
                    if (s.class == .carried and !s.coalesced) nmoves += 1;
                }
                const moves = try gpa.alloc(Move, nmoves);
                defer gpa.free(moves);
                const done = try gpa.alloc(bool, nmoves);
                defer gpa.free(done);
                var mi: usize = 0;
                for (alloc.slots) |s| {
                    if (s.class != .carried or s.coalesced) continue;
                    moves[mi] = .{ .dst = slotHomePlace(s), .src = placeOfRef(alloc, @intCast(s.store_ref)) };
                    mi += 1;
                }
                try emitParallelMove(a, moves, done);
                try a.incReg(.rbx);
                try a.jmp(loop_top);
            },
            else => unreachable, // proveKinds rejected everything else
        }
    }

    // DEOPT_EXIT: the single snapshot flush. Write each carried home back to regs[]
    // (always int-tagged) — invariant + write-only slots are already coherent. Then
    // return `completed`.
    a.bind(deopt_exit);
    for (alloc.slots) |s| {
        if (s.class != .carried) continue;
        const base: i32 = @as(i32, s.slot) * 16;
        try a.movMemImm32(.rdi, base, TAG_INT);
        switch (slotHomePlace(s)) {
            .reg => |r| try a.movMemReg(.rdi, base + 8, r),
            .mem => |d| {
                try a.movRegMem(.rax, .rsp, d);
                try a.movMemReg(.rdi, base + 8, .rax);
            },
        }
    }
    try a.movRegReg(.rax, .rbx);
    try emitTeardown(a, frame, callee[0..callee_len]);

    // PROLOGUE_FAIL: a hoisted type guard failed before any commit. Return 0 with
    // regs[] untouched (the cut-1 EXIT would have flushed half-initialized homes).
    a.bind(prologue_fail);
    try a.xorRegReg(.rax, .rax);
    try emitTeardown(a, frame, callee[0..callee_len]);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const irinterp = @import("irinterp.zig");
const I = trace.IrInstr;
const S = trace.SlotStore;

/// Compare two register files **semantically** (tag + payload bits). The 7 padding
/// bytes of a `Value` are non-semantic and left undefined by `Value.int`/etc., so a
/// raw byte compare would spuriously fail against native code that zeroes them.
fn expectRegsEqual(expected: []const Value, actual: []const Value) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, ac| {
        try testing.expectEqual(@intFromEnum(e.tag), @intFromEnum(ac.tag));
        try testing.expectEqual(e.payload.bits, ac.payload.bits);
    }
}

/// Run `t` through both the IR-interpreter (the oracle) and the native compiler on
/// identical fresh register files; assert the same `completed` and final `regs`.
fn expectMatch(t: *const Trace, regs_init: []const Value) !void {
    // Oracle: the tier-1a IR-interpreter.
    const iregs = try testing.allocator.dupe(Value, regs_init);
    defer testing.allocator.free(iregs);
    const values = try testing.allocator.alloc(Value, t.instrs.len);
    defer testing.allocator.free(values);
    const icompleted = irinterp.execute(t, iregs, values);

    // Native: must compile (caller picks compilable traces) and match bit-for-bit.
    var ct = compile(testing.allocator, t) orelse return error.NativeBailedUnexpectedly;
    defer ct.deinit();
    const nregs = try testing.allocator.dupe(Value, regs_init);
    defer testing.allocator.free(nregs);
    const ncompleted = ct.run(nregs);

    try testing.expectEqual(icompleted, ncompleted);
    try expectRegsEqual(iregs, nregs);
}

/// Assert `compile` bails (returns null) for an unsupported trace.
fn expectBail(t: *const Trace) !void {
    if (compile(testing.allocator, t)) |ct| {
        var c = ct;
        c.deinit();
        return error.TestExpectedBail;
    }
}

test "nativegen: clean integer counting loop matches the interpreter" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    // while (i < limit) { acc += i; i += 1; }  — regs: r0=i, r1=limit, r2=acc.
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: i
        .{ .op = .slot_load, .aux = 1 }, // 1: limit
        .{ .op = .guard_int, .a = 0 }, // 2
        .{ .op = .guard_int, .a = 1 }, // 3
        .{ .op = .lt, .a = 0, .b = 1 }, // 4: i < limit
        .{ .op = .guard_true, .a = 4 }, // 5
        .{ .op = .slot_load, .aux = 2 }, // 6: acc
        .{ .op = .guard_int, .a = 6 }, // 7
        .{ .op = .add, .a = 6, .b = 0 }, // 8: acc + i
        .{ .op = .konst, .aux = 0 }, // 9: 1
        .{ .op = .add, .a = 0, .b = 9 }, // 10: i + 1
        .{ .op = .loop }, // 11
    };
    var consts = [_]Value{Value.int(1)};
    var exits = [_]S{ .{ .slot = 2, .ref = 8 }, .{ .slot = 0, .ref = 10 } };
    var es = [_]u16{};
    const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .exit_stores = &exits };

    // i=1..5: commits 4 iterations (1+2+3+4=10), exits when i==5 (5<5 false).
    try expectMatch(&t, &.{ Value.int(1), Value.int(5), Value.int(0) });
    // A tighter limit: 0 commits.
    try expectMatch(&t, &.{ Value.int(7), Value.int(3), Value.int(100) });
}

test "nativegen: a guard_int failure side-exits with completed==0" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: i
        .{ .op = .slot_load, .aux = 1 }, // 1: limit (will be a float at runtime)
        .{ .op = .guard_int, .a = 0 }, // 2
        .{ .op = .guard_int, .a = 1 }, // 3 — fails: limit is float
        .{ .op = .lt, .a = 0, .b = 1 }, // 4
        .{ .op = .guard_true, .a = 4 }, // 5
        .{ .op = .konst, .aux = 0 }, // 6: 1
        .{ .op = .add, .a = 0, .b = 6 }, // 7: i+1
        .{ .op = .loop }, // 8
    };
    var consts = [_]Value{Value.int(1)};
    var exits = [_]S{.{ .slot = 0, .ref = 7 }};
    var es = [_]u16{};
    const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .exit_stores = &exits };
    // limit is a float → guard_int #3 fails on the very first iteration.
    try expectMatch(&t, &.{ Value.int(0), Value.float(5.0) });
}

test "nativegen: a loop-carried boolean is boxed with the boolean tag" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    // r1 := (i < 10) each iteration; r0 := i+1. Exits when i==10.
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: i
        .{ .op = .guard_int, .a = 0 }, // 1
        .{ .op = .konst, .aux = 0 }, // 2: 10
        .{ .op = .lt, .a = 0, .b = 2 }, // 3: i < 10  (BOOL, loop-carried)
        .{ .op = .konst, .aux = 1 }, // 4: 1
        .{ .op = .add, .a = 0, .b = 4 }, // 5: i + 1
        .{ .op = .guard_true, .a = 3 }, // 6
        .{ .op = .loop }, // 7
    };
    var consts = [_]Value{ Value.int(10), Value.int(1) };
    var exits = [_]S{ .{ .slot = 0, .ref = 5 }, .{ .slot = 1, .ref = 3 } };
    var es = [_]u16{};
    const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .exit_stores = &exits };
    // r1 must end as boolean(true) (tag=1), NOT int(1) (tag=2) — the oracle catches it.
    try expectMatch(&t, &.{ Value.int(0), Value.nil() });
}

test "nativegen: guard_true on an integer always passes (int 0 is truthy)" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: i (starts at 0)
        .{ .op = .guard_int, .a = 0 }, // 1
        .{ .op = .guard_true, .a = 0 }, // 2: truthy-guard on the int itself
        .{ .op = .konst, .aux = 0 }, // 3: 3
        .{ .op = .lt, .a = 0, .b = 3 }, // 4: i < 3
        .{ .op = .guard_true, .a = 4 }, // 5
        .{ .op = .konst, .aux = 1 }, // 6: 1
        .{ .op = .add, .a = 0, .b = 6 }, // 7: i+1
        .{ .op = .loop }, // 8
    };
    var consts = [_]Value{ Value.int(3), Value.int(1) };
    var exits = [_]S{.{ .slot = 0, .ref = 7 }};
    var es = [_]u16{};
    const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .exit_stores = &exits };
    // i=0,1,2 commit (guard_true on int 0 must NOT exit); exits at i=3. completed==3.
    try expectMatch(&t, &.{Value.int(0)});
}

test "nativegen: guard_false on an integer side-exits immediately" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0
        .{ .op = .guard_int, .a = 0 }, // 1
        .{ .op = .guard_false, .a = 0 }, // 2: int is truthy → guard_false fails
        .{ .op = .loop }, // 3
    };
    var consts = [_]Value{};
    var exits = [_]S{.{ .slot = 0, .ref = 0 }};
    var es = [_]u16{};
    const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .exit_stores = &exits };
    try expectMatch(&t, &.{Value.int(5)}); // completed==0, regs unchanged
}

test "nativegen: derived guard_int on int arithmetic compiles and matches (#1)" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    // acc = acc + (i+7)*(i+7); i += 1; while i < limit — the `CSE-able body` shape.
    // The recorder guards the *derived* (i+7) and (i+7)*(i+7); both are statically
    // int (int-op-of-ints), so the guards must lower to nothing and the trace must
    // compile. regs: r0=i, r1=limit, r2=acc.
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: i
        .{ .op = .slot_load, .aux = 1 }, // 1: limit
        .{ .op = .guard_int, .a = 0 }, // 2: slot_load guard (hoisted)
        .{ .op = .guard_int, .a = 1 }, // 3: slot_load guard (hoisted)
        .{ .op = .lt, .a = 0, .b = 1 }, // 4: i < limit
        .{ .op = .guard_true, .a = 4 }, // 5
        .{ .op = .slot_load, .aux = 2 }, // 6: acc
        .{ .op = .guard_int, .a = 6 }, // 7: slot_load guard (hoisted)
        .{ .op = .konst, .aux = 0 }, // 8: 7
        .{ .op = .add, .a = 0, .b = 8 }, // 9: i + 7   (derived)
        .{ .op = .guard_int, .a = 9 }, // 10: DERIVED guard on the add → no-op
        .{ .op = .mul, .a = 9, .b = 9 }, // 11: (i+7)*(i+7)   (derived)
        .{ .op = .guard_int, .a = 11 }, // 12: DERIVED guard on the mul → no-op
        .{ .op = .add, .a = 6, .b = 11 }, // 13: acc + (i+7)^2
        .{ .op = .konst, .aux = 1 }, // 14: 1
        .{ .op = .add, .a = 0, .b = 14 }, // 15: i + 1
        .{ .op = .loop }, // 16
    };
    var consts = [_]Value{ Value.int(7), Value.int(1) };
    var exits = [_]S{ .{ .slot = 2, .ref = 13 }, .{ .slot = 0, .ref = 15 } };
    var es = [_]u16{};
    const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .exit_stores = &exits };
    // i=1,2,3 commit: acc = 8^2+9^2+10^2 = 245; exits at i==4.
    try expectMatch(&t, &.{ Value.int(1), Value.int(4), Value.int(0) });
    // 0 commits (i already == limit): regs unchanged.
    try expectMatch(&t, &.{ Value.int(10), Value.int(10), Value.int(99) });
}

test "nativegen: bails on unsupported traces" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    var es = [_]u16{};

    // (a) a float constant → not provably int.
    {
        var instrs = [_]I{
            .{ .op = .slot_load, .aux = 0 },
            .{ .op = .guard_int, .a = 0 },
            .{ .op = .konst, .aux = 0 },
            .{ .op = .add, .a = 0, .b = 2 },
            .{ .op = .loop },
        };
        var consts = [_]Value{Value.float(1.5)};
        var exits = [_]S{.{ .slot = 0, .ref = 3 }};
        const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .exit_stores = &exits };
        try expectBail(&t);
    }
    // (b) a slot_load with no covering guard_int.
    {
        var instrs = [_]I{
            .{ .op = .slot_load, .aux = 0 },
            .{ .op = .konst, .aux = 0 },
            .{ .op = .add, .a = 0, .b = 1 },
            .{ .op = .loop },
        };
        var consts = [_]Value{Value.int(1)};
        var exits = [_]S{.{ .slot = 0, .ref = 2 }};
        const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .exit_stores = &exits };
        try expectBail(&t);
    }
    // (c) guard_number (a float passes it → can't prove int).
    {
        var instrs = [_]I{
            .{ .op = .slot_load, .aux = 0 },
            .{ .op = .guard_number, .a = 0 },
            .{ .op = .loop },
        };
        var consts = [_]Value{};
        var exits = [_]S{};
        const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .exit_stores = &exits };
        try expectBail(&t);
    }
    // (d) a deferred op (div).
    {
        var instrs = [_]I{
            .{ .op = .slot_load, .aux = 0 },
            .{ .op = .guard_int, .a = 0 },
            .{ .op = .konst, .aux = 0 },
            .{ .op = .div, .a = 0, .b = 2 },
            .{ .op = .loop },
        };
        var consts = [_]Value{Value.int(2)};
        var exits = [_]S{.{ .slot = 0, .ref = 0 }};
        const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .exit_stores = &exits };
        try expectBail(&t);
    }
    // (e) [#1] a guard_int on a *bool* (a compare result) is not discharge-able →
    // must still bail (only proven-int operands are accepted by the relaxed guard).
    {
        var instrs = [_]I{
            .{ .op = .slot_load, .aux = 0 }, // 0: i
            .{ .op = .guard_int, .a = 0 }, // 1
            .{ .op = .konst, .aux = 0 }, // 2: 5
            .{ .op = .lt, .a = 0, .b = 2 }, // 3: i < 5  → bool
            .{ .op = .guard_int, .a = 3 }, // 4: guard_int on a bool → bail
            .{ .op = .loop }, // 5
        };
        var consts = [_]Value{Value.int(5)};
        var exits = [_]S{.{ .slot = 0, .ref = 0 }};
        const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .exit_stores = &exits };
        try expectBail(&t);
    }
}

/// Helper: run proveKinds + analyze and return whether the carried slot `slot`
/// coalesced its store into its home (win 2). Caller frees nothing; this owns it.
fn slotCoalesced(t: *const Trace, slot: u16) !bool {
    const kinds = try testing.allocator.alloc(Kind, t.instrs.len);
    defer testing.allocator.free(kinds);
    const slot_of = try testing.allocator.alloc(i32, t.instrs.len);
    defer testing.allocator.free(slot_of);
    if (!proveKinds(testing.allocator, t, kinds, slot_of)) return error.ProveFailed;
    var al = analyze(testing.allocator, t, kinds, slot_of) orelse return error.AnalyzeBailed;
    defer al.deinit(testing.allocator);
    for (al.slots) |s| {
        if (s.slot == slot) return s.coalesced;
    }
    return error.NoSuchSlot;
}

test "nativegen win2: accumulator coalesces when no guard follows the update" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    // guard_true is at index 5 (before the acc update at 8) → cond 1 holds → coalesce.
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: i
        .{ .op = .slot_load, .aux = 1 }, // 1: limit
        .{ .op = .guard_int, .a = 0 }, // 2
        .{ .op = .guard_int, .a = 1 }, // 3
        .{ .op = .lt, .a = 0, .b = 1 }, // 4
        .{ .op = .guard_true, .a = 4 }, // 5  ← last body guard
        .{ .op = .slot_load, .aux = 2 }, // 6: acc
        .{ .op = .guard_int, .a = 6 }, // 7
        .{ .op = .add, .a = 6, .b = 0 }, // 8: acc + i   (after the guard → coalesces)
        .{ .op = .konst, .aux = 0 }, // 9: 1
        .{ .op = .add, .a = 0, .b = 9 }, // 10: i + 1    (after the guard → coalesces)
        .{ .op = .loop }, // 11
    };
    var consts = [_]Value{Value.int(1)};
    var exits = [_]S{ .{ .slot = 2, .ref = 8 }, .{ .slot = 0, .ref = 10 } };
    var es = [_]u16{};
    const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .exit_stores = &exits };
    try testing.expect(try slotCoalesced(&t, 2)); // acc, left-operand home
    try testing.expect(try slotCoalesced(&t, 0)); // i,  left-operand home
    try expectMatch(&t, &.{ Value.int(1), Value.int(5), Value.int(0) });
    try expectMatch(&t, &.{ Value.int(7), Value.int(3), Value.int(100) });
}

test "nativegen win2: a guard AFTER the accumulation blocks coalescing (cond 1)" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    // acc update at 8, then a guard_true at 10 reading a body bool: cond 1 fails for acc.
    // On that guard's failure the snapshot must restore the loop-header acc, NOT acc+i.
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: i
        .{ .op = .slot_load, .aux = 1 }, // 1: limit
        .{ .op = .guard_int, .a = 0 }, // 2
        .{ .op = .guard_int, .a = 1 }, // 3
        .{ .op = .slot_load, .aux = 2 }, // 4: acc
        .{ .op = .guard_int, .a = 4 }, // 5
        .{ .op = .konst, .aux = 0 }, // 6: 1
        .{ .op = .add, .a = 0, .b = 6 }, // 7: i + 1
        .{ .op = .add, .a = 4, .b = 0 }, // 8: acc + i    (precedes a later guard)
        .{ .op = .lt, .a = 7, .b = 1 }, // 9: (i+1) < limit
        .{ .op = .guard_true, .a = 9 }, // 10 ← guard AFTER the acc update
        .{ .op = .loop }, // 11
    };
    var consts = [_]Value{Value.int(1)};
    var exits = [_]S{ .{ .slot = 2, .ref = 8 }, .{ .slot = 0, .ref = 7 } };
    var es = [_]u16{};
    const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .exit_stores = &exits };
    try testing.expect(!(try slotCoalesced(&t, 2))); // acc must NOT coalesce
    try testing.expect(!(try slotCoalesced(&t, 0))); // i  must NOT coalesce
    // i=1,limit=5 → exits at the guard when i+1==5<5 false; acc/i restored to header.
    try expectMatch(&t, &.{ Value.int(1), Value.int(5), Value.int(0) });
    try expectMatch(&t, &.{ Value.int(1), Value.int(2), Value.int(50) }); // exits 2nd iter
}

test "nativegen win2: old value still live blocks coalescing (cond 2)" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    // tmp = acc (slot3 write-only); acc = acc + i. acc's old slot_load is read by the
    // tmp store, which is live to the back-edge → cond 2 fails → no coalesce.
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: i
        .{ .op = .slot_load, .aux = 1 }, // 1: limit
        .{ .op = .guard_int, .a = 0 }, // 2
        .{ .op = .guard_int, .a = 1 }, // 3
        .{ .op = .lt, .a = 0, .b = 1 }, // 4
        .{ .op = .guard_true, .a = 4 }, // 5
        .{ .op = .slot_load, .aux = 2 }, // 6: acc
        .{ .op = .guard_int, .a = 6 }, // 7
        .{ .op = .add, .a = 6, .b = 0 }, // 8: acc + i
        .{ .op = .konst, .aux = 0 }, // 9: 1
        .{ .op = .add, .a = 0, .b = 9 }, // 10: i + 1
        .{ .op = .loop }, // 11
    };
    var consts = [_]Value{Value.int(1)};
    // slot3 := acc_old (%6), still reading the old acc at the back-edge.
    var exits = [_]S{ .{ .slot = 2, .ref = 8 }, .{ .slot = 0, .ref = 10 }, .{ .slot = 3, .ref = 6 } };
    var es = [_]u16{};
    const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .exit_stores = &exits };
    try testing.expect(!(try slotCoalesced(&t, 2))); // acc's old value is still live
    try expectMatch(&t, &.{ Value.int(1), Value.int(4), Value.int(0), Value.int(-1) });
}

test "nativegen win2: commutative-right home coalesces; non-commutative-right does not" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    // acc = i + acc  (commutative, home is the RIGHT operand) → coalesces.
    var add_instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: i
        .{ .op = .slot_load, .aux = 1 }, // 1: limit
        .{ .op = .guard_int, .a = 0 }, // 2
        .{ .op = .guard_int, .a = 1 }, // 3
        .{ .op = .lt, .a = 0, .b = 1 }, // 4
        .{ .op = .guard_true, .a = 4 }, // 5
        .{ .op = .slot_load, .aux = 2 }, // 6: acc
        .{ .op = .guard_int, .a = 6 }, // 7
        .{ .op = .add, .a = 0, .b = 6 }, // 8: i + acc   (home = b, commutative)
        .{ .op = .konst, .aux = 0 }, // 9
        .{ .op = .add, .a = 0, .b = 9 }, // 10: i + 1
        .{ .op = .loop }, // 11
    };
    var consts = [_]Value{Value.int(1)};
    var add_exits = [_]S{ .{ .slot = 2, .ref = 8 }, .{ .slot = 0, .ref = 10 } };
    var es = [_]u16{};
    const ta = Trace{ .anchor = undefined, .instrs = &add_instrs, .consts = &consts, .entry_slots = &es, .exit_stores = &add_exits };
    try testing.expect(try slotCoalesced(&ta, 2));
    try expectMatch(&ta, &.{ Value.int(1), Value.int(5), Value.int(0) });

    // acc = k - acc  (non-commutative, home is the RIGHT operand) → must NOT coalesce
    // (sub home, k would compute acc-k, not k-acc).
    var sub_instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: i
        .{ .op = .slot_load, .aux = 1 }, // 1: limit
        .{ .op = .guard_int, .a = 0 }, // 2
        .{ .op = .guard_int, .a = 1 }, // 3
        .{ .op = .lt, .a = 0, .b = 1 }, // 4
        .{ .op = .guard_true, .a = 4 }, // 5
        .{ .op = .slot_load, .aux = 2 }, // 6: acc
        .{ .op = .guard_int, .a = 6 }, // 7
        .{ .op = .konst, .aux = 1 }, // 8: 100
        .{ .op = .sub, .a = 8, .b = 6 }, // 9: 100 - acc   (home = b, NON-commutative)
        .{ .op = .konst, .aux = 0 }, // 10: 1
        .{ .op = .add, .a = 0, .b = 10 }, // 11: i + 1
        .{ .op = .loop }, // 12
    };
    var consts2 = [_]Value{ Value.int(1), Value.int(100) };
    var sub_exits = [_]S{ .{ .slot = 2, .ref = 9 }, .{ .slot = 0, .ref = 11 } };
    const ts = Trace{ .anchor = undefined, .instrs = &sub_instrs, .consts = &consts2, .entry_slots = &es, .exit_stores = &sub_exits };
    try testing.expect(!(try slotCoalesced(&ts, 2)));
    try expectMatch(&ts, &.{ Value.int(1), Value.int(4), Value.int(0) });
}

test "nativegen win2: unary into a carried slot whose operand is NOT its home" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    // x = neg y, stored to slot x.  home(x) holds the OLD x, not y, so `neg home(x)`
    // would compute -x_old, not -y.  cond 3 (operand must be home(S)) blocks it.
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: i
        .{ .op = .slot_load, .aux = 1 }, // 1: limit
        .{ .op = .guard_int, .a = 0 }, // 2
        .{ .op = .guard_int, .a = 1 }, // 3
        .{ .op = .lt, .a = 0, .b = 1 }, // 4
        .{ .op = .guard_true, .a = 4 }, // 5
        .{ .op = .slot_load, .aux = 2 }, // 6: x (carried, but unused as operand)
        .{ .op = .guard_int, .a = 6 }, // 7
        .{ .op = .slot_load, .aux = 3 }, // 8: y
        .{ .op = .guard_int, .a = 8 }, // 9
        .{ .op = .neg, .a = 8 }, // 10: -y  (stored into x; operand is y, not x)
        .{ .op = .konst, .aux = 0 }, // 11: 1
        .{ .op = .add, .a = 0, .b = 11 }, // 12: i + 1
        .{ .op = .loop }, // 13
    };
    var consts = [_]Value{Value.int(1)};
    var exits = [_]S{ .{ .slot = 2, .ref = 10 }, .{ .slot = 0, .ref = 12 } };
    var es = [_]u16{};
    const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .exit_stores = &exits };
    try testing.expect(!(try slotCoalesced(&t, 2))); // x = -y must NOT coalesce into home(x)
    try expectMatch(&t, &.{ Value.int(0), Value.int(3), Value.int(0), Value.int(7) });
}

test "nativegen win2: a coalesced result consumed by a later op is not scavenged" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    // acc = acc + 1 (coalesces into home(acc)); u = acc_new band 7 (write-only slot).
    // win 1 must NOT reuse home(acc) for u (it is snapshot state), and the loop must
    // carry acc_new.  The guard is early so both are post-guard.
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: i
        .{ .op = .slot_load, .aux = 1 }, // 1: limit
        .{ .op = .guard_int, .a = 0 }, // 2
        .{ .op = .guard_int, .a = 1 }, // 3
        .{ .op = .lt, .a = 0, .b = 1 }, // 4
        .{ .op = .guard_true, .a = 4 }, // 5
        .{ .op = .slot_load, .aux = 2 }, // 6: acc
        .{ .op = .guard_int, .a = 6 }, // 7
        .{ .op = .konst, .aux = 0 }, // 8: 1
        .{ .op = .add, .a = 6, .b = 8 }, // 9: acc + 1  (coalesces into home(acc))
        .{ .op = .konst, .aux = 1 }, // 10: 7
        .{ .op = .band, .a = 9, .b = 10 }, // 11: acc_new band 7  (reads the coalesced value)
        .{ .op = .add, .a = 0, .b = 8 }, // 12: i + 1
        .{ .op = .loop }, // 13
    };
    var consts = [_]Value{ Value.int(1), Value.int(7) };
    // slot3 := acc_new band 7 (write-only); acc := acc+1; i := i+1.
    var exits = [_]S{ .{ .slot = 2, .ref = 9 }, .{ .slot = 3, .ref = 11 }, .{ .slot = 0, .ref = 12 } };
    var es = [_]u16{};
    const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .exit_stores = &exits };
    try testing.expect(try slotCoalesced(&t, 2)); // acc coalesces
    try expectMatch(&t, &.{ Value.int(0), Value.int(5), Value.int(0), Value.int(0) });
}

test "nativegen win2: chained accumulators both coalesce (b reads new a)" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    // a = a + 1; b = b + a_new.  Both coalesce into their homes; b's in-place add reads
    // home(a) as a pure source (already updated to a_new this iteration).
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: i
        .{ .op = .slot_load, .aux = 1 }, // 1: limit
        .{ .op = .guard_int, .a = 0 }, // 2
        .{ .op = .guard_int, .a = 1 }, // 3
        .{ .op = .lt, .a = 0, .b = 1 }, // 4
        .{ .op = .guard_true, .a = 4 }, // 5
        .{ .op = .slot_load, .aux = 2 }, // 6: a
        .{ .op = .guard_int, .a = 6 }, // 7
        .{ .op = .slot_load, .aux = 3 }, // 8: b
        .{ .op = .guard_int, .a = 8 }, // 9
        .{ .op = .konst, .aux = 0 }, // 10: 1
        .{ .op = .add, .a = 6, .b = 10 }, // 11: a + 1   (→ home(a))
        .{ .op = .add, .a = 8, .b = 11 }, // 12: b + a_new (→ home(b), reads home(a))
        .{ .op = .add, .a = 0, .b = 10 }, // 13: i + 1
        .{ .op = .loop }, // 14
    };
    var consts = [_]Value{Value.int(1)};
    var exits = [_]S{ .{ .slot = 2, .ref = 11 }, .{ .slot = 3, .ref = 12 }, .{ .slot = 0, .ref = 13 } };
    var es = [_]u16{};
    const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .exit_stores = &exits };
    try testing.expect(try slotCoalesced(&t, 2)); // a
    try testing.expect(try slotCoalesced(&t, 3)); // b
    try expectMatch(&t, &.{ Value.int(0), Value.int(4), Value.int(10), Value.int(100) });
}

test "nativegen: a swap loop exercises a register home cycle" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    // for i=0..limit { a, b = b, a }  — slot0=a, slot1=b, slot2=i, slot3=limit.
    // a's writeback is b's loaded value and vice-versa ⇒ home(a)<-home(b), home(b)<-home(a):
    // a 2-cycle the parallel-move must break with the scratch.
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 2 }, // 0: i
        .{ .op = .guard_int, .a = 0 }, // 1
        .{ .op = .slot_load, .aux = 3 }, // 2: limit
        .{ .op = .guard_int, .a = 2 }, // 3
        .{ .op = .lt, .a = 0, .b = 2 }, // 4: i < limit
        .{ .op = .guard_true, .a = 4 }, // 5
        .{ .op = .slot_load, .aux = 0 }, // 6: a
        .{ .op = .guard_int, .a = 6 }, // 7
        .{ .op = .slot_load, .aux = 1 }, // 8: b
        .{ .op = .guard_int, .a = 8 }, // 9
        .{ .op = .konst, .aux = 0 }, // 10: 1
        .{ .op = .add, .a = 0, .b = 10 }, // 11: i + 1
        .{ .op = .loop }, // 12
    };
    var consts = [_]Value{Value.int(1)};
    // a<-b(ref8), b<-a(ref6), i<-i+1(ref11)
    var exits = [_]S{ .{ .slot = 0, .ref = 8 }, .{ .slot = 1, .ref = 6 }, .{ .slot = 2, .ref = 11 } };
    var es = [_]u16{};
    const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .exit_stores = &exits };
    // a=10, b=20, i=0, limit=3: three swaps ⇒ a=20, b=10. The oracle is the judge.
    try expectMatch(&t, &.{ Value.int(10), Value.int(20), Value.int(0), Value.int(3) });
    // limit=0: zero iterations, no swap.
    try expectMatch(&t, &.{ Value.int(10), Value.int(20), Value.int(0), Value.int(0) });
}

test "nativegen: operand-chain reuses one register across a left-folded sum" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    // acc = ((((acc + i) + k1) + k2) + k3); i += 1.  Each intermediate dies at the next
    // add (last_use == def+1), so operand coalescing folds the whole chain onto one
    // register (win 1). The oracle judges; this just exercises the coalescing path.
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: i
        .{ .op = .guard_int, .a = 0 }, // 1
        .{ .op = .slot_load, .aux = 1 }, // 2: limit
        .{ .op = .guard_int, .a = 2 }, // 3
        .{ .op = .lt, .a = 0, .b = 2 }, // 4
        .{ .op = .guard_true, .a = 4 }, // 5
        .{ .op = .slot_load, .aux = 2 }, // 6: acc
        .{ .op = .guard_int, .a = 6 }, // 7
        .{ .op = .add, .a = 6, .b = 0 }, // 8: acc + i        (transient t8)
        .{ .op = .konst, .aux = 0 }, // 9: 10
        .{ .op = .add, .a = 8, .b = 9 }, // 10: t8 + 10        (reuses t8's reg)
        .{ .op = .konst, .aux = 1 }, // 11: 100
        .{ .op = .add, .a = 10, .b = 11 }, // 12: t10 + 100    (reuses again)
        .{ .op = .konst, .aux = 2 }, // 13: 1
        .{ .op = .add, .a = 0, .b = 13 }, // 14: i + 1
        .{ .op = .loop }, // 15
    };
    var consts = [_]Value{ Value.int(10), Value.int(100), Value.int(1) };
    var exits = [_]S{ .{ .slot = 2, .ref = 12 }, .{ .slot = 0, .ref = 14 } };
    var es = [_]u16{};
    const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .exit_stores = &exits };
    try expectMatch(&t, &.{ Value.int(0), Value.int(4), Value.int(0) });
    try expectMatch(&t, &.{ Value.int(2), Value.int(2), Value.int(7) }); // zero iters
}

test "nativegen: more carried+invariant slots than registers forces spilled homes" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    // acc = acc + i + (x0..x9), with 10 invariant slots → 13 homes > 11 GPRs ⇒ spills.
    var ins: std.ArrayListUnmanaged(I) = .empty;
    defer ins.deinit(gpa);
    var exits: std.ArrayListUnmanaged(S) = .empty;
    defer exits.deinit(gpa);

    const r_i: u16 = @intCast(ins.items.len);
    try ins.append(gpa, .{ .op = .slot_load, .aux = 0 });
    try ins.append(gpa, .{ .op = .guard_int, .a = r_i });
    const r_lim: u16 = @intCast(ins.items.len);
    try ins.append(gpa, .{ .op = .slot_load, .aux = 1 });
    try ins.append(gpa, .{ .op = .guard_int, .a = r_lim });
    const r_lt: u16 = @intCast(ins.items.len);
    try ins.append(gpa, .{ .op = .lt, .a = r_i, .b = r_lim });
    try ins.append(gpa, .{ .op = .guard_true, .a = r_lt });
    const r_acc: u16 = @intCast(ins.items.len);
    try ins.append(gpa, .{ .op = .slot_load, .aux = 2 });
    try ins.append(gpa, .{ .op = .guard_int, .a = r_acc });

    var xrefs: [10]u16 = undefined;
    var k: usize = 0;
    while (k < 10) : (k += 1) {
        const r: u16 = @intCast(ins.items.len);
        try ins.append(gpa, .{ .op = .slot_load, .aux = @intCast(3 + k) });
        try ins.append(gpa, .{ .op = .guard_int, .a = r });
        xrefs[k] = r;
    }
    var sum: u16 = r_acc;
    for (xrefs) |xr| {
        const r: u16 = @intCast(ins.items.len);
        try ins.append(gpa, .{ .op = .add, .a = sum, .b = xr });
        sum = r;
    }
    {
        const r: u16 = @intCast(ins.items.len);
        try ins.append(gpa, .{ .op = .add, .a = sum, .b = r_i });
        sum = r;
    }
    const r_one: u16 = @intCast(ins.items.len);
    try ins.append(gpa, .{ .op = .konst, .aux = 0 });
    const r_inc: u16 = @intCast(ins.items.len);
    try ins.append(gpa, .{ .op = .add, .a = r_i, .b = r_one });
    try ins.append(gpa, .{ .op = .loop });

    try exits.append(gpa, .{ .slot = 2, .ref = sum }); // acc
    try exits.append(gpa, .{ .slot = 0, .ref = r_inc }); // i

    var consts = [_]Value{Value.int(1)};
    var es = [_]u16{};
    const t = Trace{ .anchor = undefined, .instrs = ins.items, .consts = &consts, .entry_slots = &es, .exit_stores = exits.items };

    var regs: [13]Value = undefined;
    regs[0] = Value.int(0); // i
    regs[1] = Value.int(4); // limit
    regs[2] = Value.int(0); // acc
    var j: usize = 0;
    while (j < 10) : (j += 1) regs[3 + j] = Value.int(@intCast(j + 1)); // x0..x9 = 1..10
    try expectMatch(&t, &regs);
}

test "nativegen: analyze classifies slots and pins disjoint homes" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    // Same clean counting loop: r0=i (carried), r1=limit (invariant), r2=acc (carried).
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: i
        .{ .op = .slot_load, .aux = 1 }, // 1: limit
        .{ .op = .guard_int, .a = 0 }, // 2
        .{ .op = .guard_int, .a = 1 }, // 3
        .{ .op = .lt, .a = 0, .b = 1 }, // 4: i < limit
        .{ .op = .guard_true, .a = 4 }, // 5
        .{ .op = .slot_load, .aux = 2 }, // 6: acc
        .{ .op = .guard_int, .a = 6 }, // 7
        .{ .op = .add, .a = 6, .b = 0 }, // 8: acc + i
        .{ .op = .konst, .aux = 0 }, // 9: 1
        .{ .op = .add, .a = 0, .b = 9 }, // 10: i + 1
        .{ .op = .loop }, // 11
    };
    var consts = [_]Value{Value.int(1)};
    var exits = [_]S{ .{ .slot = 2, .ref = 8 }, .{ .slot = 0, .ref = 10 } };
    var es = [_]u16{};
    const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .exit_stores = &exits };

    const kinds = try testing.allocator.alloc(Kind, instrs.len);
    defer testing.allocator.free(kinds);
    const slot_of = try testing.allocator.alloc(i32, instrs.len);
    defer testing.allocator.free(slot_of);
    try testing.expect(proveKinds(testing.allocator, &t, kinds, slot_of));

    var al = analyze(testing.allocator, &t, kinds, slot_of) orelse return error.AnalyzeBailed;
    defer al.deinit(testing.allocator);

    // Three distinct slots, classified.
    try testing.expectEqual(@as(usize, 3), al.slots.len);
    for (al.slots) |s| {
        switch (s.slot) {
            0 => try testing.expectEqual(SlotClass.carried, s.class), // i: read+write
            1 => try testing.expectEqual(SlotClass.invariant, s.class), // limit: read-only
            2 => try testing.expectEqual(SlotClass.carried, s.class), // acc: read+write
            else => return error.UnexpectedSlot,
        }
        try testing.expectEqual(Kind.int, s.kind);
    }
    // Carried/invariant homes are register-disjoint (small trace ⇒ all in regs).
    var seen: u16 = 0;
    for (al.slots) |s| {
        try testing.expect(s.home == .reg);
        try testing.expect(seen & regBit(s.home.reg) == 0);
        seen |= regBit(s.home.reg);
    }
    // slot_load refs resolve to their slot home (no own register).
    try testing.expectEqual(al.slots[0].home, al.loc[0]); // ref 0 ↔ slot 0
    // Each exit_store's producer is live through to the loop marker (the back-edge).
    try testing.expectEqual(@as(u32, instrs.len - 1), al.last_use[8]); // acc+i
    try testing.expectEqual(@as(u32, instrs.len - 1), al.last_use[10]); // i+1
}

test "nativegen: analyze rejects a type-unstable carried slot" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    // slot 0 is loaded as int (guarded) but stored as a bool (a comparison result) —
    // the oracle would deopt next iteration; cut-2 must refuse to compile it.
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: i (int)
        .{ .op = .guard_int, .a = 0 }, // 1
        .{ .op = .konst, .aux = 0 }, // 2: 3
        .{ .op = .lt, .a = 0, .b = 2 }, // 3: i < 3 (BOOL)
        .{ .op = .loop }, // 4
    };
    var consts = [_]Value{Value.int(3)};
    var exits = [_]S{.{ .slot = 0, .ref = 3 }}; // slot 0 stored as the bool
    var es = [_]u16{};
    const t = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .exit_stores = &exits };

    const kinds = try testing.allocator.alloc(Kind, instrs.len);
    defer testing.allocator.free(kinds);
    const slot_of = try testing.allocator.alloc(i32, instrs.len);
    defer testing.allocator.free(slot_of);
    try testing.expect(proveKinds(testing.allocator, &t, kinds, slot_of));

    try testing.expect(analyze(testing.allocator, &t, kinds, slot_of) == null);
}

test "exec memory: assemble, map, and call a native fn(i64)->i64" {
    if (comptime !is_x64_linux) return error.SkipZigTest;

    // f(x) = 2*x + 1, SysV: arg in rdi, return in rax.
    //   mov rax, rdi ; add rax, rdi ; inc rax ; ret
    var a = x64.Assembler.init(testing.allocator);
    defer a.deinit();
    try a.movRegReg(.rax, .rdi);
    try a.addRegReg(.rax, .rdi);
    try a.incReg(.rax);
    try a.ret();
    a.resolve();

    var page = try mapExecutable(a.code.items);
    defer page.deinit();

    const f = page.entry(fn (i64) callconv(.c) i64);
    try testing.expectEqual(@as(i64, 1), f(0));
    try testing.expectEqual(@as(i64, 21), f(10));
    try testing.expectEqual(@as(i64, -1), f(-1));
}

test "exec memory: a loop with a backward jump runs natively" {
    if (comptime !is_x64_linux) return error.SkipZigTest;

    // f(n) = sum(1..n) the dumb way:  rax=0; rcx=n; L: (n<=0?exit) rax+=rcx; rcx-=1; jnz-ish
    // Keep it simple & branch-exercising:  rax=0 ; while (rdi != 0) { rax += rdi; rdi -= 1; }
    //   xor-free version using cmp/jcc:
    //   mov rax, 0
    //   L: cmp rdi, 0 ; je END ; add rax, rdi ; sub rdi, 1 ; jmp L
    //   END: ret
    var a = x64.Assembler.init(testing.allocator);
    defer a.deinit();
    const loop = try a.label();
    const end = try a.label();
    try a.movRegImm64(.rax, 0);
    a.bind(loop);
    try a.cmpRegImm32(.rdi, 0);
    try a.jcc(.e, end);
    try a.addRegReg(.rax, .rdi);
    try a.subRegImm32(.rdi, 1);
    try a.jmp(loop);
    a.bind(end);
    try a.ret();
    a.resolve();

    var page = try mapExecutable(a.code.items);
    defer page.deinit();

    const f = page.entry(fn (i64) callconv(.c) i64);
    try testing.expectEqual(@as(i64, 0), f(0));
    try testing.expectEqual(@as(i64, 15), f(5)); // 5+4+3+2+1
    try testing.expectEqual(@as(i64, 55), f(10));
}

// ---------------------------------------------------------------------------
// B2c: lane-aware native array READ path — differential tests (bool lane)
// ---------------------------------------------------------------------------

test "nativegen: bool-lane t[k] read scan matches the interpreter" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    const t = try table.Table.create(gpa);
    defer t.destroy(gpa);

    // nsieve's sieve shape: p[2..K] = true → a narrow boolean lane (key 1 a hole).
    const K: i64 = 64;
    var i: i64 = 2;
    while (i <= K) : (i += 1) try t.set(gpa, Value.int(i), Value.boolean(true));
    try testing.expectEqual(arr.Lane.boolean, t.array.lane);

    const lane: i32 = @intFromEnum(arr.Lane.boolean);
    var consts = [_]Value{Value.int(1)};
    // r0=table, r1=index, r2=last load. Each iteration loads t[index] (bool lane),
    // advances the index, and side-exits on a bounds/present miss.
    var full = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: table
        .{ .op = .guard_table, .a = 0 }, // 1
        .{ .op = .guard_lane, .a = 0, .aux = lane }, // 2
        .{ .op = .slot_load, .aux = 1 }, // 3: index
        .{ .op = .guard_int, .a = 3 }, // 4
        .{ .op = .aref, .a = 0, .b = 3, .aux = lane }, // 5
        .{ .op = .guard_bounds, .a = 5 }, // 6
        .{ .op = .guard_present, .a = 5 }, // 7
        .{ .op = .aload, .a = 5, .aux = lane }, // 8: v = t[index]
        .{ .op = .konst, .aux = 0 }, // 9: 1
        .{ .op = .add, .a = 3, .b = 9 }, // 10: index + 1
        .{ .op = .loop }, // 11
    };
    var exits = [_]S{ .{ .slot = 1, .ref = 10 }, .{ .slot = 2, .ref = 8 } };
    var es = [_]u16{};
    const tr = Trace{ .anchor = undefined, .instrs = &full, .consts = &consts, .entry_slots = &es, .exit_stores = &exits };

    // Start at 2 (first present): scans the whole dense run, bounds-exits past K.
    try expectMatch(&tr, &.{ Value.heap(&t.header), Value.int(2), Value.nil() });
    // Start at 1: key 1 is a hole → guard_present side-exits on iteration 0.
    try expectMatch(&tr, &.{ Value.heap(&t.header), Value.int(1), Value.nil() });
    // Start past the run: guard_bounds side-exits immediately.
    try expectMatch(&tr, &.{ Value.heap(&t.header), Value.int(K + 5), Value.nil() });
    // Start mid-run: a shorter clean prefix, then bounds-exit.
    try expectMatch(&tr, &.{ Value.heap(&t.header), Value.int(40), Value.nil() });
}

test "nativegen: guard_table failure side-exits natively with completed==0" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    const t = try table.Table.create(gpa);
    defer t.destroy(gpa);
    var i: i64 = 2;
    while (i <= 8) : (i += 1) try t.set(gpa, Value.int(i), Value.boolean(true));

    const lane: i32 = @intFromEnum(arr.Lane.boolean);
    var full = [_]I{
        .{ .op = .slot_load, .aux = 0 },
        .{ .op = .guard_table, .a = 0 },
        .{ .op = .guard_lane, .a = 0, .aux = lane },
        .{ .op = .slot_load, .aux = 1 },
        .{ .op = .guard_int, .a = 3 },
        .{ .op = .aref, .a = 0, .b = 3, .aux = lane },
        .{ .op = .guard_bounds, .a = 5 },
        .{ .op = .guard_present, .a = 5 },
        .{ .op = .aload, .a = 5, .aux = lane },
        .{ .op = .konst, .aux = 0 },
        .{ .op = .add, .a = 3, .b = 9 },
        .{ .op = .loop },
    };
    var consts = [_]Value{Value.int(1)};
    var exits = [_]S{ .{ .slot = 1, .ref = 10 }, .{ .slot = 2, .ref = 8 } };
    var es = [_]u16{};
    const tr = Trace{ .anchor = undefined, .instrs = &full, .consts = &consts, .entry_slots = &es, .exit_stores = &exits };

    // r0 is an int, not a table → the prologue guard_table check fails (completed==0,
    // regs untouched). The oracle agrees.
    try expectMatch(&tr, &.{ Value.int(99), Value.int(2), Value.nil() });
}

test "nativegen: a non-bool array lane bails to tier-1a" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    // An i16-lane scan (aux != bool ordinal) must be rejected by proveKinds so the
    // trace stays on the IR-interpreter (B2c lowers the bool lane only).
    const lane: i32 = @intFromEnum(arr.Lane.i16);
    var full = [_]I{
        .{ .op = .slot_load, .aux = 0 },
        .{ .op = .guard_table, .a = 0 },
        .{ .op = .guard_lane, .a = 0, .aux = lane },
        .{ .op = .slot_load, .aux = 1 },
        .{ .op = .guard_int, .a = 3 },
        .{ .op = .aref, .a = 0, .b = 3, .aux = lane },
        .{ .op = .guard_bounds, .a = 5 },
        .{ .op = .guard_present, .a = 5 },
        .{ .op = .aload, .a = 5, .aux = lane },
        .{ .op = .konst, .aux = 0 },
        .{ .op = .add, .a = 3, .b = 9 },
        .{ .op = .loop },
    };
    var consts = [_]Value{Value.int(1)};
    var exits = [_]S{ .{ .slot = 1, .ref = 10 }, .{ .slot = 2, .ref = 8 } };
    var es = [_]u16{};
    const tr = Trace{ .anchor = undefined, .instrs = &full, .consts = &consts, .entry_slots = &es, .exit_stores = &exits };
    try expectBail(&tr);
}

test "nativegen: a carried .ptr (table) slot bails (no int/ptr type confusion)" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    // slot 0 is loaded as a table (guard_table → .ptr) AND written back as an int
    // → it would be classified `carried` and treated as int end-to-end, skipping the
    // table/lane prologue checks and dereferencing an int as a *GcHeader. Must bail.
    const lane: i32 = @intFromEnum(arr.Lane.boolean);
    var full = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: table
        .{ .op = .guard_table, .a = 0 }, // 1
        .{ .op = .guard_lane, .a = 0, .aux = lane }, // 2
        .{ .op = .slot_load, .aux = 1 }, // 3: index
        .{ .op = .guard_int, .a = 3 }, // 4
        .{ .op = .aref, .a = 0, .b = 3, .aux = lane }, // 5
        .{ .op = .guard_bounds, .a = 5 }, // 6
        .{ .op = .guard_present, .a = 5 }, // 7
        .{ .op = .aload, .a = 5, .aux = lane }, // 8
        .{ .op = .konst, .aux = 0 }, // 9: 1 (an int)
        .{ .op = .add, .a = 3, .b = 9 }, // 10: index+1
        .{ .op = .loop }, // 11
    };
    var consts = [_]Value{Value.int(1)};
    // slot 0 (the table) carried as an int store → the type-confusion trigger.
    var exits = [_]S{ .{ .slot = 0, .ref = 9 }, .{ .slot = 1, .ref = 10 } };
    var es = [_]u16{};
    const tr = Trace{ .anchor = undefined, .instrs = &full, .consts = &consts, .entry_slots = &es, .exit_stores = &exits };
    try expectBail(&tr);
}

test "nativegen: guard_present/aload without a dominating guard_bounds bails" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    // A malformed trace where guard_present precedes guard_bounds. `present` may be
    // null and idx0 may be OOB → the bitmap `bt`/data load would be unsafe. compile
    // must reject it (never trust the handed-in IR).
    const lane: i32 = @intFromEnum(arr.Lane.boolean);
    var full = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: table
        .{ .op = .guard_table, .a = 0 }, // 1
        .{ .op = .guard_lane, .a = 0, .aux = lane }, // 2
        .{ .op = .slot_load, .aux = 1 }, // 3: index
        .{ .op = .guard_int, .a = 3 }, // 4
        .{ .op = .aref, .a = 0, .b = 3, .aux = lane }, // 5
        .{ .op = .guard_present, .a = 5 }, // 6: BEFORE bounds — unsafe
        .{ .op = .guard_bounds, .a = 5 }, // 7
        .{ .op = .aload, .a = 5, .aux = lane }, // 8
        .{ .op = .konst, .aux = 0 }, // 9
        .{ .op = .add, .a = 3, .b = 9 }, // 10
        .{ .op = .loop }, // 11
    };
    var consts = [_]Value{Value.int(1)};
    var exits = [_]S{ .{ .slot = 1, .ref = 10 }, .{ .slot = 2, .ref = 8 } };
    var es = [_]u16{};
    const tr = Trace{ .anchor = undefined, .instrs = &full, .consts = &consts, .entry_slots = &es, .exit_stores = &exits };
    try expectBail(&tr);
}
