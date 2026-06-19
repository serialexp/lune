//! lune stdlib — the basic-library iterators `pairs`, `ipairs`, `next`.
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
//! doc says "lands fully with that iterator" lands here. This first cut builds the
//! sorted hash-key view **on each `next` call** (correct and trivially
//! snapshot-safe — nothing derived is cached); a per-table sorted-key cache is a
//! pure-perf follow-up behind the same tests.
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
const key_order = @import("../key_order.zig");

const Value = value.Value;
const Table = table_mod.Table;
const Vm = interp.Vm;

/// Name of the hidden numeric iterator `ipairs` hands back. Not a valid lune
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
    return Table.fromHeader(v.asHeap());
}

/// Fetch the native installed under `name` as a callable `Value` (from globals).
fn globalNative(vm: *Vm, name: []const u8) anyerror!Value {
    return vm.globals.get(try vm.heap.internValue(name));
}

// ---------------------------------------------------------------------------
// next — the deterministic traversal primitive
// ---------------------------------------------------------------------------

/// A located key/value pair, or `found == false` at the end of traversal.
const Step = struct { found: bool, key: Value = undefined, val: Value = undefined };

/// Collect the hash-part keys, sorted into the canonical order. Caller frees.
fn sortedHashKeys(gpa: std.mem.Allocator, t: *const Table) ![]Value {
    const keys = try gpa.alloc(Value, t.hash.count());
    var it = t.hash.iterator();
    var i: usize = 0;
    while (it.next()) |e| : (i += 1) keys[i] = e.key_ptr.*;
    std.mem.sort(Value, keys, {}, key_order.less);
    return keys;
}

/// First hash key in canonical order (and its value), or not-found if empty.
fn firstHashStep(gpa: std.mem.Allocator, t: *const Table) !Step {
    const keys = try sortedHashKeys(gpa, t);
    defer gpa.free(keys);
    if (keys.len == 0) return .{ .found = false };
    return .{ .found = true, .key = keys[0], .val = t.hash.get(keys[0]).? };
}

/// The hash key/value strictly after `ctrl` in canonical order. Uses a
/// strictly-greater search (NOT "find ctrl then +1"), so it stays correct when
/// the current key was just deleted (Lua permits deleting the current key during
/// traversal) — the rebuilt list simply excludes it and we land on the next one.
fn hashSuccessorStep(gpa: std.mem.Allocator, t: *const Table, ctrl: Value) !Step {
    const keys = try sortedHashKeys(gpa, t);
    defer gpa.free(keys);
    // First index where ctrl < keys[idx]; sorted ascending, so this is the
    // successor whether ctrl is present or absent.
    var lo: usize = 0;
    var hi: usize = keys.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (key_order.keyLessThan(ctrl, keys[mid])) hi = mid else lo = mid + 1;
    }
    if (lo >= keys.len) return .{ .found = false };
    return .{ .found = true, .key = keys[lo], .val = t.hash.get(keys[lo]).? };
}

/// The core of `next(t, ctrl)`: array part (ascending index, skipping nil holes)
/// then hash part (canonical order).
fn nextStep(gpa: std.mem.Allocator, t: *const Table, ctrl: Value) !Step {
    const n: i64 = @intCast(t.array.len);

    // Determine where to resume in the array part.
    var start: i64 = undefined; // first array index to consider
    var in_array = true;
    if (ctrl.isNil()) {
        start = 1;
    } else if (ctrl.isInt() and ctrl.asInt() >= 1 and ctrl.asInt() <= n) {
        start = ctrl.asInt() + 1;
    } else {
        in_array = false; // ctrl is a hash key (or an int beyond the array part)
    }

    if (in_array) {
        var i = start;
        while (i <= n) : (i += 1) {
            const v = t.array.get(@intCast(i));
            if (!v.isNil()) return .{ .found = true, .key = Value.int(i), .val = v };
        }
        // Array part exhausted → first hash key.
        return firstHashStep(gpa, t);
    }
    return hashSuccessorStep(gpa, t, ctrl);
}

/// `next(t [, ctrl])` primary projection — the next key only (drives `for k in
/// pairs(t)`). nil at end of traversal.
fn nNext1(ctx: *anyopaque, args: []const Value) anyerror!Value {
    const vm = vmOf(ctx);
    const t = try tableArg(vm, args, 0);
    const ctrl = if (args.len >= 2) args[1] else Value.nil();
    const step = try nextStep(vm.gpa, t, ctrl);
    return if (step.found) step.key else Value.nil();
}

/// `next(t [, ctrl])` multi path — `(key, value)`, or 0 results at the end (the
/// VM nil-pads, so the generic-for sees a nil first var and stops).
fn nNextN(ctx: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
    const vm = vmOf(ctx);
    const t = try tableArg(vm, args, 0);
    const ctrl = if (args.len >= 2) args[1] else Value.nil();
    const step = try nextStep(vm.gpa, t, ctrl);
    if (!step.found) return 0;
    if (out.len >= 1) out[0] = step.key;
    if (out.len >= 2) out[1] = step.val;
    return @min(@as(usize, 2), out.len);
}

// ---------------------------------------------------------------------------
// ipairs iterator — numeric, stops at the first nil
// ---------------------------------------------------------------------------

/// `@ipairs_iter(t, i)` primary projection — the next index `i+1`, or nil when
/// `t[i+1]` is nil (stops the loop).
fn nInext1(ctx: *anyopaque, args: []const Value) anyerror!Value {
    const vm = vmOf(ctx);
    const t = try tableArg(vm, args, 0);
    const i = if (args.len >= 2 and args[1].isInt()) args[1].asInt() else 0;
    const j = i + 1;
    return if (t.getInt(j).isNil()) Value.nil() else Value.int(j);
}

/// `@ipairs_iter(t, i)` multi path — `(i+1, t[i+1])`, or 0 results at the first
/// nil.
fn nInextN(ctx: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
    const vm = vmOf(ctx);
    const t = try tableArg(vm, args, 0);
    const i = if (args.len >= 2 and args[1].isInt()) args[1].asInt() else 0;
    const j = i + 1;
    const v = t.getInt(j);
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
    _ = try tableArg(vm, args, 0); // type-check
    return globalNative(vm, "next");
}

fn nPairsN(ctx: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
    const vm = vmOf(ctx);
    const t = try tableArg(vm, args, 0);
    const triple = [3]Value{ try globalNative(vm, "next"), Value.heap(&t.header), Value.nil() };
    const w = @min(@as(usize, 3), out.len);
    var i: usize = 0;
    while (i < w) : (i += 1) out[i] = triple[i];
    return w;
}

/// `ipairs(t)` → `(@ipairs_iter, t, 0)`. Primary projection is the iterator.
fn nIpairs1(ctx: *anyopaque, args: []const Value) anyerror!Value {
    const vm = vmOf(ctx);
    _ = try tableArg(vm, args, 0);
    return globalNative(vm, ipairs_iter_name);
}

fn nIpairsN(ctx: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
    const vm = vmOf(ctx);
    const t = try tableArg(vm, args, 0);
    const triple = [3]Value{ try globalNative(vm, ipairs_iter_name), Value.heap(&t.header), Value.int(0) };
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
    .{ .name = ipairs_iter_name, .func = &nInext1, .multi = &nInextN },
};
