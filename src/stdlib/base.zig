//! mahina stdlib — the basic-library iterators `pairs`, `ipairs`, `next`.
//!
//! These are top-level globals (Lua's "basic" library, not the `table`
//! namespace). Like `stdlib/table.zig` they take the `*Vm` (heap, globals,
//! allocator) via `@ptrCast(@alignCast(ctx))`, so this module imports `interp`.
//!
//! ## Deterministic iteration order
//!
//! `next`/`pairs` walk the table's **array part** in ascending index order, then
//! its **hash part** in the canonical key order (`key_order.keyLessThan`: tag →
//! heap `GcHeader.id` → payload bits) — the exact order the keyframe serializer
//! uses. That makes iteration address-independent and stable across runs and
//! across snapshot/restore (docs/design/02-determinism.md): the rule the design
//! doc says "lands fully with that iterator" lands here. The sorted hash-key
//! view is built once per traversal and kept in the hash part
//! (`HashPart.nextLive`). It is derived state only: a keyframe never carries
//! it, and a traversal resumed after restore rebuilds it and visits the same
//! keys. The first cut sorted on every `next` call, which made a traversal
//! O(k² log k).
//!
//! ## Generic-for protocol & the multi ABI
//!
//! The compiler lowers `for v1..vn in explist` to a per-iteration `f(s, ctrl)`
//! call (see `compiler.compileGenericFor`). `pairs(t)` returns `(next, t, nil)`
//! and `ipairs(t)` returns `(inext, t, 0)` — three values via the native multi
//! ABI. The iterator they hand back must be a *callable* the VM can dispatch:
//! `pairs` returns the public `next` global; `ipairs` returns a hidden iterator
//! installed under the non-identifier name `@ipairs_iter` (un-spellable in source,
//! but still a GC root via `globals` and restorable by-name from `base_natives` —
//! the property a mid-iteration keyframe needs).
//!
//! Each iterator native supplies BOTH a `multi` impl and a `func` primary
//! projection: `for k in pairs(t)` wants a single result, which the VM routes to
//! `func` (the multi path is only taken for ≥2 wanted), so `func` must return the
//! first result (the key / the index).

const std = @import("std");
const value = @import("../value.zig");
const function = @import("../function.zig");
const table_mod = @import("../table.zig");
const interp = @import("../interp.zig");

const Value = value.Value;
const Table = table_mod.Table;
const Vm = interp.Vm;

/// Name of the hidden numeric iterator `ipairs` hands back. Not a valid mahina
/// identifier, so user code can never name it, yet it installs as a normal global
/// native (GC root + keyframe-restorable by name).
const ipairs_iter_name = "@ipairs_iter";

// ---------------------------------------------------------------------------
// Argument helpers
// ---------------------------------------------------------------------------

inline fn vmOf(ctx: *anyopaque) *Vm {
    return @ptrCast(@alignCast(ctx));
}

fn tableArg(vm: *Vm, args: []const Value, i: usize) anyerror!*Table {
    if (i >= args.len) return vm.badArg(i + 1, "table", null);
    const v = args[i];
    if (!v.isHeap() or v.heapType() != .table) return vm.badArg(i + 1, "table", v);
    const t = Table.fromHeader(v.asHeap());
    // Gate (doc 14): a grid is only ever touched by fused `a[i][j]`; any bare
    // stdlib access deflates it back to real row tables first.
    if (t.array.isGrid()) try vm.heap.deflateGrid(t);
    return t;
}

/// Like `tableArg` but also accepts a `row_view` (a transient grid row, doc 14):
/// `next`/`pairs`/`ipairs` traverse a row as a length-`#row` array. Returns the
/// container *value* — the iterators carry it verbatim as the loop state.
fn iterableArg(vm: *Vm, args: []const Value, i: usize) anyerror!Value {
    if (i >= args.len) return vm.badArg(i + 1, "table", null);
    const v = args[i];
    if (v.isRowView()) return v;
    if (!v.isHeap() or v.heapType() != .table) return vm.badArg(i + 1, "table", v);
    // Gate: iterating the matrix itself deflates it (so the loop sees real row
    // tables, never bare row_views). A row_view container is handled above.
    const t = Table.fromHeader(v.asHeap());
    if (t.array.isGrid()) try vm.heap.deflateGrid(t);
    return v;
}

/// Fetch the native installed under `name` as a callable `Value` (from globals).
fn globalNative(vm: *Vm, name: []const u8) anyerror!Value {
    return vm.globals.get(try vm.heap.internValue(name));
}

// ---------------------------------------------------------------------------
// next — the deterministic traversal primitive
// ---------------------------------------------------------------------------

/// A located key/value pair, or `found == false` at the end of traversal.
pub const Step = struct { found: bool, key: Value = undefined, val: Value = undefined };

