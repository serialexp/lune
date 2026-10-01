//! Tests for `trace.zig` — widen-eviction (`laneWidenedPast`).
//!
//! The predicate's premise is lane monotonicity, and monotonicity begins only
//! at the one-shot lane commitment (`ArrayPart.frozen`, set by
//! `commitFreshLane`). A fresh, unfrozen `.value` array is lane-UNDECIDED: its
//! first real store will commit it to a narrow lane, so a narrow `guard_lane`
//! can absolutely pass on a later entry. Treating that state as "widened past"
//! caused a per-outer-iteration mint→retire→re-record churn on every
//! fill-a-fresh-table loop (`local r = {}; for j=1,n do r[j]=v end` — ~600
//! full record+compile+retire rounds per grid_matmul run, doc 47 increment D).
//!
//! Doc 48 layered identity on top: monotonicity is a per-TABLE invariant, so
//! the predicate only accepts evidence from the very table the recorder
//! observed, matched by deterministic `GcHeader.id` via `TraceCode.lane_pins`.
//! A different table live at the guarded register (a polymorphic anchor,
//! doc 33) proves nothing — evicting there churned spectral-norm's f64 Av
//! sibling once per u-burst.

const trace = @import("trace.zig");
const std = @import("std");
const value = @import("value.zig");
const regwindow = @import("regwindow.zig");
const table_mod = @import("table.zig");
const arr = @import("array.zig");
const testing = std.testing;

const Value = value.Value;
const RegWindow = regwindow.RegWindow;
const IrInstr = trace.IrInstr;
const Trace = trace.Trace;
const TraceState = trace.TraceState;
const EntryGuard = trace.EntryGuard;
const ExitProvEntry = trace.ExitProvEntry;
const LanePin = trace.LanePin;

/// A minimal trace whose IR pins `guard_lane(lane)` on the table in tier-0
/// register 0: `%0 slot_load r0; %1 guard_lane %0 aux=lane`. Exactly the shape
/// `laneWidenedPast` walks (guard_lane.a → slot_load → .aux register). When
/// `pin_table_id` is non-null, a `LanePin` binds the guard to that table
/// identity (doc 48); with null, the trace carries no pins — the recorder's
/// OOM-skip / pre-doc-48 shape — and must never be evicted.
fn laneGuardTrace(gpa: std.mem.Allocator, lane: arr.Lane, pin_table_id: ?u32) !*Trace {
    const t = try gpa.create(Trace);
    errdefer gpa.destroy(t);
    const instrs = try gpa.alloc(IrInstr, 2);
    instrs[0] = .{ .op = .slot_load, .aux = 0 };
    instrs[1] = .{ .op = .guard_lane, .a = 0, .aux = @intFromEnum(lane) };
    var pins: []LanePin = &.{};
    if (pin_table_id) |tid| {
        pins = try gpa.alloc(LanePin, 1);
        pins[0] = .{ .guard_ref = 1, .table_id = tid };
    }
    t.* = .{
        .code = .{
            .anchor = .{ .proto = undefined, .pc = 0 },
            .instrs = instrs,
            .consts = try gpa.alloc(Value, 0),
            .entry_slots = try gpa.alloc(u16, 0),
            .entry_guards = try gpa.alloc(EntryGuard, 0),
            .exit_prov = try gpa.alloc(ExitProvEntry, 0),
            .lane_pins = pins,
        },
        .id = 1,
    };
    return t;
}

fn destroyLaneGuardTrace(gpa: std.mem.Allocator, t: *Trace) void {
    t.code.deinit(gpa);
    gpa.destroy(t);
}

test "widen-eviction predicate: unfrozen .value array never evicts (lane-undecided), frozen .value does" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();

    const tbl = try table_mod.Table.create(gpa);
    defer tbl.destroy(gpa);

    const t = try laneGuardTrace(gpa, .f64, tbl.header.id);
    defer destroyLaneGuardTrace(gpa, t);

    var tags = [_]u8{0};
    var payloads = [_]u64{0};
    const regs = RegWindow.of(&tags, &payloads);
    regs.set(0, Value.heap(&tbl.header));

    // Fresh `{}`: `.value`, unfrozen — the state every next-outer-iteration
    // fill table is in when the dispatcher first enters the fill trace. The
    // first real store will commit it to `.f64`, so the guard can still pass:
    // NOT widened past (the doc 47 increment D fix).
    try testing.expectEqual(arr.Lane.value, tbl.array.lane);
    try testing.expect(!tbl.array.frozen);
    try testing.expect(!state.laneWidenedPast(t, regs));

    // The same `.value` lane FROZEN (a table demoted to `.value` by a
    // type-incompatible store keeps its commitment): `.value` is the lattice
    // top and reaches nothing, so an f64 pin is permanently dead → evict.
    tbl.array.frozen = true;
    try testing.expect(state.laneWidenedPast(t, regs));
}

