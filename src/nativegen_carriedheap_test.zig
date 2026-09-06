//! Tests for `nativegen.zig` — doc 22 Phase A: carried-heap slots (heap φ writeback).
//!
//! The shape under test is the nbody outer body `bi = b[i]` — a slot that is BOTH
//! `slot_load`-read (guard_table-covered, so its ref kind is `.ptr`) and φ-written
//! with a per-iteration `.heap` table value. Phase A classifies it `.carried`/`.heap`
//! and lowers every table fact rooted at it dynamically (in-body guard_table,
//! guard_hash count check, `resolveHashCell` callout, per-iteration hload tag check),
//! exactly matching tier-1a's per-iteration semantics.
//!
//! Shared harness lives in `nativegen_testutil.zig`; the IR-building idiom follows
//! the Phase F `.value`-lane tests in `nativegen_arrayread_test.zig`.

const nativegen = @import("nativegen.zig");
const std = @import("std");
const trace = @import("trace.zig");
const value = @import("value.zig");
const table = @import("table.zig");
const arr = @import("array.zig");
const string = @import("string.zig");
const Value = value.Value;
const Trace = @import("trace_code.zig").TraceCode;
const RegWindow = @import("regwindow.zig").RegWindow;
const testing = std.testing;
const irinterp = @import("irinterp.zig");
const trace_exec = @import("trace_exec.zig");
const I = trace.IrInstr;

const VALUE_LANE = nativegen.VALUE_LANE;
const compile = nativegen.compile;
const is_x64_linux = nativegen.is_x64_linux;

const util = @import("nativegen_testutil.zig");
const expectBail = util.expectBail;
const expectMatch = util.expectMatch;
const runNative = util.runNative;

/// Build the canonical carried-heap universe: a `.value`-lane container whose dense
/// keys `1..n` hold `n` DISTINCT element tables, each with exactly one hash field
/// `key = <int i>`. Distinct per-element values make any stale-cell reuse (native
/// caching iteration 0's absolute cell pointer instead of re-resolving against the
/// CURRENT carried table) diverge from the oracle immediately.
fn buildUniverse(
    gpa: std.mem.Allocator,
    key_val: Value,
    elems: []*table.Table,
    built: *usize,
) !*table.Table {
    const container = try table.Table.create(gpa);
    errdefer container.destroy(gpa);
    for (elems, 0..) |*slot, i| {
        const e = try table.Table.create(gpa);
        slot.* = e;
        built.* += 1;
        try e.set(gpa, key_val, Value.int(@intCast(i + 1)));
        try container.set(gpa, Value.int(@intCast(i + 1)), Value.heap(&e.header));
    }
    try testing.expectEqual(arr.Lane.value, container.array.lane);
    return container;
}

/// The carried-heap READ loop (nbody inner-read shape), hand-built:
///   r0=container, r1=index, r2=bi (CARRIED-HEAP), r3=acc.
///   per iteration: acc += bi.v ; bi = container[index] ; index += 1.
/// `bi` is slot_load-read at 5 (guard_table-covered → `.ptr` ref kind) and φ-written
/// at the back edge with the VALUE_LANE aload result (`.heap`) — the doc 22 §A.1
/// carried-heap slot. The href carries a (redundant, option-(b)) seed slot in `aux`;
/// both the oracle and the dynamic native lowering ignore it.
fn carriedReadIr(consts: []Value, full: []I) void {
    consts[0] = undefined; // caller fills the key konst
    consts[1] = Value.int(1);
    const ir = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: container
        .{ .op = .guard_table, .a = 0 }, // 1: prologue-hoisted (.ptr root)
        .{ .op = .guard_lane, .a = 0, .aux = VALUE_LANE }, // 2
        .{ .op = .slot_load, .aux = 1 }, // 3: index
        .{ .op = .guard_int, .a = 3 }, // 4
        .{ .op = .slot_load, .aux = 2 }, // 5: bi — carried-heap
        .{ .op = .guard_table, .a = 5 }, // 6: DYNAMIC per-iteration (carried root)
        .{ .op = .konst, .aux = 0 }, // 7: field key
        .{ .op = .href, .a = 5, .b = 7, .aux = 4 }, // 8: carried root → callout (aux seed unused)
        .{ .op = .guard_hash, .a = 8, .aux = 1 }, // 9: DYNAMIC count check
        .{ .op = .hload, .a = 8, .ty = .int }, // 10: v = bi.v
        .{ .op = .slot_load, .aux = 3 }, // 11: acc
        .{ .op = .guard_int, .a = 11 }, // 12
        .{ .op = .add, .a = 11, .b = 10, .ty = .int }, // 13: acc + v
        .{ .op = .aref, .a = 0, .b = 3, .aux = VALUE_LANE }, // 14
        .{ .op = .guard_bounds, .a = 14 }, // 15
        .{ .op = .aload, .a = 14, .aux = VALUE_LANE, .ty = .heap }, // 16: next element
        .{ .op = .konst, .aux = 1 }, // 17: 1
        .{ .op = .add, .a = 3, .b = 17, .ty = .int }, // 18: index + 1
        .{ .op = .phi, .b = 18, .aux = 1 }, // index carry
        .{ .op = .phi, .b = 13, .aux = 3 }, // acc carry
        .{ .op = .phi, .b = 16, .aux = 2 }, // bi carry — THE carried-heap φ
        .{ .op = .loop }, // 22
    };
    @memcpy(full, &ir);
}

const CARRIED_READ_LEN = 23;

