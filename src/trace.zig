//! Trace recorder + trace IR — the heart of the JIT (Phase 5).
//!
//! A tracing JIT works by watching tier-0 execute, noticing when a loop runs
//! *hot*, and **recording** one iteration of that loop into a linear,
//! single-assignment IR specialised to the types it actually observed. Later
//! tiers (Phase 6: IR-interpreter; Phase 8: native codegen) *execute* that IR;
//! this module only **records** it. Recording is deliberately *transparent* —
//! tier-0 still performs every operation, so a program's observable behaviour is
//! identical whether the recorder is on or off. That invariant is the recorder's
//! decisive correctness test (`interp.zig`, the `expectProgram` matrix).
//!
//! Two pieces live here:
//!   * the **trace IR** — `IrOp`/`IrInstr`/`Trace`, plus a disassembler. This is
//!     the cache-sensitive representation the architecture reserves for the JIT
//!     (docs/design/00-architecture.md §Value representation), kept separate from
//!     the tier-0 bytecode (`bytecode.zig`).
//!   * the **recorder** — `TraceState` (hotness counters, the trace cache, and
//!     the in-progress `Recorder`) and its state machine (`onBackEdge`).
//!
//! Policy is set by docs/design/01-trace-lifecycle.md. Phase 5a (this increment)
//! lands hotness detection, recording with type guards, and the abort policy;
//! executing traces, deopt/side-exit restore, blacklist backoff, side traces, and
//! cache invalidation are later phases (named there, not built here).

const std = @import("std");
const bytecode = @import("bytecode.zig");
const value = @import("value.zig");
const io = @import("io.zig");
const Value = value.Value;
const Proto = bytecode.Proto;
const Instr = bytecode.Instr;
const OpCode = bytecode.OpCode;

// ---------------------------------------------------------------------------
// Trace IR
// ---------------------------------------------------------------------------

/// An SSA value reference: an index into a trace's `instrs` array. Every IR
/// instruction defines exactly one value, named by its position.
pub const Ref = u16;

/// Index into the (future) per-guard snapshot table. A placeholder in Phase 5a —
/// the field exists from day one so the deopt machinery (Phase 6) is a body to
/// fill in, not a schema change. See docs/design/01-trace-lifecycle.md.
pub const SnapIdx = u32;

/// The type the recorder *observed* for a value, and therefore the type a guard
/// pins / the result type the recorder inferred. Drives guard insertion now and
/// type-narrowing in the Phase 6 optimizer.
pub const ObsType = enum(u8) { unknown, int, float, boolean, nil, heap };

/// Trace IR opcode. Mirrors the arithmetic/compare subset of the tier-0 ISA
/// (`bytecode.OpCode`) plus the constructs unique to a linear trace: value
/// *inputs* (`slot_load`/`konst`), *guards* (the runtime checks that keep the
/// straight-line trace valid), and the `loop` back-edge marker.
pub const IrOp = enum(u8) {
    // ---- inputs ----
    /// `aux` = tier-0 register read at trace entry (a loop-variant input).
    slot_load,
    /// `aux` = index into the trace's `consts` pool.
    konst,

    // ---- arithmetic / bitwise (R = a op b) ----
    add,
    sub,
    mul,
    div,
    idiv,
    mod,
    pow,
    band,
    bor,
    bxor,
    shl,
    shr,

    // ---- unary (R = op a) ----
    neg,
    not,
    bnot,

    // ---- comparisons (R = a cmp b → boolean). gt/ge normalise to lt/le with
    //      swapped operands, exactly as tier-0 does. ----
    eq,
    ne,
    lt,
    le,

    // ---- guards (check `a`; on failure the future executor side-exits to
    //      tier-0 via the snapshot). ----
    guard_int,
    guard_float,
    guard_number,
    guard_true,
    guard_false,

    // ---- close ----
    /// Loop back-edge: the end of the straight-line trace. Carries no operands;
    /// the loop-carried register writes are in the trace's `exit_stores`.
    loop,
};

