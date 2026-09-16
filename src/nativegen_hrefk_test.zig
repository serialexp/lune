//! Tests for `nativegen.zig` — doc 49: hrefk (inline constant-key hash-cell
//! resolution for dynamic-root `href`s).
//!
//! The shape under test is nbody's `b[i].x`: a per-iteration table (`.heap`
//! aload result, guard_table-covered) whose constant-string field access
//! recorded a LIVE `(slot, mask)` pin (`HrefAux.encode`). Native lowers the
//! `href` to inline mask/live-cell/key-tag/key-id guards + the cell address —
//! no `resolveHashCell` callout, no save frame.
//!
//! hrefk is deliberately MORE conservative than the tier-1a oracle: the oracle
//! re-resolves the cell by full probe every iteration, so a same-shape sibling
//! whose key sits at a DIFFERENT slot passes tier-1a but side-exits native.
//! `expectMatch` (which asserts identical exit points) therefore only fits the
//! agreement scenarios; the divergent ones drive `runNative` directly against
//! hand-computed exit state, with a parallel oracle run documenting the
//! divergence where it exists.
//!
//! Shared harness lives in `nativegen_testutil.zig`.

const nativegen = @import("nativegen.zig");
const std = @import("std");
const trace = @import("trace.zig");
const trace_ir = @import("trace_ir.zig");
const value = @import("value.zig");
const table = @import("table.zig");
const arr = @import("array.zig");
const string = @import("string.zig");
const hash_part = @import("hash_part.zig");
const Value = value.Value;
const Trace = @import("trace_code.zig").TraceCode;
const testing = std.testing;
const irinterp = @import("irinterp.zig");
const I = trace.IrInstr;

const VALUE_LANE = nativegen.VALUE_LANE;
const compile = nativegen.compile;
const is_x64_linux = nativegen.is_x64_linux;

const util = @import("nativegen_testutil.zig");
const expectBail = util.expectBail;
const expectMatch = util.expectMatch;
const runNative = util.runNative;

/// The hrefk READ loop (the nbody `acc = acc + b[i].x` shape), hand-built:
///   r0=container, r1=index, r2=acc.
///   per iteration: elem = container[index] ; acc += elem.<key> ; index += 1.
/// The `href` at 10 roots at the ALOAD result 7 (`.heap` kind — the only root
/// kind the prover admits a hrefk aux for) and carries the caller-provided
/// encoding in `aux`.
const READ_LEN = 21;
const READ_HREF_IDX = 10;
fn hrefkReadIr(full: *[READ_LEN]I, href_aux: i32, count_aux: i32) void {
    full.* = .{
        .{ .op = .slot_load, .aux = 0 }, // 0: container
        .{ .op = .guard_table, .a = 0 }, // 1
        .{ .op = .guard_lane, .a = 0, .aux = VALUE_LANE }, // 2
        .{ .op = .slot_load, .aux = 1 }, // 3: index
        .{ .op = .guard_int, .a = 3 }, // 4
        .{ .op = .aref, .a = 0, .b = 3, .aux = VALUE_LANE }, // 5
        .{ .op = .guard_bounds, .a = 5 }, // 6
        .{ .op = .aload, .a = 5, .aux = VALUE_LANE, .ty = .heap }, // 7: elem
        .{ .op = .guard_table, .a = 7 }, // 8: dynamic per-iteration
        .{ .op = .konst, .aux = 0 }, // 9: field key
        .{ .op = .href, .a = 7, .b = 9, .aux = href_aux }, // 10: hrefk
        .{ .op = .guard_hash, .a = 10, .aux = count_aux }, // 11
        .{ .op = .hload, .a = 10, .ty = .int }, // 12: elem.<key>
        .{ .op = .slot_load, .aux = 2 }, // 13: acc
        .{ .op = .guard_int, .a = 13 }, // 14
        .{ .op = .add, .a = 13, .b = 12, .ty = .int }, // 15: acc + v
        .{ .op = .konst, .aux = 1 }, // 16: 1
        .{ .op = .add, .a = 3, .b = 16, .ty = .int }, // 17: index + 1
        .{ .op = .phi, .b = 17, .aux = 1 }, // index carry
        .{ .op = .phi, .b = 15, .aux = 2 }, // acc carry
        .{ .op = .loop }, // 20
    };
}