test "widen-eviction predicate: frozen lanes follow canWidenTo reachability" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();

    const tbl = try table_mod.Table.create(gpa);
    defer tbl.destroy(gpa);
    tbl.array.frozen = true;

    var tags = [_]u8{0};
    var payloads = [_]u64{0};
    const regs = RegWindow.of(&tags, &payloads);
    regs.set(0, Value.heap(&tbl.header));

    // Same lane as the pin: guard passes today → no eviction.
    {
        const t = try laneGuardTrace(gpa, .f64, tbl.header.id);
        defer destroyLaneGuardTrace(gpa, t);
        tbl.array.lane = .f64;
        try testing.expect(!state.laneWidenedPast(t, regs));
    }
    // Live `.i8` vs an `.i16` pin: not equal, but `i8.canWidenTo(i16)` — the
    // array can still reach the pinned lane → no eviction.
    {
        const t = try laneGuardTrace(gpa, .i16, tbl.header.id);
        defer destroyLaneGuardTrace(gpa, t);
        tbl.array.lane = .i8;
        try testing.expect(!state.laneWidenedPast(t, regs));
    }
    // Live `.i64` vs an `.i16` pin: ints never re-narrow → permanently dead →
    // evict (the original, still-correct eviction case — the monotonic
    // single-table fill this predicate was built for, commit e53fbe8).
    {
        const t = try laneGuardTrace(gpa, .i16, tbl.header.id);
        defer destroyLaneGuardTrace(gpa, t);
        tbl.array.lane = .i64;
        try testing.expect(state.laneWidenedPast(t, regs));
    }
}

test "widen-eviction predicate: a different table at the guarded register is no evidence (doc 48 polymorphic anchor)" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();

    // Table A: what the recorder saw (the pin). Table B: a sibling flowing
    // through the same anchor — spectral-norm's Av alternates exactly like
    // this (x=u on the `.value` lane, x=v on `.f64`).
    const tbl_a = try table_mod.Table.create(gpa);
    defer tbl_a.destroy(gpa);
    const tbl_b = try table_mod.Table.create(gpa);
    defer tbl_b.destroy(gpa);
    // Unit tables never pass through `gc.Heap.link`, so both would sit at
    // id 0 and collide. Give them distinct ids. (NB 0 is itself a VALID
    // identity in a real VM — the globals table — which the same-table tests
    // above exercise implicitly by pinning id 0 against a live id-0 table.)
    tbl_a.header.id = 1;
    tbl_b.header.id = 2;

    // The trace pins `.f64` on A's identity.
    const t = try laneGuardTrace(gpa, .f64, tbl_a.header.id);
    defer destroyLaneGuardTrace(gpa, t);

    var tags = [_]u8{0};
    var payloads = [_]u64{0};
    const regs = RegWindow.of(&tags, &payloads);

    // B is frozen on `.value` — widened past `.f64` in every lane-only sense.
    // Pre-doc-48 this evicted the f64 trace once per B entry. With identity:
    // B's id ≠ the pin's id → no evidence → the sibling survives.
    tbl_b.array.frozen = true;
    tbl_b.array.lane = .value;
    regs.set(0, Value.heap(&tbl_b.header));
    try testing.expect(!state.laneWidenedPast(t, regs));

    // Control: the SAME lane state on the pinned table itself does evict.
    tbl_a.array.frozen = true;
    tbl_a.array.lane = .value;
    regs.set(0, Value.heap(&tbl_a.header));
    try testing.expect(state.laneWidenedPast(t, regs));
}