test "nativegen(doc22 A): carried-heap read loop matches the interpreter" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;

    const key = try string.String.create(gpa, "v");
    defer key.destroy(gpa);
    const key_val = Value.heap(&key.header);

    const N: usize = 32;
    var elems: [N]*table.Table = undefined;
    var built: usize = 0;
    defer for (elems[0..built]) |e| e.destroy(gpa);
    const container = try buildUniverse(gpa, key_val, &elems, &built);
    defer container.destroy(gpa);

    var consts: [2]Value = undefined;
    var full: [CARRIED_READ_LEN]I = undefined;
    carriedReadIr(&consts, &full);
    consts[0] = key_val;
    var es = [_]u16{};
    const tr = Trace{ .anchor = undefined, .instrs = &full, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };

    // Full scan from 1 (bi seeded with the LAST element so its value differs from
    // container[1]'s — a stale-cell or stale-table bug shows immediately). Sums a
    // different v every iteration, bounds-exits past N; the mid-loop exit flushes
    // the carried-heap home TAG_HEAP + the CURRENT table (expectRegsEqual checks
    // tag AND payload bits, so the flushed pointer is pinned too).
    try expectMatch(&tr, &.{ Value.heap(&container.header), Value.int(1), Value.heap(&elems[N - 1].header), Value.int(0) });
    // Start mid-run: shorter clean prefix, then bounds-exit.
    try expectMatch(&tr, &.{ Value.heap(&container.header), Value.int(20), Value.heap(&elems[0].header), Value.int(0) });
    // Start past the run: guard_bounds side-exits on iteration 0 — but AFTER the
    // acc update at 13, which therefore must NOT have been coalesced in place.
    try expectMatch(&tr, &.{ Value.heap(&container.header), Value.int(@intCast(N + 5)), Value.heap(&elems[3].header), Value.int(100) });
    // Entry-state mismatch: bi holds an INT → the native entry tag check (TAG_HEAP
    // for a `.heap` carried slot) and the oracle's guard_table both exit with
    // completed==0 and untouched regs.
    try expectMatch(&tr, &.{ Value.heap(&container.header), Value.int(1), Value.int(7), Value.int(0) });
}

test "nativegen(doc22 A): carried-heap read loop matches on the frameless production path" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;

    // Same trace through compileInto + McodeArena + the shared trampoline — the only
    // path that stages the exit dispatch target in memory, so it pins the
    // resolveHashCell callout's interaction with exit staging and the save area.
    const key = try string.String.create(gpa, "v");
    defer key.destroy(gpa);
    const key_val = Value.heap(&key.header);

    const N: usize = 16;
    var elems: [N]*table.Table = undefined;
    var built: usize = 0;
    defer for (elems[0..built]) |e| e.destroy(gpa);
    const container = try buildUniverse(gpa, key_val, &elems, &built);
    defer container.destroy(gpa);

    var consts: [2]Value = undefined;
    var full: [CARRIED_READ_LEN]I = undefined;
    carriedReadIr(&consts, &full);
    consts[0] = key_val;
    var es = [_]u16{};
    const tr = Trace{ .anchor = undefined, .instrs = &full, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };

    try expectMatch(&tr, &.{ Value.heap(&container.header), Value.int(1), Value.heap(&elems[N - 1].header), Value.int(0) });
    try expectMatch(&tr, &.{ Value.heap(&container.header), Value.int(10), Value.heap(&elems[2].header), Value.int(5) });
}