/// The hrefk STORE (RMW) loop: elem = container[index] ; elem.<key> += 10.
const STORE_LEN = 20;
const STORE_HREF_IDX = 10;
fn hrefkStoreIr(full: *[STORE_LEN]I, href_aux: i32, count_aux: i32) void {
    full.* = .{
        .{ .op = .slot_load, .aux = 0 }, // 0: container
        .{ .op = .guard_table, .a = 0 }, // 1
        .{ .op = .guard_lane, .a = 0, .aux = VALUE_LANE }, // 2
        .{ .op = .slot_load, .aux = 1 }, // 3: index
        .{ .op = .guard_int, .a = 3 }, // 4
        .{ .op = .aref, .a = 0, .b = 3, .aux = VALUE_LANE }, // 5
        .{ .op = .guard_bounds, .a = 5 }, // 6
        .{ .op = .aload, .a = 5, .aux = VALUE_LANE, .ty = .heap }, // 7: elem
        .{ .op = .guard_table, .a = 7 }, // 8
        .{ .op = .konst, .aux = 0 }, // 9: key
        .{ .op = .href, .a = 7, .b = 9, .aux = href_aux }, // 10: hrefk
        .{ .op = .guard_hash, .a = 10, .aux = count_aux }, // 11
        .{ .op = .hload, .a = 10, .ty = .int }, // 12: v
        .{ .op = .konst, .aux = 1 }, // 13: 10
        .{ .op = .add, .a = 12, .b = 13, .ty = .int }, // 14: v + 10
        .{ .op = .hstore, .a = 10, .b = 14 }, // 15: elem.<key> = v + 10
        .{ .op = .konst, .aux = 2 }, // 16: 1
        .{ .op = .add, .a = 3, .b = 16, .ty = .int }, // 17: index + 1
        .{ .op = .phi, .b = 17, .aux = 1 }, // index carry
        .{ .op = .loop }, // 19
    };
}