test "widen-eviction predicate: no pins → never evicts (fail-safe)" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();

    const tbl = try table_mod.Table.create(gpa);
    defer tbl.destroy(gpa);
    // Maximally evictable lane state: frozen on the lattice top.
    tbl.array.frozen = true;
    tbl.array.lane = .value;

    // Pin capture is best-effort (`append(...) catch {}` in the recorder, and
    // finalize drops pins whose guard was optimized away): a pinless trace
    // must fail safe to "keep", never to "evict".
    const t = try laneGuardTrace(gpa, .f64, null);
    defer destroyLaneGuardTrace(gpa, t);

    var tags = [_]u8{0};
    var payloads = [_]u64{0};
    const regs = RegWindow.of(&tags, &payloads);
    regs.set(0, Value.heap(&tbl.header));
    try testing.expect(!state.laneWidenedPast(t, regs));
}

test "widen-eviction predicate: pinned table widens while a same-lane sibling remains — accepted re-record (doc 48 heuristic)" {
    const gpa = testing.allocator;
    var state = TraceState.init(gpa);
    defer state.deinit();

    // Adversarial shape (codex round-1): the trace is LANE-specialized, not
    // identity-specialized, so after pinned table A widens past `.f64`, a
    // sibling B still ON `.f64` could have kept using the trace. The doc 48
    // decision: evict anyway when A shows up (the pin is our only per-table
    // monotonicity evidence); B's next entry re-records — one re-record is
    // the accepted cost, not a churn loop. This test pins that behavior so a
    // future "fix" doesn't silently flip it without revisiting the design.
    const tbl_a = try table_mod.Table.create(gpa);
    defer tbl_a.destroy(gpa);
    const tbl_b = try table_mod.Table.create(gpa);
    defer tbl_b.destroy(gpa);
    tbl_a.header.id = 1;
    tbl_b.header.id = 2;

    const t = try laneGuardTrace(gpa, .f64, tbl_a.header.id);
    defer destroyLaneGuardTrace(gpa, t);

    tbl_a.array.frozen = true;
    tbl_a.array.lane = .value; // A: widened past the pin
    tbl_b.array.frozen = true;
    tbl_b.array.lane = .f64; // B: still exactly on the trace's lane

    var tags = [_]u8{0};
    var payloads = [_]u64{0};
    const regs = RegWindow.of(&tags, &payloads);

    // B live → guard would pass; no eviction (and no evidence either way).
    regs.set(0, Value.heap(&tbl_b.header));
    try testing.expect(!state.laneWidenedPast(t, regs));

    // A live → identity matches, lane widened past → evict, even though B
    // could still have used the trace. Accepted single re-record.
    regs.set(0, Value.heap(&tbl_a.header));
    try testing.expect(state.laneWidenedPast(t, regs));
}

// ---------------------------------------------------------------------------
// Doc 48 integration: lane-pin integrity through the real record→optimize→
// commit pipeline. The recorder captures `LanePin.guard_ref` in EMISSION index
// space; tropt's compaction (DCE/CSE drops) and preheader insertion both shift
// committed indices, so finalize must remap pins through `old_to_new`. A
// peel-only test would miss that failure — this source shifts the guard both
// ways (the fill trace's guard moves DOWN via a compaction drop, the read
// trace's moves UP past an inserted preheader).
// ---------------------------------------------------------------------------

const interp = @import("interp.zig");
const compiler = @import("compiler.zig");
const io = @import("io.zig");
const testutil = @import("interp_testutil.zig");
const Vm = interp.Vm;

/// (anchor pc, guarded lane, pinned id, committed pin index) collected from
/// one pipeline run — pc+lane+table_id identify the same logical guard across
/// the unoptimized and optimized pipelines, so the shift assertions below
/// can't be satisfied by accidentally comparing two different guards.
const PinEntry = struct { pc: u32, lane: i32, table_id: u32, guard_ref: u32 };

/// The doc 48 pin-shift source: a fill loop (append-path guard_lane) and a
/// read loop with a hoistable invariant (`q * q`) ahead of the array access,
/// so tropt's preheader insertion moves the read trace's guard_lane index.
const pin_shift_source =
    \\local a = {}
    \\for i = 1, 60 do a[i] = i * 0.5 end
    \\local q = 2.5
    \\local s = 0
    \\for i = 1, 60 do
    \\  local w = q * q
    \\  s = s + a[i] * w
    \\end
    \\print(s)
;