/// Who is stepping: the `next` native, or doc 66 P1's `itern` fast lane,
/// which must not allocate and so declines (`error.WouldAllocate`) where
/// `next` would build the hash part's sorted view.
const Stepper = enum { native, no_alloc };

/// The hash key/value after `ctrl` in canonical order (the first one when
/// `ctrl` is null). Strictly greater, not "find ctrl, then +1", so it stays
/// correct when the current key was just deleted (Lua permits that during a
/// traversal). `HashPart.nextLive` keeps the sorted view across the steps.
fn hashStep(comptime by: Stepper, gpa: std.mem.Allocator, t: *Table, ctrl: ?Value) !Step {
    // `nextLive` allocates only to (re)build the view, and only frees it
    // when the hash part is empty.
    if (by == .no_alloc and t.hash.live != 0 and !t.hash.iter_valid) return error.WouldAllocate;
    const e = try t.hash.nextLive(gpa, ctrl) orelse return .{ .found = false };
    return .{ .found = true, .key = e.key, .val = e.value_ptr.* };
}

/// The core of `next(t, ctrl)`: array part (ascending index, skipping nil holes)
/// then hash part (canonical order).
fn nextStep(comptime by: Stepper, gpa: std.mem.Allocator, t: *Table, ctrl: Value) !Step {
    const n: i64 = @intCast(t.array.asize);

    // Table keys are identity-normalized (float-spelled integers and -0.0 fold
    // to the integer key), so a user-supplied control like `next(t, 0.0)` must
    // fold the same way before we classify it — otherwise a float-spelled
    // array-resident key falls into the hash-successor arm and finds nothing.
    const nctrl = table_mod.normalizeKey(ctrl);

    // Determine where to resume in the array part (doc 18: keys 0..asize-1,
    // identity slots — so key 0 iterates FIRST when present).
    var start: i64 = undefined; // first array index to consider
    var in_array = true;
    if (nctrl.isNil()) {
        start = 0;
    } else if (nctrl.isInt() and arr.ArrayPart.inArray(nctrl.asInt(), t.array.asize)) {
        start = nctrl.asInt() + 1;
    } else {
        in_array = false; // ctrl is a hash key (or an int beyond the array part)
    }

    if (in_array) {
        var i = start;
        while (i < n) : (i += 1) {
            const v = t.array.get(@intCast(i));
            if (!v.isNil()) return .{ .found = true, .key = Value.int(i), .val = v };
        }
        // Array part exhausted → first hash key.
        return hashStep(by, gpa, t, null);
    }
    return hashStep(by, gpa, t, nctrl);
}

/// `next` over a `row_view` (doc 14): ascending columns `1..stride`, skipping
/// `nil` holes — a grid row has no hash part. Mirrors the array-part arm of
/// `nextStep`. Pure (no allocation): cells live in the parent grid's flat buffer.
fn rowViewNextStep(rv: Value, ctrl: Value) Step {
    const stride = Table.fromHeader(rv.rowViewParent()).array.stride;
    var j: i64 = 1;
    if (!ctrl.isNil()) {
        // Same normalization as `nextStep`: a float-spelled integer control
        // (`next(row, 2.0)`) denotes the same column key.
        const nctrl = table_mod.normalizeKey(ctrl);
        if (!nctrl.isInt()) return .{ .found = false };
        j = nctrl.asInt() + 1;
    }
    while (j <= @as(i64, @intCast(stride))) : (j += 1) {
        const v = Table.rowViewGet(rv, Value.int(j));
        if (!v.isNil()) return .{ .found = true, .key = Value.int(j), .val = v };
    }
    return .{ .found = false };
}

/// `next(t [, ctrl])` over a table or a `row_view`, dispatching on the container.
fn nextStepAny(gpa: std.mem.Allocator, container: Value, ctrl: Value) !Step {
    if (container.isRowView()) return rowViewNextStep(container, ctrl);
    return nextStep(.native, gpa, Table.fromHeader(container.asHeap()), ctrl);
}

/// Doc 66 P1: is `nat` the `next` builtin? By function identity, which the
/// keyframe restorer preserves (it rebinds natives from the registry).
pub fn isNext(nat: *const function.Native) bool {
    return nat.func == &nNext1;
}

/// Doc 66 P1: `next(container, ctrl)` for `itern`'s fast lane, or null where
/// the `next` native would do more than step: a non-table argument (which
/// raises), a grid (which `iterableArg` deflates) or a hash view to build.
/// The same core as `next` otherwise, so the step is exactly the native's.
pub fn iternStep(gpa: std.mem.Allocator, container: Value, ctrl: Value) ?Step {
    if (container.isRowView()) return rowViewNextStep(container, ctrl);
    if (!container.isHeap() or container.heapType() != .table) return null;
    const t = Table.fromHeader(container.asHeap());
    if (t.array.isGrid()) return null;
    return nextStep(.no_alloc, gpa, t, ctrl) catch |e| switch (e) {
        error.WouldAllocate => null,
        // Unreachable: the no-allocation lane declines before `nextLive`
        // could build anything.
        error.OutOfMemory => unreachable,
    };
}