/// One IR instruction. `a`/`b` are operand `Ref`s (or unused); `aux` carries a
/// slot index (`slot_load`) or const-pool index (`konst`); `ty` is the inferred
/// result / guarded type; `snap` is the deopt-snapshot index for guards.
pub const IrInstr = struct {
    op: IrOp,
    a: Ref = 0,
    b: Ref = 0,
    aux: i32 = 0,
    ty: ObsType = .unknown,
    snap: SnapIdx = 0,
};

/// A loop-carried writeback: at the back-edge, tier-0 register `slot` holds the
/// value produced by IR `ref`. The set of these is the trace's exit snapshot —
/// what a future executor copies back into the register file each iteration.
pub const SlotStore = struct { slot: u16, ref: Ref };

/// Identifies a trace anchor: a loop header at byte-`pc` within a `Proto`. Loop
/// headers are the only root-trace anchors in Phase 5a (hot side exits seed side
/// traces later).
pub const AnchorKey = struct { proto: *const Proto, pc: u32 };

/// A completed, cached trace: the recorded IR plus the entry/exit snapshots that
/// connect it back to tier-0 register slots. Immutable once committed (Phase 5a
/// never invalidates a cached trace — see the lifecycle doc).
pub const Trace = struct {
    anchor: AnchorKey,
    /// The straight-line IR, terminated by a `loop` instruction.
    instrs: []IrInstr,
    /// Constants referenced by `konst` instructions (may include heap values, so
    /// the collector roots these — see `Vm.collect`).
    consts: []Value,
    /// Tier-0 registers read as inputs, in `slot_load` order (the entry snapshot).
    entry_slots: []u16,
    /// Loop-carried register writebacks at the back-edge (the exit snapshot).
    exit_stores: []SlotStore,

    /// Free a heap-allocated trace and its arrays.
    pub fn destroy(self: *Trace, gpa: std.mem.Allocator) void {
        gpa.free(self.instrs);
        gpa.free(self.consts);
        gpa.free(self.entry_slots);
        gpa.free(self.exit_stores);
        gpa.destroy(self);
    }
};

// ---------------------------------------------------------------------------
// Recorder + trace state
// ---------------------------------------------------------------------------

/// Why a recording was abandoned. Aborting discards the partial trace and leaves
/// tier-0 entirely untouched; the anchor may be retried later (penalty/blacklist
/// backoff is a later increment — see the lifecycle doc). `recordInstr` and the
/// state machine fill these in (Increment B).
pub const AbortReason = enum {
    /// An opcode the recorder does not yet model (tables, globals, concat, …).
    nyi_opcode,
    /// A `call`/`ret`/`halt` — cross-frame tracing is deferred.
    cross_frame,
    /// A host (`native`) call — always a trace barrier (`02-determinism.md`).
    host_barrier,
    /// The trace exceeded `maxrecord` instructions.
    too_long,
    /// An operand had a type the recorder cannot guard/model here.
    bad_type,
};

/// Tunables for the recorder. Defaults track LuaJIT's where sensible; all are
/// overridable (tests use tiny thresholds, the CLI flips `enabled`).
pub const TraceConfig = struct {
    /// Master switch. Off by default: with this false the VM behaves exactly as
    /// it did before Phase 5 (no counting, no recording). The CLI `--trace` /
    /// `--dump-traces` flags and tests flip it on.
    enabled: bool = false,
    /// Back-edge count at which a loop header becomes a trace anchor.
    hotloop: u32 = 56,
    /// Maximum IR instructions in one trace before aborting (`too_long`).
    maxrecord: u32 = 2000,
};