/// Run `pin_shift_source` with the trace pipeline in `mode`, and return the
/// per-anchor guard_ref of every lane pin (asserting pin integrity on the way:
/// each pin must point at a committed `guard_lane` and carry a real heap id).
fn collectPins(mode: testutil.TraceMode, pins_out: *std.ArrayListUnmanaged(PinEntry), gpa: std.mem.Allocator) !void {
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, pin_shift_source, &diags);
    defer tree.deinit();
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    vm.trace.config.enabled = true;
    vm.trace.config.execute = true;
    vm.trace.config.optimize = mode == .record_execute;
    vm.trace.config.hotloop = 4;
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;
    var chunk = try compiler.compile(gpa, vm.heap, pin_shift_source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    _ = try vm.run(chunk.proto);

    for (vm.trace.registry.cache.items) |t| {
        for (t.code.lane_pins) |pin| {
            // Pin integrity: a remap failure leaves guard_ref pointing at
            // whatever op now sits at the stale emission index.
            try testing.expect(pin.guard_ref < t.code.instrs.len);
            try testing.expectEqual(trace.IrOp.guard_lane, t.code.instrs[pin.guard_ref].op);
            // NB id 0 is a VALID identity (the globals table is heap id 0;
            // gc.Heap starts next_obj_id at 0) — no non-zero assertion here.
            try pins_out.append(gpa, .{
                .pc = t.code.anchor.pc,
                .lane = t.code.instrs[pin.guard_ref].aux,
                .table_id = pin.table_id,
                .guard_ref = pin.guard_ref,
            });
        }
    }
}

test "doc 48: lane pins survive tropt compaction and preheader insertion (guard_ref remap)" {
    const gpa = testing.allocator;
    var unopt: std.ArrayListUnmanaged(PinEntry) = .empty;
    defer unopt.deinit(gpa);
    var opt: std.ArrayListUnmanaged(PinEntry) = .empty;
    defer opt.deinit(gpa);
    try collectPins(.record_execute_noopt, &unopt, gpa);
    try collectPins(.record_execute, &opt, gpa);

    // Both pipelines commit pinned traces for both loops (non-vacuous).
    try testing.expect(unopt.items.len >= 2);
    try testing.expect(opt.items.len >= 2);

    // The optimizer must actually MOVE guard indices for this source — in
    // BOTH directions (down via a compaction drop in the fill trace, up past
    // the read trace's inserted preheader) — or the remap is untested.
    // Match the same logical guard by pc+lane+table_id, not pc alone. If
    // tropt ever stops shifting here, strengthen the source rather than
    // deleting the asserts.
    var moved_down = false;
    var moved_up = false;
    for (opt.items) |o| {
        for (unopt.items) |u| {
            if (u.pc == o.pc and u.lane == o.lane and u.table_id == o.table_id) {
                if (o.guard_ref < u.guard_ref) moved_down = true;
                if (o.guard_ref > u.guard_ref) moved_up = true;
            }
        }
    }
    try testing.expect(moved_down);
    try testing.expect(moved_up);
}

// ---------------------------------------------------------------------------
// Doc 48 §"guard-dedup peel-rewind staleness": the spectral cont shape. The
// loop-done continuation records `y[i] = a` while `y` is still in its append
// phase; a failed peel rewinds the IR, and the `guarded_refs` dedup map must
// purge every entry whose GUARD was truncated (keyed on the guard's own
// instruction index, always above the guarded ref's). The stale-map bug kept
// the inner for_prep limit's slot_load marked "guarded" after its guard_num
// was rewound away — the re-emit was suppressed, the committed cont carried a
// silently-unguarded slot_load, and proveKinds rejected it: a permanently
// tier-1a cont (3.3%-native spectral). The `A(i, j)` call is required — the
// inlined-call shape is what forces the failed peel.
// ---------------------------------------------------------------------------

const cont_peel_source =
    \\local function A(i, j)
    \\  local ij = i+j-1
    \\  return 1.0 / (ij * (ij-1) * 0.5 + i)
    \\end
    \\local function Av(x, y, N)
    \\  for i=1,N do
    \\    local a = 0
    \\    for j=1,N do a = a + x[j] * A(i, j) end
    \\    y[i] = a
    \\  end
    \\end
    \\local N = 60
    \\local u, t = {}, {}
    \\for i=1,N do u[i] = 1.0 end
    \\for k=1,10 do Av(u, t, N) end
    \\print(string.format("%0.9f", t[1] + t[N]))
;