/// `next(t [, ctrl])` primary projection — the next key only (drives `for k in
/// pairs(t)`). nil at end of traversal.
fn nNext1(ctx: *anyopaque, args: []const Value) anyerror!Value {
    const vm = vmOf(ctx);
    const container = try iterableArg(vm, args, 0);
    const ctrl = if (args.len >= 2) args[1] else Value.nil();
    const step = try nextStepAny(vm.gpa, container, ctrl);
    return if (step.found) step.key else Value.nil();
}

/// `next(t [, ctrl])` multi path — `(key, value)`, or 0 results at the end (the
/// VM nil-pads, so the generic-for sees a nil first var and stops).
fn nNextN(ctx: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
    const vm = vmOf(ctx);
    const container = try iterableArg(vm, args, 0);
    const ctrl = if (args.len >= 2) args[1] else Value.nil();
    const step = try nextStepAny(vm.gpa, container, ctrl);
    if (!step.found) return 0;
    if (out.len >= 1) out[0] = step.key;
    if (out.len >= 2) out[1] = step.val;
    return @min(@as(usize, 2), out.len);
}

// ---------------------------------------------------------------------------
// ipairs iterator — numeric, stops at the first nil
// ---------------------------------------------------------------------------

/// `container[j]` for an integer key over a table or `row_view` — the `ipairs`
/// iterator's per-step read.
fn iterableGetInt(container: Value, j: i64) Value {
    if (container.isRowView()) return Table.rowViewGet(container, Value.int(j));
    return Table.fromHeader(container.asHeap()).getInt(j);
}

/// `@ipairs_iter(t, i)` primary projection — the next index `i+1`, or nil when
/// `t[i+1]` is nil (stops the loop). `i+1` wraps as Lua's does, so a
/// `math.maxinteger` control reads `t[math.mininteger]`.
fn nInext1(ctx: *anyopaque, args: []const Value) anyerror!Value {
    const vm = vmOf(ctx);
    const container = try iterableArg(vm, args, 0);
    const i = if (args.len >= 2 and args[1].isInt()) args[1].asInt() else 0;
    const j = i +% 1;
    return if (iterableGetInt(container, j).isNil()) Value.nil() else Value.int(j);
}

/// `@ipairs_iter(t, i)` multi path — `(i+1, t[i+1])`, or 0 results at the first
/// nil.
fn nInextN(ctx: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
    const vm = vmOf(ctx);
    const container = try iterableArg(vm, args, 0);
    const i = if (args.len >= 2 and args[1].isInt()) args[1].asInt() else 0;
    const j = i +% 1;
    const v = iterableGetInt(container, j);
    if (v.isNil()) return 0;
    if (out.len >= 1) out[0] = Value.int(j);
    if (out.len >= 2) out[1] = v;
    return @min(@as(usize, 2), out.len);
}

// ---------------------------------------------------------------------------
// pairs / ipairs — return the (iterator, state, control) triple
// ---------------------------------------------------------------------------

/// `pairs(t)` → `(next, t, nil)`. Primary projection is the iterator (`next`).
fn nPairs1(ctx: *anyopaque, args: []const Value) anyerror!Value {
    const vm = vmOf(ctx);
    _ = try iterableArg(vm, args, 0); // type-check (table or row_view)
    return globalNative(vm, "next");
}

fn nPairsN(ctx: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
    const vm = vmOf(ctx);
    const state = try iterableArg(vm, args, 0); // the row_view / table loop state
    const triple = [3]Value{ try globalNative(vm, "next"), state, Value.nil() };
    const w = @min(@as(usize, 3), out.len);
    var i: usize = 0;
    while (i < w) : (i += 1) out[i] = triple[i];
    return w;
}

/// `ipairs(t)` → `(@ipairs_iter, t, 0)`. Primary projection is the iterator.
fn nIpairs1(ctx: *anyopaque, args: []const Value) anyerror!Value {
    const vm = vmOf(ctx);
    _ = try iterableArg(vm, args, 0);
    return globalNative(vm, ipairs_iter_name);
}

fn nIpairsN(ctx: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
    const vm = vmOf(ctx);
    const state = try iterableArg(vm, args, 0);
    const triple = [3]Value{ try globalNative(vm, ipairs_iter_name), state, Value.int(0) };
    const w = @min(@as(usize, 3), out.len);
    var i: usize = 0;
    while (i < w) : (i += 1) out[i] = triple[i];
    return w;
}