test "nativegen(doc22 A): hstore through a carried-heap root writes the CURRENT table" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;

    // The nbody WRITEBACK shape: bi.v = bi.v + 10 through the per-iteration cell.
    // A stale-cell bug here corrupts the wrong table's field, so we run the oracle
    // and native on two IDENTICAL, DISJOINT universes and compare field-by-field.
    const key = try string.String.create(gpa, "v");
    defer key.destroy(gpa);
    const key_val = Value.heap(&key.header);

    const N: usize = 24;
    var elems_a: [N]*table.Table = undefined;
    var built_a: usize = 0;
    defer for (elems_a[0..built_a]) |e| e.destroy(gpa);
    const cont_a = try buildUniverse(gpa, key_val, &elems_a, &built_a);
    defer cont_a.destroy(gpa);

    var elems_b: [N]*table.Table = undefined;
    var built_b: usize = 0;
    defer for (elems_b[0..built_b]) |e| e.destroy(gpa);
    const cont_b = try buildUniverse(gpa, key_val, &elems_b, &built_b);
    defer cont_b.destroy(gpa);

    // r0=container, r1=index, r2=bi (carried-heap). Per iteration:
    //   bi.v = bi.v + 10 ; bi = container[index] ; index += 1.
    var consts = [_]Value{ key_val, Value.int(10), Value.int(1) };
    var full = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: container
        .{ .op = .guard_table, .a = 0 }, // 1
        .{ .op = .guard_lane, .a = 0, .aux = VALUE_LANE }, // 2
        .{ .op = .slot_load, .aux = 1 }, // 3: index
        .{ .op = .guard_int, .a = 3 }, // 4
        .{ .op = .slot_load, .aux = 2 }, // 5: bi — carried-heap
        .{ .op = .guard_table, .a = 5 }, // 6: dynamic
        .{ .op = .konst, .aux = 0 }, // 7: key
        .{ .op = .href, .a = 5, .b = 7, .aux = 3 }, // 8: callout (seed aux unused)
        .{ .op = .guard_hash, .a = 8, .aux = 1 }, // 9
        .{ .op = .hload, .a = 8, .ty = .int }, // 10: v
        .{ .op = .konst, .aux = 1 }, // 11: 10
        .{ .op = .add, .a = 10, .b = 11, .ty = .int }, // 12: v + 10
        .{ .op = .hstore, .a = 8, .b = 12 }, // 13: bi.v = v + 10
        .{ .op = .aref, .a = 0, .b = 3, .aux = VALUE_LANE }, // 14
        .{ .op = .guard_bounds, .a = 14 }, // 15
        .{ .op = .aload, .a = 14, .aux = VALUE_LANE, .ty = .heap }, // 16: next bi
        .{ .op = .konst, .aux = 2 }, // 17: 1
        .{ .op = .add, .a = 3, .b = 17, .ty = .int }, // 18: index + 1
        .{ .op = .phi, .b = 18, .aux = 1 },
        .{ .op = .phi, .b = 16, .aux = 2 },
        .{ .op = .loop }, // 21
    };
    var es = [_]u16{};
    const tr = Trace{ .anchor = undefined, .instrs = &full, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };

    // Oracle on universe A.
    const iregs = try gpa.dupe(Value, &.{ Value.heap(&cont_a.header), Value.int(1), Value.heap(&elems_a[N - 1].header), Value.nil() });
    defer gpa.free(iregs);
    const values = try gpa.alloc(Value, tr.instrs.len);
    defer gpa.free(values);
    const iresult = irinterp.executeValues(&tr, iregs, values);

    // Native on universe B (same logical entry state).
    var ct = compile(gpa, &tr, 0) orelse return error.NativeBailedUnexpectedly;
    defer ct.deinit();
    const nregs = try gpa.dupe(Value, &.{ Value.heap(&cont_b.header), Value.int(1), Value.heap(&elems_b[N - 1].header), Value.nil() });
    defer gpa.free(nregs);
    const nresult = try runNative(ct, nregs);

    try testing.expectEqual(iresult.completed, nresult.completed);
    // Scalar regs bit-equal; heap regs point at the CORRESPONDING object of each
    // universe (same tag, and bi resolves to the same element index).
    try testing.expectEqual(@intFromEnum(iregs[1].tag), @intFromEnum(nregs[1].tag));
    try testing.expectEqual(iregs[1].payload.bits, nregs[1].payload.bits);
    try testing.expectEqual(@intFromEnum(iregs[2].tag), @intFromEnum(nregs[2].tag));
    var idx_a: ?usize = null;
    var idx_b: ?usize = null;
    for (elems_a, 0..) |e, i| {
        if (iregs[2].payload.bits == @intFromPtr(&e.header)) idx_a = i;
    }
    for (elems_b, 0..) |e, i| {
        if (nregs[2].payload.bits == @intFromPtr(&e.header)) idx_b = i;
    }
    try testing.expectEqual(idx_a, idx_b);
    try testing.expect(idx_a != null);
    // Every element's field matches between universes — the stores landed in the
    // same logical tables with the same values.
    for (elems_a, elems_b) |ea, eb| {
        const va = ea.get(key_val);
        const vb = eb.get(key_val);
        try testing.expectEqual(@intFromEnum(va.tag), @intFromEnum(vb.tag));
        try testing.expectEqual(va.payload.bits, vb.payload.bits);
    }
}

test "nativegen(doc22 A / Rule 0.5): scalar update before a dynamic table guard must not coalesce" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;

    // Regression pin for the coalescing-inventory fix (opMayExitInBody): a
    // coalescible int φ update (acc+1 at 11) ordered BEFORE a dynamic .heap-rooted
    // guard_table (12). Pre-fix, guard_table was missing from the exit inventory, so
    // the add coalesced into the home in place; the guard's mid-iteration exit then
    // flushed the UPDATED acc where tier-1a keeps the old one. The container holds a
    // STRING at one position: aload's TAG_HEAP check passes, guard_table fails.
    const s = try string.String.create(gpa, "not-a-table");
    defer s.destroy(gpa);

    const N: usize = 12;
    const STR_AT: usize = 5; // container[5] is the string
    var elems: [N]*table.Table = undefined;
    var built: usize = 0;
    defer for (elems[0..built]) |e| e.destroy(gpa);

    const container = try table.Table.create(gpa);
    defer container.destroy(gpa);
    for (0..N) |i| {
        if (i + 1 == STR_AT) {
            try container.set(gpa, Value.int(@intCast(i + 1)), Value.heap(&s.header));
            continue;
        }
        const e = try table.Table.create(gpa);
        elems[built] = e;
        built += 1;
        try container.set(gpa, Value.int(@intCast(i + 1)), Value.heap(&e.header));
    }
    try testing.expectEqual(arr.Lane.value, container.array.lane);

    // r0=container, r1=index, r2=acc. Per iteration: elem = container[index] (heap);
    // acc += 1; guard_table(elem) — fails at index==STR_AT AFTER the acc update.
    var consts = [_]Value{Value.int(1)};
    var full = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: container
        .{ .op = .guard_table, .a = 0 }, // 1
        .{ .op = .guard_lane, .a = 0, .aux = VALUE_LANE }, // 2
        .{ .op = .slot_load, .aux = 1 }, // 3: index
        .{ .op = .guard_int, .a = 3 }, // 4
        .{ .op = .aref, .a = 0, .b = 3, .aux = VALUE_LANE }, // 5
        .{ .op = .guard_bounds, .a = 5 }, // 6
        .{ .op = .aload, .a = 5, .aux = VALUE_LANE, .ty = .heap }, // 7: elem (string OK)
        .{ .op = .slot_load, .aux = 2 }, // 8: acc
        .{ .op = .guard_int, .a = 8 }, // 9
        .{ .op = .konst, .aux = 0 }, // 10: 1
        .{ .op = .add, .a = 8, .b = 10, .ty = .int }, // 11: acc + 1 — coalescing candidate
        .{ .op = .guard_table, .a = 7 }, // 12: DYNAMIC exit after the update
        .{ .op = .add, .a = 3, .b = 10, .ty = .int }, // 13: index + 1
        .{ .op = .phi, .b = 13, .aux = 1 },
        .{ .op = .phi, .b = 11, .aux = 2 },
        .{ .op = .loop }, // 16
    };
    var es = [_]u16{};
    const tr = Trace{ .anchor = undefined, .instrs = &full, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };

    // Fails on iteration STR_AT-1: acc must be the value as of the LAST back edge.
    try expectMatch(&tr, &.{ Value.heap(&container.header), Value.int(1), Value.int(0) });
    // Fails on iteration 0 (entry index == STR_AT): acc must stay the entry value.
    try expectMatch(&tr, &.{ Value.heap(&container.header), Value.int(@intCast(STR_AT)), Value.int(100) });
    // Clean run to bounds-exit (no string hit): starts past the string.
    try expectMatch(&tr, &.{ Value.heap(&container.header), Value.int(@intCast(STR_AT + 1)), Value.int(0) });
}