/// Build the hrefk universe: a `.value`-lane container whose dense keys `1..n`
/// hold `n` DISTINCT single-field element tables `{ <key> = i }` — the same
/// creation history everywhere, so every element pins the SAME `(slot, mask)`
/// (the owned map's layout is a pure function of history; doc 49). Distinct
/// values make any cross-table cell confusion diverge immediately.
fn buildHrefkUniverse(
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

/// The `(slot, mask)` every element of a fresh single-field universe agrees on,
/// hrefk-encoded. Asserts the shape really is the min-capacity one.
fn universeAux(elem: *const table.Table, key_val: Value) !i32 {
    const sm = elem.hashSlotOf(key_val).?;
    try testing.expectEqual(@as(u32, 3), sm.mask); // min capacity 4
    return trace_ir.HrefAux.encode(sm.slot, sm.mask).?;
}

/// Heap identity — hashing AND `Value.eql` — goes by stable `GcHeader.id`
/// (docs/design/02): raw `String.create` outside the heap leaves `id = 0`, so
/// a test with more than one heap key MUST assign distinct ids itself (the
/// heap's allocation-order job). This helper picks an id `>= start_id` whose
/// home slot under `mask` does (or does not) equal `target`, writing it into
/// `s` — the test's way of constructing colliding / non-colliding keys.
fn assignIdWithSlot(
    s: *string.String,
    start_id: u32,
    mask: u32,
    target: u32,
    comptime want_equal: bool,
) !void {
    var id: u32 = start_id;
    while (id < start_id + 4096) : (id += 1) {
        s.header.id = id;
        const slot: u32 = @intCast(hash_part.keyHash(Value.heap(&s.header)) & mask);
        if ((slot == target) == want_equal) return;
    }
    return error.TestNoSuchId; // 4096 misses at mask<=3: impossible
}

test "nativegen(doc49): hrefk read loop matches the interpreter across distinct same-shape tables" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;

    const key = try string.String.create(gpa, "v");
    defer key.destroy(gpa);
    const key_val = Value.heap(&key.header);

    const N: usize = 32;
    var elems: [N]*table.Table = undefined;
    var built: usize = 0;
    defer for (elems[0..built]) |e| e.destroy(gpa);
    const container = try buildHrefkUniverse(gpa, key_val, &elems, &built);
    defer container.destroy(gpa);

    // All N distinct tables pin the SAME (slot, mask) — the loop-varying-root
    // property hrefk exists for.
    const aux = try universeAux(elems[0], key_val);
    for (elems) |e| {
        const sm = e.hashSlotOf(key_val).?;
        try testing.expectEqual(aux, trace_ir.HrefAux.encode(sm.slot, sm.mask).?);
    }

    var consts = [_]Value{ key_val, Value.int(1) };
    var full: [READ_LEN]I = undefined;
    hrefkReadIr(&full, aux, 1);
    var es = [_]u16{};
    const tr = Trace{ .anchor = undefined, .instrs = &full, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };

    // Full scan: sums a different table's field every iteration, bounds-exits
    // past N — the hrefk guards must pass on all 32 DISTINCT tables.
    try expectMatch(&tr, &.{ Value.heap(&container.header), Value.int(1), Value.int(0) });
    // Start mid-run.
    try expectMatch(&tr, &.{ Value.heap(&container.header), Value.int(20), Value.int(5) });
    // Start past the run: guard_bounds exits on iteration 0.
    try expectMatch(&tr, &.{ Value.heap(&container.header), Value.int(@intCast(N + 5)), Value.int(100) });
}

test "nativegen(doc49): hrefk read agrees with the oracle on a non-table element (guard_table exit)" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;

    // container[STR_AT] holds a STRING: the aload's TAG_HEAP check passes,
    // guard_table fails — BEFORE the hrefk guards, in both tiers, at the same
    // instruction. Pins that hrefk changed nothing upstream of it.
    const key = try string.String.create(gpa, "v");
    defer key.destroy(gpa);
    const key_val = Value.heap(&key.header);
    const s = try string.String.create(gpa, "not-a-table");
    defer s.destroy(gpa);

    const N: usize = 12;
    const STR_AT: i64 = 5;
    var elems: [N]*table.Table = undefined;
    var built: usize = 0;
    defer for (elems[0..built]) |e| e.destroy(gpa);
    const container = try buildHrefkUniverse(gpa, key_val, &elems, &built);
    defer container.destroy(gpa);
    const aux = try universeAux(elems[0], key_val);
    try container.set(gpa, Value.int(STR_AT), Value.heap(&s.header));

    var consts = [_]Value{ key_val, Value.int(1) };
    var full: [READ_LEN]I = undefined;
    hrefkReadIr(&full, aux, 1);
    var es = [_]u16{};
    const tr = Trace{ .anchor = undefined, .instrs = &full, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };

    // Hits the string on iteration STR_AT-1 (mid-run exit after clean prefix).
    try expectMatch(&tr, &.{ Value.heap(&container.header), Value.int(1), Value.int(0) });
    // Hits it on iteration 0: entry state must be flushed untouched.
    try expectMatch(&tr, &.{ Value.heap(&container.header), Value.int(STR_AT), Value.int(7) });
}