test "doc 48: peel-rewound guards are purged from the dedup map — the spectral cont proves native" {
    const gpa = testing.allocator;
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, cont_peel_source, &diags);
    defer tree.deinit();
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    vm.trace.config.enabled = true;
    vm.trace.config.execute = true;
    vm.trace.config.optimize = true;
    vm.trace.config.native_codegen = true;
    vm.trace.config.hotloop = 4;
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;
    var chunk = try compiler.compile(gpa, vm.heap, cont_peel_source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    _ = try vm.run(chunk.proto);

    // The regression's signature: a dispatched trace stuck `.unsupported`
    // (proveKinds rejected the silently-unguarded slot_load). Post-fix, every
    // trace this program dispatches natively must compile.
    var compiled: usize = 0;
    for (vm.trace.registry.cache.items) |t| {
        try testing.expect(t.native != .unsupported);
        if (t.native == .compiled) compiled += 1;
    }
    // Non-vacuous: the loop bodies AND the cont went native.
    try testing.expect(compiled >= 2);
}

// Tier-0 equivalence for both doc 48 reproducers, through the full native
// pipeline — eviction and pin bookkeeping must never change program output.
fn expectNativeTier0Equiv(source: [:0]const u8) !void {
    var buf0: [256]u8 = undefined;
    var s0 = io.Writer.fixed(&buf0);
    try testutil.runCaptured(testing.allocator, source, &s0, false, .off);
    var buf1: [256]u8 = undefined;
    var s1 = io.Writer.fixed(&buf1);
    try testutil.runCaptured(testing.allocator, source, &s1, false, .record_execute_native);
    try testing.expectEqualStrings(s0.buffered(), s1.buffered());
}

test "doc 48: cont-peel reproducer is tier-0 equivalent under the native pipeline" {
    try expectNativeTier0Equiv(cont_peel_source);
}

test "doc 48: alternating-lane (polymorphic anchor) reproducer is tier-0 equivalent under the native pipeline" {
    // The lane_alt shape: the same Av anchor sees x=u (i64 lane widened to
    // .value by a float overwrite) and x=v (pure f64) on alternating calls.
    // Pre-doc-48 the f64 sibling was widen-evicted once per u entry (commit→
    // retire churn); either way the output must be byte-identical to tier-0.
    try expectNativeTier0Equiv(
        \\local function A(i, j)
        \\  local ij = i+j-1
        \\  return 1.0 / (ij * (ij-1) * 0.5 + i)
        \\end
        \\local function Av(x, y, N)
        \\  for i=1,N do
        \\    local a = 0
        \\    for j=1,N do a = a + x[j] * A(i, j) end
        \\    y[i] = a
        \\  end
        \\end
        \\local N = 60
        \\local u, v, t = {}, {}, {}
        \\for i=1,N do u[i] = 1 end
        \\for i=1,N do v[i] = 0.5 end
        \\for i=1,N do u[i] = 0.25 end
        \\for k=1,8 do Av(u, t, N) Av(v, t, N) end
        \\print(string.format("%0.9f", t[1] + t[N]))
    );
}

// ---------------------------------------------------------------------------
// Doc 48 dispatch-level policy tests (codex round-2): the predicate unit
// tests above can't detect the `laneWidenedPast` call being dropped from the
// dispatch walk, or retirement hitting the wrong candidate — and output
// equivalence passes even WITH the old churn. These assert the cache
// structure the policy promises.
// ---------------------------------------------------------------------------

/// Per-pc lane census over the committed trace cache.
fn laneAt(t: *const Trace, lane: arr.Lane) bool {
    for (t.code.instrs) |ins| {
        if (ins.op == .guard_lane and ins.aux == @intFromEnum(lane)) return true;
    }
    return false;
}

/// Does the trace guard ANY integer lane (the narrow rungs a float store
/// widens past)? Small int literals commit to `.u8` (ordinal 7), bigger to
/// the i8..i64 ladder — the census must not care which rung the fixture
/// landed on.
fn guardsIntLane(t: *const Trace) bool {
    inline for (.{ arr.Lane.i8, arr.Lane.i16, arr.Lane.i32, arr.Lane.i64, arr.Lane.u8 }) |l| {
        if (laneAt(t, l)) return true;
    }
    return false;
}