// ---------------------------------------------------------------------------
// Registry
// ---------------------------------------------------------------------------

/// The basic-library iterator natives, concatenated into `interp.base_natives`.
pub const natives = [_]function.BaseNative{
    .{ .name = "next", .func = &nNext1, .multi = &nNextN },
    .{ .name = "pairs", .func = &nPairs1, .multi = &nPairsN },
    .{ .name = "ipairs", .func = &nIpairs1, .multi = &nIpairsN },
    .{ .name = ipairs_iter_name, .func = &nInext1, .multi = &nInextN, .itern = .inext },
};

test "next keeps its sorted view across traversals, and a collection mid-walk drops it" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    const ctx: *anyopaque = @ptrCast(&vm);

    // A global table, so the collection keeps it.
    const t = try vm.heap.newTable();
    const tv = Value.heap(&t.header);
    try vm.globals.set(gpa, try vm.heap.internValue("t"), tv);
    var buf: [16]u8 = undefined;
    for (0..300) |i| {
        const name = try std.fmt.bufPrint(&buf, "k{d}", .{i});
        try t.set(gpa, try vm.heap.internValue(name), Value.int(@intCast(i)));
    }

    // One walk, recording the keys; a collection runs halfway through.
    var keys: [300]Value = undefined;
    var n: usize = 0;
    var out: [2]Value = undefined;
    var ctrl = Value.nil();
    while (try nNextN(ctx, &.{ tv, ctrl }, &out) == 2) : (n += 1) {
        keys[n] = out[0];
        ctrl = out[0];
        if (n == 150) {
            vm.collect();
            try testing.expect(t.hash.iter_keys == null);
        }
    }
    try testing.expectEqual(@as(usize, 300), n);
    for (keys[0 .. n - 1], keys[1..n]) |a, b| try testing.expect(key_order.keyLessThan(a, b));
    // Sorted once at the start and once after the collection.
    try testing.expectEqual(@as(u32, 2), t.hash.iter_builds);

    // A second walk of the unchanged table sorts nothing.
    ctrl = Value.nil();
    n = 0;
    while (try nNextN(ctx, &.{ tv, ctrl }, &out) == 2) : (n += 1) {
        try testing.expect(out[0].eql(keys[n]));
        ctrl = out[0];
    }
    try testing.expectEqual(@as(usize, 300), n);
    try testing.expectEqual(@as(u32, 2), t.hash.iter_builds);
}

// --- grid row iteration (Phase 3, doc 14) ------------------------------------

const testing = std.testing;
const arr = @import("../array.zig");
const key_order = @import("../key_order.zig");

test "next/ipairs traverse a grid row_view as a length-#row array" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    const ctx: *anyopaque = @ptrCast(&vm);

    // Off-heap grid (Phase 3 predates GC-awareness, Phase 6). Row 0: [1, hole, 3].
    const t = try Table.create(gpa);
    defer t.destroy(gpa);
    t.array = try arr.ArrayPart.initGrid(gpa, 1, 4, .i32);
    t.array.gridSet(0, 0, Value.int(1));
    t.array.gridSet(0, 2, Value.int(3));
    const rv = t.getInt(1);
    try testing.expect(rv.isRowView());

    // `next` skips the hole: (1,1) then (3,3), then exhausted.
    var out: [2]Value = undefined;
    var n = try nNextN(ctx, &.{ rv, Value.nil() }, &out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(i64, 1), out[0].asInt());
    try testing.expectEqual(@as(i64, 1), out[1].asInt());

    n = try nNextN(ctx, &.{ rv, Value.int(1) }, &out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(i64, 3), out[0].asInt());
    try testing.expectEqual(@as(i64, 3), out[1].asInt());

    n = try nNextN(ctx, &.{ rv, Value.int(3) }, &out);
    try testing.expectEqual(@as(usize, 0), n); // past the last non-nil cell → done

    // `pairs(rv)` hands back (next, rv, nil) — the row_view rides as the state.
    var trip: [3]Value = undefined;
    const w = try nPairsN(ctx, &.{rv}, &trip);
    try testing.expectEqual(@as(usize, 3), w);
    try testing.expect(trip[1].isRowView());
    try testing.expect(trip[2].isNil());

    // `ipairs` iterator stops at the first nil: (1,1) then done (cell 2 is a hole).
    n = try nInextN(ctx, &.{ rv, Value.int(0) }, &out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(i64, 1), out[0].asInt());
    try testing.expectEqual(@as(i64, 1), out[1].asInt());
    n = try nInextN(ctx, &.{ rv, Value.int(1) }, &out);
    try testing.expectEqual(@as(usize, 0), n); // t[2] is a hole → ipairs halts
}