test "nativegen(doc49): hrefk store writes the CURRENT table (two disjoint universes)" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;

    // The nbody writeback shape through the hrefk cell. A stale-cell bug
    // corrupts the wrong table's field, so run oracle and native on two
    // IDENTICAL, DISJOINT universes and compare field-by-field.
    const key = try string.String.create(gpa, "v");
    defer key.destroy(gpa);
    const key_val = Value.heap(&key.header);

    const N: usize = 24;
    var elems_a: [N]*table.Table = undefined;
    var built_a: usize = 0;
    defer for (elems_a[0..built_a]) |e| e.destroy(gpa);
    const cont_a = try buildHrefkUniverse(gpa, key_val, &elems_a, &built_a);
    defer cont_a.destroy(gpa);

    var elems_b: [N]*table.Table = undefined;
    var built_b: usize = 0;
    defer for (elems_b[0..built_b]) |e| e.destroy(gpa);
    const cont_b = try buildHrefkUniverse(gpa, key_val, &elems_b, &built_b);
    defer cont_b.destroy(gpa);

    // Two universes created back-to-back: element ids differ, so their
    // (slot, mask) pins MAY differ — encode per-universe and require the
    // native run's universe B to be self-consistent.
    const aux_b = try universeAux(elems_b[0], key_val);
    for (elems_b) |e| {
        const sm = e.hashSlotOf(key_val).?;
        try testing.expectEqual(aux_b, trace_ir.HrefAux.encode(sm.slot, sm.mask).?);
    }

    var consts = [_]Value{ key_val, Value.int(10), Value.int(1) };
    var full: [STORE_LEN]I = undefined;
    hrefkStoreIr(&full, aux_b, 1);
    var es = [_]u16{};
    const tr = Trace{ .anchor = undefined, .instrs = &full, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };

    // Oracle on universe A (it ignores the aux and re-resolves per iteration,
    // so A's possibly-different slot layout is irrelevant to it).
    const iregs = try gpa.dupe(Value, &.{ Value.heap(&cont_a.header), Value.int(1) });
    defer gpa.free(iregs);
    const values = try gpa.alloc(Value, tr.instrs.len);
    defer gpa.free(values);
    const iresult = irinterp.executeValues(&tr, iregs, values);
    try testing.expectEqual(@as(usize, N), iresult.completed); // sanity: full scan

    // Native on universe B.
    var ct = compile(gpa, &tr, 0) orelse return error.NativeBailedUnexpectedly;
    defer ct.deinit();
    const nregs = try gpa.dupe(Value, &.{ Value.heap(&cont_b.header), Value.int(1) });
    defer gpa.free(nregs);
    const nresult = try runNative(ct, nregs);

    try testing.expectEqual(iresult.completed, nresult.local_completed);
    try testing.expectEqual(@intFromEnum(iregs[1].tag), @intFromEnum(nregs[1].tag));
    try testing.expectEqual(iregs[1].payload.bits, nregs[1].payload.bits);
    // Every element's field matches between universes: each store landed in
    // its OWN iteration's table, through the hrefk cell.
    for (elems_a, elems_b) |ea, eb| {
        const va = ea.get(key_val);
        const vb = eb.get(key_val);
        try testing.expectEqual(@intFromEnum(va.tag), @intFromEnum(vb.tag));
        try testing.expectEqual(va.payload.bits, vb.payload.bits);
    }
}