/// All recorder state owned by a `Vm`: the hotness counters, the cache of
/// committed traces, and the single in-progress `Recorder`.
pub const TraceState = struct {
    gpa: std.mem.Allocator,
    config: TraceConfig = .{},
    /// Back-edge counters keyed by loop-header anchor.
    counters: std.AutoHashMapUnmanaged(AnchorKey, u32) = .empty,
    /// Committed traces. A linear scan is fine — the cache is small in Phase 5a
    /// and never invalidated.
    cache: std.ArrayListUnmanaged(*Trace) = .empty,
    /// The in-progress recording (at most one at a time in Phase 5a).
    rec: Recorder = .{},

    pub fn init(gpa: std.mem.Allocator) TraceState {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *TraceState) void {
        self.counters.deinit(self.gpa);
        for (self.cache.items) |t| t.destroy(self.gpa);
        self.cache.deinit(self.gpa);
        self.rec.deinit(self.gpa);
    }

    /// Is a trace already cached for this anchor? (Prevents re-arming.)
    pub fn hasTrace(self: *const TraceState, anchor: AnchorKey) bool {
        for (self.cache.items) |t| {
            if (t.anchor.proto == anchor.proto and t.anchor.pc == anchor.pc) return true;
        }
        return false;
    }

    /// True while a recording is in flight (the interpreter's recording hook
    /// gates on this).
    pub fn isRecording(self: *const TraceState) bool {
        return self.rec.active;
    }

    /// Called by the interpreter whenever a back-edge fires (a backward/self
    /// jump). Increment A: count back-edges per anchor — that count *is* the
    /// hotness signal. Arming the recorder on the threshold, and closing/aborting
    /// an in-flight recording, land in Increment B.
    pub fn onBackEdge(self: *TraceState, proto: *const Proto, target_pc: u32) void {
        const key = AnchorKey{ .proto = proto, .pc = target_pc };
        const gop = self.counters.getOrPut(self.gpa, key) catch return;
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* +|= 1;
    }

    /// Back-edge count recorded for an anchor (0 if never seen). A loop is "hot"
    /// once this reaches `config.hotloop`.
    pub fn backEdgeCount(self: *const TraceState, anchor: AnchorKey) u32 {
        return self.counters.get(anchor) orelse 0;
    }
};

/// The in-progress recording buffer. Increment A defines its storage + cleanup
/// so `TraceState` owns it cleanly; the emission logic (`recordInstr`, `refOf`,
/// the per-opcode translation) lands in Increment B. While `active` is false the
/// interpreter never calls into it.
pub const Recorder = struct {
    active: bool = false,
    anchor: AnchorKey = .{ .proto = undefined, .pc = 0 },
    abort_reason: ?AbortReason = null,
    instrs: std.ArrayListUnmanaged(IrInstr) = .empty,
    consts: std.ArrayListUnmanaged(Value) = .empty,
    entry_slots: std.ArrayListUnmanaged(u16) = .empty,
    /// Current SSA ref held by each tier-0 register; `null` = not yet defined in
    /// this trace (the next read emits a `slot_load`). Sized to the recording
    /// frame's `num_registers`.
    reg_map: []?Ref = &.{},

    pub fn deinit(self: *Recorder, gpa: std.mem.Allocator) void {
        self.instrs.deinit(gpa);
        self.consts.deinit(gpa);
        self.entry_slots.deinit(gpa);
        if (self.reg_map.len != 0) gpa.free(self.reg_map);
    }
};

// ---------------------------------------------------------------------------
// Disassembly — same spirit as `bytecode.writeProto`. Invaluable for `--dump-
// traces` and for asserting trace shape in tests.
// ---------------------------------------------------------------------------

/// Write one IR instruction in a fixed columnar form (no trailing newline).
pub fn writeIrInstr(w: *io.Writer, ins: IrInstr) io.Writer.Error!void {
    try w.print("{s:<13}", .{@tagName(ins.op)});
    switch (ins.op) {
        .slot_load => try w.print("r{d}", .{ins.aux}),
        .konst => try w.print("k{d}", .{ins.aux}),
        .neg,
        .not,
        .bnot,
        .guard_int,
        .guard_float,
        .guard_number,
        .guard_true,
        .guard_false,
        => try w.print("%{d}", .{ins.a}),
        .loop => {},
        else => try w.print("%{d}  %{d}", .{ ins.a, ins.b }),
    }
}