test "nativegen(doc22 A): array op rooted at a carried-heap slot bails (fail-closed)" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;

    // Phase A supports HASH facts through a carried root, not ARRAY facts: aref/
    // guard_lane root their hoisted base-pointer analyses at the slot, which for a
    // per-iteration table would freeze iteration 0's array base. The structural
    // scan must decline the whole trace. (Test 1 is the positive control that the
    // carried-heap slot itself compiles — this bail is attributable to the array op.)
    const container = try table.Table.create(gpa);
    defer container.destroy(gpa);
    const inner = try table.Table.create(gpa);
    defer inner.destroy(gpa);
    try container.set(gpa, Value.int(1), Value.heap(&inner.header));

    var consts = [_]Value{Value.int(1)};
    var full = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: container
        .{ .op = .guard_table, .a = 0 }, // 1
        .{ .op = .guard_lane, .a = 0, .aux = VALUE_LANE }, // 2
        .{ .op = .slot_load, .aux = 1 }, // 3: index
        .{ .op = .guard_int, .a = 3 }, // 4
        .{ .op = .slot_load, .aux = 2 }, // 5: bi — carried-heap
        .{ .op = .guard_table, .a = 5 }, // 6
        .{ .op = .guard_lane, .a = 5, .aux = VALUE_LANE }, // 7: rooted at carried slot → bail
        .{ .op = .aref, .a = 5, .b = 3, .aux = VALUE_LANE }, // 8: likewise
        .{ .op = .guard_bounds, .a = 8 }, // 9
        .{ .op = .aload, .a = 8, .aux = VALUE_LANE, .ty = .heap }, // 10: bi[index]
        .{ .op = .aref, .a = 0, .b = 3, .aux = VALUE_LANE }, // 11
        .{ .op = .guard_bounds, .a = 11 }, // 12
        .{ .op = .aload, .a = 11, .aux = VALUE_LANE, .ty = .heap }, // 13: next bi
        .{ .op = .konst, .aux = 0 }, // 14: 1
        .{ .op = .add, .a = 3, .b = 14, .ty = .int }, // 15: index + 1
        .{ .op = .phi, .b = 15, .aux = 1 },
        .{ .op = .phi, .b = 13, .aux = 2 }, // carried-heap φ
        .{ .op = .loop }, // 18
    };
    var es = [_]u16{};
    const tr = Trace{ .anchor = undefined, .instrs = &full, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };
    try expectBail(&tr);
}

// ---------------------------------------------------------------------------
// Doc 22 §A.1b/§B.4 (Phase B-i): the page-owned SeedPlan.
// ---------------------------------------------------------------------------

/// B-ii made `compileImpl` fail-closed: a non-empty plan with no seed ctx bails.
/// The plan-inspection pins below never RUN their pages, so a stub ctx whose
/// `seed_fn` unconditionally reports success is enough to let the compile
/// proceed (the prologue bakes `&dummy_seed_ctx`, which is file-static and
/// outlives the page).
fn dummySeedFn(ctx: *const trace.NativeSeedCtx, t: *const Trace, plan_bits: u64) callconv(.c) u64 {
    _ = ctx;
    _ = t;
    _ = plan_bits;
    return trace.NativeSeedCtx.SEED_OK;
}
var dummy_seed_ctx = trace.NativeSeedCtx{ .seed_fn = &dummySeedFn };

test "nativegen(doc22 B-i): dynamic-rooted href DEACTIVATES its hash_cell seed; upvalue/global stay active" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;

    // The carried-heap READ shape: its href (idx 8, aux=4) roots at the carried
    // slot 2, so it lowers to the per-iteration resolveHashCell callout and never
    // reads seeded slab slot 4 — the matching hash_cell seed must be INACTIVE.
    // An upvalue seed on the same trace is consumed by ordinary slot_loads and
    // stays active regardless.
    const key = try string.String.create(gpa, "v");
    defer key.destroy(gpa);

    var consts: [2]Value = undefined;
    var full: [CARRIED_READ_LEN]I = undefined;
    carriedReadIr(&consts, &full);
    consts[0] = Value.heap(&key.header);
    var es = [_]u16{};

    // (a) hash_cell seed alone → an EMPTY plan (this page seeds nothing at entry,
    //     even though `inputs.len == 1` — the §B.4 "never raw inputs.len" pin).
    var ins_hash = [_]trace.InputSeed{
        .{ .kind = .hash_cell, .source = 0, .slot = 4, .table_reg = 2, .expected_count = 1 },
    };
    const tr_hash = Trace{ .anchor = undefined, .instrs = &full, .consts = &consts, .entry_slots = &es, .entry_guards = &.{}, .inputs = &ins_hash };
    var ct_hash = compile(gpa, &tr_hash, 0) orelse return error.NativeBailedUnexpectedly;
    defer ct_hash.deinit();
    try testing.expect(!ct_hash.seed_plan.isActive(0));
    try testing.expect(!ct_hash.seed_plan.nonEmpty());

    // (b) hash_cell + upvalue → only the upvalue bit set.
    var ins_mixed = [_]trace.InputSeed{
        .{ .kind = .hash_cell, .source = 0, .slot = 4, .table_reg = 2, .expected_count = 1 },
        .{ .kind = .upvalue, .source = 0, .slot = 30 },
    };
    const tr_mixed = Trace{ .anchor = undefined, .instrs = &full, .consts = &consts, .entry_slots = &es, .entry_guards = &.{}, .inputs = &ins_mixed };
    var ct_mixed = nativegen.compileSeeded(gpa, &tr_mixed, 0, &dummy_seed_ctx) orelse return error.NativeBailedUnexpectedly;
    defer ct_mixed.deinit();
    try testing.expect(!ct_mixed.seed_plan.isActive(0));
    try testing.expect(ct_mixed.seed_plan.isActive(1));
    try testing.expect(ct_mixed.seed_plan.nonEmpty());
}