test "nativegen(doc49): hrefk key-id guard exits on a same-shape sibling with swapped slot layout; the oracle passes" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;

    // THE conservative-divergence pin. Two keys that COLLIDE under mask 3:
    // canonical elements insert (filler, key) — key probes to slot s+1;
    // the sibling at SWAP inserts (key, filler) — key sits at slot s. Same
    // mask, same live count, same field set: tier-1a (full probe + count
    // check) passes and completes all N iterations; native's key-id guard at
    // the pinned slot finds the FILLER's id and side-exits at iteration SWAP.
    // A spurious exit is safe under coarse deopt — this test pins exactly
    // where it lands and that the flushed state is the last back edge's.
    const key = try string.String.create(gpa, "v");
    defer key.destroy(gpa);
    key.header.id = 1;
    const key_val = Value.heap(&key.header);
    const kv_slot: u32 = @intCast(hash_part.keyHash(key_val) & 3);

    // A DISTINCT key (different id) that COLLIDES with `v` under mask 3.
    const filler = try string.String.create(gpa, "f");
    defer filler.destroy(gpa);
    try assignIdWithSlot(filler, 1000, 3, kv_slot, true);
    const filler_val = Value.heap(&filler.header);

    const N: usize = 8;
    const SWAP: usize = 3;
    var elems: [N]*table.Table = undefined;
    var built: usize = 0;
    defer for (elems[0..built]) |e| e.destroy(gpa);
    const container = try table.Table.create(gpa);
    defer container.destroy(gpa);
    for (0..N) |i| {
        const e = try table.Table.create(gpa);
        elems[i] = e;
        built += 1;
        if (i == SWAP) {
            try e.set(gpa, key_val, Value.int(@intCast(i + 1)));
            try e.set(gpa, filler_val, Value.int(0));
        } else {
            try e.set(gpa, filler_val, Value.int(0));
            try e.set(gpa, key_val, Value.int(@intCast(i + 1)));
        }
        try container.set(gpa, Value.int(@intCast(i + 1)), Value.heap(&e.header));
    }
    try testing.expectEqual(arr.Lane.value, container.array.lane);

    // The collision really produced two layouts of the same shape.
    const canon = elems[0].hashSlotOf(key_val).?;
    const swapped = elems[SWAP].hashSlotOf(key_val).?;
    try testing.expectEqual(canon.mask, swapped.mask);
    try testing.expect(canon.slot != swapped.slot);
    const aux = trace_ir.HrefAux.encode(canon.slot, canon.mask).?;

    var consts = [_]Value{ key_val, Value.int(1) };
    var full: [READ_LEN]I = undefined;
    hrefkReadIr(&full, aux, 2); // two live keys per element
    var es = [_]u16{};
    const tr = Trace{ .anchor = undefined, .instrs = &full, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };

    // Oracle: completes ALL N iterations — the sibling is semantically fine.
    const iregs = try gpa.dupe(Value, &.{ Value.heap(&container.header), Value.int(1), Value.int(0) });
    defer gpa.free(iregs);
    const values = try gpa.alloc(Value, tr.instrs.len);
    defer gpa.free(values);
    const iresult = irinterp.executeValues(&tr, iregs, values);
    try testing.expectEqual(@as(usize, N), iresult.completed);

    // Native: iterations 0..SWAP-1 pass on the canonical layout, then the
    // key-id guard at the href exits mid-iteration SWAP. Homes hold the last
    // back edge's state: index = 1+SWAP, acc = sum(1..SWAP).
    var ct = compile(gpa, &tr, 0) orelse return error.NativeBailedUnexpectedly;
    defer ct.deinit();
    var nregs = [_]Value{ Value.heap(&container.header), Value.int(1), Value.int(0) };
    const nresult = try runNative(ct, &nregs);
    try testing.expectEqual(@as(usize, SWAP), nresult.local_completed);
    try testing.expectEqual(@as(u32, READ_HREF_IDX), nresult.exit_instr);
    try testing.expectEqual(@intFromEnum(value.Tag.int), @intFromEnum(nregs[1].tag));
    try testing.expectEqual(@as(i64, 1 + SWAP), nregs[1].asInt());
    try testing.expectEqual(@as(i64, SWAP * (SWAP + 1) / 2), nregs[2].asInt());
}