fn inspectPolymorphicSiblings(vm: *Vm, mode: testutil.TraceMode) anyerror!void {
    _ = mode;
    // Find the polymorphic anchor: a pc with BOTH a value-lane and an
    // f64-lane sibling. It must exist (both burst flavors ran hot; the old
    // live-table-quantified predicate evicted the f64 sibling on every u
    // entry, so its coexistence IS the regression pin), and no such pc may
    // still hold the dead narrow-int sibling (pinned to u, which widened
    // past its int lane mid-run — precisely evicted on the next u entry).
    var found_poly = false;
    for (vm.trace.registry.cache.items) |t| {
        if (!laneAt(t, .value)) continue;
        var has_f64 = false;
        var has_int = false;
        for (vm.trace.registry.cache.items) |s| {
            // Same anchor = same proto AND same pc (pcs are proto-local),
            // and a DISTINCT trace — one trace guarding several lanes on
            // different tables must not masquerade as two coexisting
            // siblings (codex round-3).
            if (s == t) continue;
            if (s.code.anchor.proto != t.code.anchor.proto) continue;
            if (s.code.anchor.pc != t.code.anchor.pc) continue;
            if (laneAt(s, .f64)) has_f64 = true;
            if (guardsIntLane(s)) has_int = true;
        }
        if (has_f64) {
            found_poly = true;
            try testing.expect(!has_int); // the zombie is gone
        }
    }
    try testing.expect(found_poly); // both siblings coexist at one anchor
}

test "doc 48 dispatch: polymorphic siblings coexist and the widened-past zombie is retired" {
    // u starts on a narrow integer lane (`u[i] = 1` commits `.u8`; a
    // narrow-int sibling records), widens to .value mid-run, then
    // alternates with pure-f64 v — the spectral shape end-to-end. Ends on u,
    // the entry that pre-doc-48 killed the f64 sibling every burst.
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    try testutil.runCapturedTuned(testing.allocator,
        \\local function A(i, j)
        \\  local ij = i+j-1
        \\  return 1.0 / (ij * (ij-1) * 0.5 + i)
        \\end
        \\local function Av(x, y, N)
        \\  for i=1,N do
        \\    local a = 0
        \\    for j=1,N do a = a + x[j] * A(i, j) end
        \\    y[i] = a
        \\  end
        \\end
        \\local N = 40
        \\local u, v, t = {}, {}, {}
        \\for i=1,N do u[i] = 1 end
        \\for i=1,N do v[i] = 0.5 end
        \\for k=1,3 do Av(u, t, N) end
        \\for i=1,N do u[i] = 0.25 end
        \\for k=1,6 do Av(v, t, N) Av(u, t, N) end
        \\print(string.format("%0.6f", t[1] + t[N]))
    , &sink, false, .record_execute_native, .{ .inspect = &inspectPolymorphicSiblings });
}

fn inspectMonotonicRetirement(vm: *Vm, mode: testutil.TraceMode) anyerror!void {
    _ = mode;
    // Census scoped to the `fill` proto's loop anchor: BOTH phases run that
    // same anchor, so its int-lane trace (phase 1) is re-entered after the
    // widen and must be retired from the cache — not merely flagged by the
    // standalone predicate. (Phase-1 traces at anchors phase 2 never
    // re-enters — the first outer `for k` loop — legitimately survive:
    // eviction is entry-driven, so they stay out of this census. So does the
    // doc 56 exit-side child phase 1 records mid-body in `fill`: it is entered
    // only through its parent's adapter, which retirement disarms.)
    var has_value = false;
    for (vm.trace.registry.cache.items) |t| {
        const p = t.code.anchor.proto;
        if (!std.mem.eql(u8, p.name, "fill")) continue;
        const loop_header = for (p.code, 0..) |ins, pc| {
            if (ins.op == .for_loop) break @import("bytecode.zig").loopHeaderOf(ins, pc).?;
        } else return error.TestUnexpectedResult;
        if (t.code.anchor.pc != loop_header) continue;
        try testing.expect(!guardsIntLane(t));
        if (laneAt(t, .value)) has_value = true;
    }
    try testing.expect(has_value); // the successor trace exists (non-vacuous)
}

test "doc 48 dispatch: monotonic same-table widening still retires the stale narrow trace" {
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    try testutil.runCapturedTuned(testing.allocator,
        \\local function fill(t, v)
        \\  for i=1,50 do t[i] = v end
        \\end
        \\local r = {}
        \\for k=1,8 do fill(r, 1) end
        \\for k=1,8 do fill(r, 0.5) end
        \\print(r[1] + r[50])
    , &sink, false, .record_execute_native, .{ .inspect = &inspectMonotonicRetirement });
}