test "nativegen(doc22 B-i): static-rooted href keeps its hash_cell seed ACTIVE" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;

    // The classic H1 static shape (lowering-test win2(H1)): the href roots at a
    // guard_table-covered, non-φ'd slot 0 (`.ptr`, loop-invariant), so it lowers
    // to the seeded slab read `[rsi + aux*8]` — the matching seed must be ACTIVE.
    const kt = try table.Table.create(gpa);
    defer kt.destroy(gpa);
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: table (static root)
        .{ .op = .guard_table, .a = 0 }, // 1
        .{ .op = .konst, .aux = 0 }, // 2: key
        .{ .op = .slot_load, .aux = 1 }, // 3: acc
        .{ .op = .guard_int, .a = 3 }, // 4
        .{ .op = .konst, .aux = 1 }, // 5: 1
        .{ .op = .add, .a = 3, .b = 5, .ty = .int }, // 6: acc + 1
        .{ .op = .href, .a = 0, .b = 2, .aux = 3 }, // 7: STATIC → seeded slot 3
        .{ .op = .guard_hash, .a = 7 }, // 8
        .{ .op = .hload, .a = 7, .ty = .int }, // 9
        .{ .op = .phi, .b = 6, .aux = 1 }, // acc carry
        .{ .op = .phi, .b = 9, .aux = 2 }, // lastseen carry
        .{ .op = .loop }, // 12
    };
    var consts = [_]Value{ Value.heap(&kt.header), Value.int(1) };
    var es = [_]u16{};
    var ins = [_]trace.InputSeed{
        .{ .kind = .hash_cell, .source = 0, .slot = 3, .table_reg = 0, .expected_count = 0 },
    };
    const tr = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .entry_guards = &.{}, .inputs = &ins };
    var ct = nativegen.compileSeeded(gpa, &tr, 0, &dummy_seed_ctx) orelse return error.NativeBailedUnexpectedly;
    defer ct.deinit();
    try testing.expect(ct.seed_plan.isActive(0));
    try testing.expect(ct.seed_plan.nonEmpty());
}

test "nativegen(doc22 B-i): more inputs than the plan can name bails the compile (fail closed)" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;

    const kt = try table.Table.create(gpa);
    defer kt.destroy(gpa);
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: table
        .{ .op = .guard_table, .a = 0 }, // 1
        .{ .op = .konst, .aux = 0 }, // 2: key
        .{ .op = .href, .a = 0, .b = 2, .aux = 3 }, // 3
        .{ .op = .guard_hash, .a = 3 }, // 4
        .{ .op = .hload, .a = 3, .ty = .int }, // 5
        .{ .op = .phi, .b = 5, .aux = 1 },
        .{ .op = .loop },
    };
    var consts = [_]Value{Value.heap(&kt.header)};
    var es = [_]u16{};
    var ins: [65]trace.InputSeed = undefined;
    for (&ins) |*seed| seed.* = .{ .kind = .upvalue, .source = 0, .slot = 30 };
    const tr = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .entry_guards = &.{}, .inputs = &ins };
    try testing.expect(compile(gpa, &tr, 0) == null);
}

// ---------------------------------------------------------------------------
// Doc 22 §B.2 (Phase B-ii): the seeded entry prologue + decline exits.
// ---------------------------------------------------------------------------

/// Instrumented seed twin: records the call, optionally writes the seeded slab
/// slot through test-global lane pointers (the callout receives only ctx/t/
/// plan_bits — production reaches the slab via `ctx.vm`, the test via these),
/// and returns whatever the test staged. File-static so `&env_seed_ctx` bakes
/// as a stable imm64 in the prologue.
const SeedEnv = struct {
    tags: ?[*]u8 = null,
    pays: ?[*]u64 = null,
    slot: usize = 0,
    cell_bits: u64 = 0,
    ret: u64 = trace.NativeSeedCtx.SEED_OK,
    calls: usize = 0,
    last_plan_bits: u64 = 0,
};
var seed_env: SeedEnv = .{};

fn envSeedFn(ctx: *const trace.NativeSeedCtx, t: *const Trace, plan_bits: u64) callconv(.c) u64 {
    _ = ctx;
    _ = t;
    seed_env.calls += 1;
    seed_env.last_plan_bits = plan_bits;
    if (seed_env.ret == trace.NativeSeedCtx.SEED_OK) {
        seed_env.tags.?[seed_env.slot] = @intFromEnum(value.Tag.int);
        seed_env.pays.?[seed_env.slot] = seed_env.cell_bits;
    }
    return seed_env.ret;
}
var env_seed_ctx = trace.NativeSeedCtx{ .seed_fn = &envSeedFn };