test "nativegen(doc49): hrefk live-cell guard rejects a DEAD node before any key deref or store" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;

    // The codex round-1 soundness case. Element M recorded shape { v = 99 };
    // then `v` was DELETED and an unrelated key `u` inserted: `live` and
    // `mask` are back to the recorded values, but v's node is DEAD (nil
    // value, id-bits key payload — NOT a pointer). A store-only chain whose
    // guards missed liveness would write through the dead cell, corrupting
    // `live` accounting; worse, the key-id guard would deref id bits. The
    // live-cell guard must exit FIRST, at iteration 0, touching nothing.
    const key = try string.String.create(gpa, "v");
    defer key.destroy(gpa);
    key.header.id = 1;
    const key_val = Value.heap(&key.header);
    const kv_slot: u32 = @intCast(hash_part.keyHash(key_val) & 3);

    // Unrelated key (distinct id) at a DIFFERENT slot, so its insert neither
    // reuses v's dead node nor changes the mask.
    const u = try string.String.create(gpa, "u");
    defer u.destroy(gpa);
    try assignIdWithSlot(u, 1000, 3, kv_slot, false);
    const u_val = Value.heap(&u.header);

    const M = try table.Table.create(gpa);
    defer M.destroy(gpa);
    try M.set(gpa, key_val, Value.int(99)); // recorded shape…
    const rec = M.hashSlotOf(key_val).?;
    const aux = trace_ir.HrefAux.encode(rec.slot, rec.mask).?;
    try M.set(gpa, key_val, Value.nil()); // …then delete v (dead node)…
    try M.set(gpa, u_val, Value.int(42)); // …and insert an unrelated key.
    try testing.expectEqual(rec.mask, M.hash.mask); // mask unchanged
    try testing.expectEqual(@as(u32, 1), M.hash.live); // count restored
    try testing.expect(M.hashSlotOf(key_val) == null); // v really dead
    try testing.expect(M.hashSlotOf(u_val).?.slot != rec.slot); // fresh node

    // A second, intact element behind M: if the guard wrongly passed, the
    // loop would keep going and mutate it — completed would exceed 0.
    const ok_elem = try table.Table.create(gpa);
    defer ok_elem.destroy(gpa);
    try ok_elem.set(gpa, key_val, Value.int(7));

    const container = try table.Table.create(gpa);
    defer container.destroy(gpa);
    try container.set(gpa, Value.int(1), Value.heap(&M.header));
    try container.set(gpa, Value.int(2), Value.heap(&ok_elem.header));

    var consts = [_]Value{ key_val, Value.int(10), Value.int(1) };
    var full: [STORE_LEN]I = undefined;
    hrefkStoreIr(&full, aux, 1);
    var es = [_]u16{};
    const tr = Trace{ .anchor = undefined, .instrs = &full, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };

    var ct = compile(gpa, &tr, 0) orelse return error.NativeBailedUnexpectedly;
    defer ct.deinit();
    var nregs = [_]Value{ Value.heap(&container.header), Value.int(1) };
    const nresult = try runNative(ct, &nregs);

    // Exited at the href, iteration 0, entry state flushed untouched.
    try testing.expectEqual(@as(usize, 0), nresult.local_completed);
    try testing.expectEqual(@as(u32, STORE_HREF_IDX), nresult.exit_instr);
    try testing.expectEqual(@as(i64, 1), nregs[1].asInt());
    // M is byte-for-byte what the mutation left: no store landed, no
    // resurrection, `live` accounting intact.
    try testing.expect(M.get(key_val).isNil());
    try testing.expectEqual(@as(i64, 42), M.get(u_val).asInt());
    try testing.expectEqual(@as(u32, 1), M.hash.live);
    try testing.expectEqual(@as(i64, 7), ok_elem.get(key_val).asInt());
}