/// Disassemble a whole trace: header + entry slots + numbered IR + exit stores.
pub fn writeTrace(w: *io.Writer, t: *const Trace) io.Writer.Error!void {
    try w.print("trace {s}:{d}  entry=[", .{ t.anchor.proto.name, t.anchor.pc });
    for (t.entry_slots, 0..) |s, i| {
        if (i != 0) try w.writeAll(" ");
        try w.print("r{d}", .{s});
    }
    try w.writeAll("]\n");
    for (t.instrs, 0..) |ins, i| {
        try w.print("  %{d:0>3}  ", .{i});
        try writeIrInstr(w, ins);
        try w.writeAll("\n");
    }
    if (t.exit_stores.len > 0) {
        try w.writeAll("  exit:");
        for (t.exit_stores) |st| try w.print(" r{d}<-%{d}", .{ st.slot, st.ref });
        try w.writeAll("\n");
    }
}

// ---------------------------------------------------------------------------
// Tests (Increment A): IR shape + disassembler + hotness counting.
// ---------------------------------------------------------------------------

const testing = std.testing;

test "IrInstr stays small" {
    // Cache-sensitive representation; keep it compact. Not serialised here (the
    // wire format is binschema, Phase 5b) — just guard against accidental bloat.
    try testing.expect(@sizeOf(IrInstr) <= 16);
}

test "writeTrace renders a hand-built counting-loop trace" {
    // A stand-in for `for i=lo,hi do acc = acc + i end`'s recorded body:
    //   %0 = slot_load r0   (acc)
    //   %1 = slot_load r1   (i)
    //   %2 = guard_int %0
    //   %3 = guard_int %1
    //   %4 = add %0 %1
    //   loop  (acc<-%4, i<-%1)
    const proto = Proto{ .code = &.{}, .name = "main" };
    var instrs = [_]IrInstr{
        .{ .op = .slot_load, .aux = 0, .ty = .int },
        .{ .op = .slot_load, .aux = 1, .ty = .int },
        .{ .op = .guard_int, .a = 0 },
        .{ .op = .guard_int, .a = 1 },
        .{ .op = .add, .a = 0, .b = 1, .ty = .int },
        .{ .op = .loop },
    };
    var entry = [_]u16{ 0, 1 };
    var stores = [_]SlotStore{ .{ .slot = 0, .ref = 4 }, .{ .slot = 1, .ref = 1 } };
    const t = Trace{
        .anchor = .{ .proto = &proto, .pc = 5 },
        .instrs = &instrs,
        .consts = &.{},
        .entry_slots = &entry,
        .exit_stores = &stores,
    };

    var buf: [512]u8 = undefined;
    var w = io.Writer.fixed(&buf);
    try writeTrace(&w, &t);
    const text = w.buffered();

    try testing.expect(std.mem.indexOf(u8, text, "trace main:5") != null);
    try testing.expect(std.mem.indexOf(u8, text, "entry=[r0 r1]") != null);
    try testing.expect(std.mem.indexOf(u8, text, "slot_load") != null);
    try testing.expect(std.mem.indexOf(u8, text, "guard_int") != null);
    try testing.expect(std.mem.indexOf(u8, text, "add") != null);
    try testing.expect(std.mem.indexOf(u8, text, "exit: r0<-%4 r1<-%1") != null);
}

test "onBackEdge counts per anchor; threshold is the hotness signal" {
    var state = TraceState.init(testing.allocator);
    defer state.deinit();
    state.config.hotloop = 8;

    const proto = Proto{ .code = &.{}, .name = "t" };
    const hot = AnchorKey{ .proto = &proto, .pc = 3 };
    const cold = AnchorKey{ .proto = &proto, .pc = 99 };

    var i: u32 = 0;
    while (i < 10) : (i += 1) state.onBackEdge(&proto, 3);
    state.onBackEdge(&proto, 99); // a single, cold back-edge elsewhere

    try testing.expectEqual(@as(u32, 10), state.backEdgeCount(hot));
    try testing.expect(state.backEdgeCount(hot) >= state.config.hotloop); // hot
    try testing.expectEqual(@as(u32, 1), state.backEdgeCount(cold));
    try testing.expect(state.backEdgeCount(cold) < state.config.hotloop); // cold
}