/// The canonical seeded RUN shape: a bounded H1 accumulation loop whose href
/// (idx 11, aux=4) roots statically at slot 0, so the page reads seeded slab
/// slot 4. Slots: 0=table, 1=i, 2=limit, 3=acc, 4=seeded cell (dead scratch).
const SEEDED_RUN_LEN = 20;
fn seededRunIr(out: *[SEEDED_RUN_LEN]I) void {
    out.* = .{
        .{ .op = .slot_load, .aux = 0 }, // 0: table (static root)
        .{ .op = .guard_table, .a = 0 }, // 1
        .{ .op = .konst, .aux = 0 }, // 2: key
        .{ .op = .slot_load, .aux = 1 }, // 3: i
        .{ .op = .guard_int, .a = 3 }, // 4
        .{ .op = .slot_load, .aux = 2 }, // 5: limit
        .{ .op = .guard_int, .a = 5 }, // 6
        .{ .op = .lt, .a = 3, .b = 5 }, // 7: i < limit
        .{ .op = .guard_true, .a = 7 }, // 8
        .{ .op = .konst, .aux = 1 }, // 9: 1
        .{ .op = .add, .a = 3, .b = 9, .ty = .int }, // 10: i + 1
        .{ .op = .href, .a = 0, .b = 2, .aux = 4 }, // 11: STATIC → seeded slot 4
        .{ .op = .guard_hash, .a = 11, .aux = 1 }, // 12: count == 1
        .{ .op = .hload, .a = 11, .ty = .int }, // 13: field
        .{ .op = .slot_load, .aux = 3 }, // 14: acc
        .{ .op = .guard_int, .a = 14 }, // 15
        .{ .op = .add, .a = 14, .b = 13, .ty = .int }, // 16: acc + field
        .{ .op = .phi, .b = 10, .aux = 1 }, // i carry
        .{ .op = .phi, .b = 16, .aux = 3 }, // acc carry
        .{ .op = .loop }, // 19
    };
}

test "nativegen(doc22 B-ii): SEED_OK — prologue calls seed_fn once with the plan bits; seeded page matches the oracle" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;

    const kt = try table.Table.create(gpa);
    defer kt.destroy(gpa);
    try kt.set(gpa, Value.int(99), Value.int(7));

    var consts = [_]Value{ Value.int(99), Value.int(1) };
    var full: [SEEDED_RUN_LEN]I = undefined;
    seededRunIr(&full);
    var es = [_]u16{};
    var ins = [_]trace.InputSeed{
        .{ .kind = .hash_cell, .source = 0, .slot = 4, .table_reg = 0, .expected_count = 1 },
    };
    const tr = Trace{ .anchor = undefined, .instrs = &full, .consts = &consts, .entry_slots = &es, .entry_guards = &.{}, .inputs = &ins };
    var ct = nativegen.compileSeeded(gpa, &tr, 0, &env_seed_ctx) orelse return error.NativeBailedUnexpectedly;
    defer ct.deinit();
    try testing.expect(ct.seed_plan.isActive(0));

    // Oracle (tier-1a): resolves the field from the href operands via `Table.get`
    // and never reads the seeded scratch slot — its slot 4 stays the initial value.
    const regs_init = [_]Value{ Value.heap(&kt.header), Value.int(0), Value.int(4), Value.int(0), Value.int(0) };
    const iregs = try gpa.dupe(Value, &regs_init);
    defer gpa.free(iregs);
    const ivalues = try gpa.alloc(Value, full.len);
    defer gpa.free(ivalues);
    const iresult = irinterp.executeValues(&tr, iregs, ivalues);
    try testing.expectEqual(@as(usize, 4), iresult.completed); // sanity: the loop really runs

    // Native: lanes we own, so the seed stub can write slab slot 4 with the true
    // cell pointer (the test twin of `nativeSeedFn`'s hash_cell resolution).
    const tags = try gpa.alloc(u8, regs_init.len);
    defer gpa.free(tags);
    const pays = try gpa.alloc(u64, regs_init.len);
    defer gpa.free(pays);
    for (regs_init, 0..) |v, i| {
        tags[i] = @intFromEnum(v.tag);
        pays[i] = v.payload.bits;
    }
    const cell = kt.fieldPtr(Value.int(99)).?;
    seed_env = .{ .tags = tags.ptr, .pays = pays.ptr, .slot = 4, .cell_bits = @intFromPtr(cell) };
    const nresult = ct.run(RegWindow.of(tags, pays));

    try testing.expectEqual(@as(usize, 1), seed_env.calls); // exactly one entry callout
    try testing.expectEqual(ct.seed_plan.bits, seed_env.last_plan_bits); // baked by value
    try testing.expectEqual(iresult.completed, nresult.completed);
    // Slots 0..3 must match the oracle bit-for-bit. Slot 4 is the seeded scratch:
    // native holds the raw cell pointer, the oracle its untouched initial — excluded.
    for (0..4) |i| {
        try testing.expectEqual(@intFromEnum(iregs[i].tag), tags[i]);
        try testing.expectEqual(iregs[i].payload.bits, pays[i]);
    }
}