test "nativegen(doc49): hrefk mask guard exits on a rehashed table and on an empty hash part" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;

    const key = try string.String.create(gpa, "v");
    defer key.destroy(gpa);
    key.header.id = 1;
    const key_val = Value.heap(&key.header);

    // (a) Rehashed: recorded at mask 3, then grown past the load limit.
    const R = try table.Table.create(gpa);
    defer R.destroy(gpa);
    try R.set(gpa, key_val, Value.int(7));
    const rec = R.hashSlotOf(key_val).?;
    try testing.expectEqual(@as(u32, 3), rec.mask);
    const aux = trace_ir.HrefAux.encode(rec.slot, rec.mask).?;
    var fillers: [3]*string.String = undefined;
    var made: usize = 0;
    defer for (fillers[0..made]) |f| f.destroy(gpa);
    for (0..3) |i| {
        var buf: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&buf, "g{d}", .{i});
        fillers[i] = try string.String.create(gpa, name);
        made += 1;
        fillers[i].header.id = @intCast(100 + i); // distinct heap identities
        try R.set(gpa, Value.heap(&fillers[i].header), Value.int(0));
    }
    try testing.expect(R.hash.mask != rec.mask); // really rehashed

    // (b) Fresh empty table: hash part never allocated — mask 0, nodes null.
    //     The mask guard must exit WITHOUT touching the (null) nodes pointer.
    const E = try table.Table.create(gpa);
    defer E.destroy(gpa);

    var consts = [_]Value{ key_val, Value.int(1) };
    var full: [READ_LEN]I = undefined;
    hrefkReadIr(&full, aux, 1);
    var es = [_]u16{};
    const tr = Trace{ .anchor = undefined, .instrs = &full, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };
    var ct = compile(gpa, &tr, 0) orelse return error.NativeBailedUnexpectedly;
    defer ct.deinit();

    for ([_]*table.Table{ R, E }) |bad| {
        const container = try table.Table.create(gpa);
        defer container.destroy(gpa);
        try container.set(gpa, Value.int(1), Value.heap(&bad.header));

        var nregs = [_]Value{ Value.heap(&container.header), Value.int(1), Value.int(0) };
        const nresult = try runNative(ct, &nregs);
        try testing.expectEqual(@as(usize, 0), nresult.local_completed);
        try testing.expectEqual(@as(u32, READ_HREF_IDX), nresult.exit_instr);
        try testing.expectEqual(@as(i64, 1), nregs[1].asInt()); // entry state
        try testing.expectEqual(@as(i64, 0), nregs[2].asInt());
    }
    // R itself untouched by the exits.
    try testing.expectEqual(@as(i64, 7), R.get(key_val).asInt());
}

test "nativegen(doc49): a static-root href with a hrefk aux fails closed (bail)" {
    if (comptime !is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;

    // The recorder only encodes hrefk when the seed path declined (dynamic
    // root); a `.ptr`-rooted href must carry a seed slab slot (aux >= 0).
    // Malformed IR pairing a static root with a hrefk encoding must decline
    // native, not silently misread the aux as a slab slot.
    const kt = try table.Table.create(gpa);
    defer kt.destroy(gpa);
    const key = try string.String.create(gpa, "v");
    defer key.destroy(gpa);
    const key_val = Value.heap(&key.header);
    try kt.set(gpa, key_val, Value.int(7));
    const sm = kt.hashSlotOf(key_val).?;

    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0: table (static .ptr root)
        .{ .op = .guard_table, .a = 0 }, // 1
        .{ .op = .konst, .aux = 0 }, // 2: key
        .{ .op = .href, .a = 0, .b = 2, .aux = trace_ir.HrefAux.encode(sm.slot, sm.mask).? }, // 3
        .{ .op = .guard_hash, .a = 3, .aux = 1 }, // 4
        .{ .op = .hload, .a = 3, .ty = .int }, // 5
        .{ .op = .phi, .b = 5, .aux = 1 },
        .{ .op = .loop },
    };
    var consts = [_]Value{key_val};
    var es = [_]u16{};
    const tr = Trace{ .anchor = undefined, .instrs = &instrs, .consts = &consts, .entry_slots = &es, .entry_guards = &.{} };
    try expectBail(&tr);
}