test "nativegen(doc22 B-ii): SEED_HASH_DECLINE — terminal before the body, regs untouched" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;

    const kt = try table.Table.create(gpa);
    defer kt.destroy(gpa);
    try kt.set(gpa, Value.int(99), Value.int(7));

    var consts = [_]Value{ Value.int(99), Value.int(1) };
    var full: [SEEDED_RUN_LEN]I = undefined;
    seededRunIr(&full);
    var es = [_]u16{};
    var ins = [_]trace.InputSeed{
        .{ .kind = .hash_cell, .source = 0, .slot = 4, .table_reg = 0, .expected_count = 1 },
    };
    const tr = Trace{ .anchor = undefined, .instrs = &full, .consts = &consts, .entry_slots = &es, .entry_guards = &.{}, .inputs = &ins };
    var ct = nativegen.compileSeeded(gpa, &tr, 0, &env_seed_ctx) orelse return error.NativeBailedUnexpectedly;
    defer ct.deinit();

    const regs_init = [_]Value{ Value.heap(&kt.header), Value.int(0), Value.int(4), Value.int(0), Value.int(0) };
    const tags = try gpa.alloc(u8, regs_init.len);
    defer gpa.free(tags);
    const pays = try gpa.alloc(u64, regs_init.len);
    defer gpa.free(pays);
    for (regs_init, 0..) |v, i| {
        tags[i] = @intFromEnum(v.tag);
        pays[i] = v.payload.bits;
    }
    seed_env = .{ .ret = trace.NativeSeedCtx.SEED_HASH_DECLINE };
    var ledger: [trace_exec.LEDGER_CAP]trace_exec.LedgerEntry = undefined;
    const r = ct.runCapturingLedger(RegWindow.of(tags, pays), &ledger, .{});

    try testing.expectEqual(@as(usize, 1), seed_env.calls);
    try testing.expectEqual(@as(usize, 0), r.completed); // zero local progress
    try testing.expectEqual(trace_exec.ExitReason.seed_hash_decline, r.exit_reason);
    try testing.expectEqual(std.math.maxInt(u32), r.exit_instr); // like prologue_fail
    try testing.expectEqual(@as(u32, 1), r.ledger_len); // one terminal row
    try testing.expectEqual(trace_exec.LedgerKind.seed_hash_decline, ledger[0].kind);
    try testing.expectEqual(@as(usize, 0), ledger[0].cum);
    // The body never ran: every lane bit is exactly the entry state.
    for (regs_init, 0..) |v, i| {
        try testing.expectEqual(@intFromEnum(v.tag), tags[i]);
        try testing.expectEqual(v.payload.bits, pays[i]);
    }
}

test "nativegen(doc22 B-ii): SEED_CAPACITY_DECLINE — and any out-of-grammar return fails closed to it" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;

    const kt = try table.Table.create(gpa);
    defer kt.destroy(gpa);
    try kt.set(gpa, Value.int(99), Value.int(7));

    var consts = [_]Value{ Value.int(99), Value.int(1) };
    var full: [SEEDED_RUN_LEN]I = undefined;
    seededRunIr(&full);
    var es = [_]u16{};
    var ins = [_]trace.InputSeed{
        .{ .kind = .hash_cell, .source = 0, .slot = 4, .table_reg = 0, .expected_count = 1 },
    };
    const tr = Trace{ .anchor = undefined, .instrs = &full, .consts = &consts, .entry_slots = &es, .entry_guards = &.{}, .inputs = &ins };
    var ct = nativegen.compileSeeded(gpa, &tr, 0, &env_seed_ctx) orelse return error.NativeBailedUnexpectedly;
    defer ct.deinit();

    const regs_init = [_]Value{ Value.heap(&kt.header), Value.int(0), Value.int(4), Value.int(0), Value.int(0) };
    const tags = try gpa.alloc(u8, regs_init.len);
    defer gpa.free(tags);
    const pays = try gpa.alloc(u64, regs_init.len);
    defer gpa.free(pays);

    // (a) the declared capacity decline.
    for (regs_init, 0..) |v, i| {
        tags[i] = @intFromEnum(v.tag);
        pays[i] = v.payload.bits;
    }
    seed_env = .{ .ret = trace.NativeSeedCtx.SEED_CAPACITY_DECLINE };
    var ledger: [trace_exec.LEDGER_CAP]trace_exec.LedgerEntry = undefined;
    const r = ct.runCapturingLedger(RegWindow.of(tags, pays), &ledger, .{});
    try testing.expectEqual(@as(usize, 0), r.completed);
    try testing.expectEqual(trace_exec.ExitReason.seed_capacity_decline, r.exit_reason);
    try testing.expectEqual(std.math.maxInt(u32), r.exit_instr);
    try testing.expectEqual(@as(u32, 1), r.ledger_len);
    try testing.expectEqual(trace_exec.LedgerKind.seed_capacity_decline, ledger[0].kind);
    for (regs_init, 0..) |v, i| {
        try testing.expectEqual(@intFromEnum(v.tag), tags[i]);
        try testing.expectEqual(v.payload.bits, pays[i]);
    }

    // (b) fail-closed: a return outside {OK, HASH, CAPACITY} routes to the
    // capacity exit (whose consumer — next-candidate — is sound for garbage).
    seed_env = .{ .ret = 77 };
    const rg = ct.runCapturingLedger(RegWindow.of(tags, pays), &ledger, .{});
    try testing.expectEqual(trace_exec.ExitReason.seed_capacity_decline, rg.exit_reason);
    try testing.expectEqual(@as(usize, 0), rg.completed);
}

test "nativegen(doc22 B-v §B.6): redundant-seed deactivation — a STALE hash seed excluded by the plan never blocks native entry, its slot stays unwritten" {
    // §B.6 row 7 ("redundant-seed deactivation"): the carried-heap READ shape
    // carries a hash_cell seed whose `expected_count` (99) can NEVER validate
    // (every element table has exactly one field). A page that CONSUMED the
    // seed would decline at every entry; `computeSeedPlan` deactivates it
    // instead (the href roots at the CARRIED slot), so the page must enter
    // natively, run to the oracle result, and leave the inactive slab slot
    // bit-for-bit at its entry value — the run-time proof of the compile-time
    // release-assert that the emitted body never reads an inactive seed slot.
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;

    const key = try string.String.create(gpa, "v");
    defer key.destroy(gpa);
    const key_val = Value.heap(&key.header);

    const N: usize = 8;
    var elems: [N]*table.Table = undefined;
    var built: usize = 0;
    defer for (elems[0..built]) |e| e.destroy(gpa);
    const container = try buildUniverse(gpa, key_val, &elems, &built);
    defer container.destroy(gpa);

    var consts: [2]Value = undefined;
    var full: [CARRIED_READ_LEN]I = undefined;
    carriedReadIr(&consts, &full);
    consts[0] = key_val;
    var es = [_]u16{};

    // (a) The stale seed ALONE → an EMPTY plan: no prologue, no callout, the
    // page enters unconditionally. `seed_env` stays null-laned so a spurious
    // callout would crash rather than pass silently.
    var ins_stale = [_]trace.InputSeed{
        .{ .kind = .hash_cell, .source = 0, .slot = 4, .table_reg = 2, .expected_count = 99 },
    };
    const tr_a = Trace{ .anchor = undefined, .instrs = &full, .consts = &consts, .entry_slots = &es, .entry_guards = &.{}, .inputs = &ins_stale };
    var ct_a = nativegen.compileSeeded(gpa, &tr_a, 0, &env_seed_ctx) orelse return error.NativeBailedUnexpectedly;
    defer ct_a.deinit();
    try testing.expect(!ct_a.seed_plan.nonEmpty());

    const regs_a = [_]Value{ Value.heap(&container.header), Value.int(1), Value.heap(&elems[N - 1].header), Value.int(0), Value.int(0) };
    const iregs_a = try gpa.dupe(Value, &regs_a);
    defer gpa.free(iregs_a);
    const ivalues = try gpa.alloc(Value, full.len);
    defer gpa.free(ivalues);
    const iresult_a = irinterp.executeValues(&tr_a, iregs_a, ivalues);
    try testing.expectEqual(@as(usize, N), iresult_a.completed); // sanity: the loop really runs

    const tags_a = try gpa.alloc(u8, regs_a.len);
    defer gpa.free(tags_a);
    const pays_a = try gpa.alloc(u64, regs_a.len);
    defer gpa.free(pays_a);
    for (regs_a, 0..) |v, i| {
        tags_a[i] = @intFromEnum(v.tag);
        pays_a[i] = v.payload.bits;
    }
    seed_env = .{};
    const nresult_a = ct_a.run(RegWindow.of(tags_a, pays_a));
    try testing.expectEqual(@as(usize, 0), seed_env.calls); // no prologue emitted
    try testing.expectEqual(iresult_a.completed, nresult_a.completed);
    for (0..4) |i| {
        try testing.expectEqual(@intFromEnum(iregs_a[i].tag), tags_a[i]);
        try testing.expectEqual(iregs_a[i].payload.bits, pays_a[i]);
    }
    // The inactive seed's slot: bit-for-bit the entry value — never written.
    try testing.expectEqual(@intFromEnum(regs_a[4].tag), tags_a[4]);
    try testing.expectEqual(regs_a[4].payload.bits, pays_a[4]);

    // (b) Stale seed + an active upvalue seed → a PARTIAL plan: the prologue
    // runs once with only the upvalue bit, the twin writes only the ACTIVE
    // slot, and the stale seed's slot again stays untouched.
    var ins_mixed = [_]trace.InputSeed{
        .{ .kind = .hash_cell, .source = 0, .slot = 4, .table_reg = 2, .expected_count = 99 },
        .{ .kind = .upvalue, .source = 0, .slot = 5 },
    };
    const tr_b = Trace{ .anchor = undefined, .instrs = &full, .consts = &consts, .entry_slots = &es, .entry_guards = &.{}, .inputs = &ins_mixed };
    var ct_b = nativegen.compileSeeded(gpa, &tr_b, 0, &env_seed_ctx) orelse return error.NativeBailedUnexpectedly;
    defer ct_b.deinit();
    try testing.expect(!ct_b.seed_plan.isActive(0));
    try testing.expect(ct_b.seed_plan.isActive(1));

    const regs_b = [_]Value{ Value.heap(&container.header), Value.int(1), Value.heap(&elems[N - 1].header), Value.int(0), Value.int(0), Value.int(0) };
    const tags_b = try gpa.alloc(u8, regs_b.len);
    defer gpa.free(tags_b);
    const pays_b = try gpa.alloc(u64, regs_b.len);
    defer gpa.free(pays_b);
    for (regs_b, 0..) |v, i| {
        tags_b[i] = @intFromEnum(v.tag);
        pays_b[i] = v.payload.bits;
    }
    seed_env = .{ .tags = tags_b.ptr, .pays = pays_b.ptr, .slot = 5, .cell_bits = 1234 };
    const nresult_b = ct_b.run(RegWindow.of(tags_b, pays_b));
    try testing.expectEqual(@as(usize, 1), seed_env.calls);
    try testing.expectEqual(ct_b.seed_plan.bits, seed_env.last_plan_bits); // bit 0 excluded
    try testing.expectEqual(iresult_a.completed, nresult_b.completed);
    for (0..4) |i| {
        try testing.expectEqual(@intFromEnum(iregs_a[i].tag), tags_b[i]);
        try testing.expectEqual(iregs_a[i].payload.bits, pays_b[i]);
    }
    // Inactive stale-seed slot 4: entry bits. Active upvalue slot 5: the
    // twin's write landed (proves the callout serviced the partial plan).
    try testing.expectEqual(@intFromEnum(regs_b[4].tag), tags_b[4]);
    try testing.expectEqual(regs_b[4].payload.bits, pays_b[4]);
    try testing.expectEqual(@intFromEnum(value.Tag.int), tags_b[5]);
    try testing.expectEqual(@as(u64, 1234), pays_b[5]);
}
