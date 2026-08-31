//! mahina stdlib — the `table` library.
//!
//! Sequence/array helpers over mahina's `Table` (tier `core` in
//! `docs/lua-stdlib-inventory.csv`). **Unlike `stdlib/math.zig`, these natives
//! need the VM**: they allocate (shift/append via `Table.set`, `vm.gpa`), intern
//! strings (`vm.heap.internValue` for `concat`), and create tables
//! (`vm.heap.newTable` for `pack`). So `ctx` is cast to `*Vm` with the
//! `@ptrCast(@alignCast(ctx))` pattern, and this module imports `interp` for the
//! `Vm` type. The mutual import is fine: `Vm` appears only inside function
//! bodies (analyzed lazily), and `interp` consumes only `table.natives` — a
//! value, not a type (Rule Z-1: verified by `zig build`).
//!
//! No GC runs *inside* a native (collection only fires at the dispatch-loop
//! safepoint, between instructions), so a freshly `newTable`'d/`internValue`'d
//! object stays live until the native returns and the VM roots the result —
//! the same discipline `string.format` relies on.
//!
//! `table.unpack` returns *N* values via the native multi-return ABI
//! (`function.NativeMultiFn`): its primary projection is `t[i]`, and the multi
//! path writes `t[i..j]` into `out` (`min(count, out.len)`) — identical code for
//! fixed-count and `all_results` callers; the VM nil-pads or stamps `reg_top`.
//!
//! `table.sort(t[, comp])` sorts `t[1..#t]` in place by **heapsort** — chosen for
//! determinism: O(n log n) worst case, no pivot choice, and it terminates even
//! under an inconsistent comparator (we do not emulate Lua's "invalid order
//! function" detection; `docs/design/02-determinism.md` requires reproducibility,
//! not Lua's exact ordering of equal elements). The default comparator is
//! `arith.lt` — matching mahina's `<` operator exactly (numeric-only today; sorting
//! non-numbers without a `comp` raises `TypeError`, the same gap `<` has). A
//! custom comparator re-enters the VM via `Vm.callValue`; a comparator that errors
//! propagates out (catchable by an enclosing `pcall`). GC discipline: elements are
//! read by index on every comparison, never cached across a `callValue` (which may
//! collect), so a comparator that mutates `t` can never leave a stale `Value`.

const std = @import("std");
const value = @import("../value.zig");
const function = @import("../function.zig");
const table_mod = @import("../table.zig");
const interp = @import("../interp.zig");
const arith = @import("../arith.zig");

const Value = value.Value;
const Table = table_mod.Table;
const Vm = interp.Vm;

// ---------------------------------------------------------------------------
// Argument helpers
// ---------------------------------------------------------------------------

/// Recover the owning `*Vm` from the opaque native context.
inline fn vmOf(ctx: *anyopaque) *Vm {
    return @ptrCast(@alignCast(ctx));
}

/// Fetch argument `i` (0-based) as a `*Table`, or raise the located Lua
/// `bad argument #<i+1> to '<fn>' (table expected, got <type|no value>)`.
fn tableArg(vm: *Vm, args: []const Value, i: usize) anyerror!*Table {
    if (i >= args.len) return vm.badArg(i + 1, "table", null);
    const v = args[i];
    if (!v.isHeap() or v.heapType() != .table) return vm.badArg(i + 1, "table", v);
    const t = Table.fromHeader(v.asHeap());
    // Gate (doc 14): grids are touched only by fused `a[i][j]`; a stdlib op on the
    // matrix itself deflates it back to real row tables first.
    if (t.array.isGrid()) try vm.heap.deflateGrid(t);
    return t;
}

/// Convert a number `Value` to an `i64` with an exact integer representation
/// (Lua: "number has no integer representation" otherwise). Used for positions
/// and ranges, which Lua requires to be integers. Pure converter — callers map
/// the `error.TypeError` to a located bad-argument message via `intArg`.
fn toInt(v: Value) error{TypeError}!i64 {
    if (v.isInt()) return v.asInt();
    if (v.isFloat()) {
        const f = v.asFloat();
        const two_pow_63 = 9223372036854775808.0; // 2^63, exact in f64
        if (std.math.isFinite(f) and f == @trunc(f) and f >= -two_pow_63 and f < two_pow_63) {
            return @intFromFloat(f);
        }
    }
    return error.TypeError;
}

/// Fetch argument `i` (0-based) as an integer, raising the located Lua
/// bad-argument error: `(number expected, got <type|no value>)` when missing or
/// non-numeric, `(number has no integer representation)` for a non-integral float.
fn intArg(vm: *Vm, args: []const Value, i: usize) anyerror!i64 {
    if (i >= args.len) return vm.badArg(i + 1, "number", null);
    const v = args[i];
    if (!v.isNumber()) return vm.badArg(i + 1, "number", v);
    return toInt(v) catch vm.badArgReason(i + 1, "number has no integer representation");
}

/// True when arg `i` is present and not nil (an *omitted* optional).
inline fn given(args: []const Value, i: usize) bool {
    return i < args.len and !args[i].isNil();
}

// ---------------------------------------------------------------------------
// Natives
// ---------------------------------------------------------------------------

/// `table.insert(t, v)` — append at `#t+1`.
/// `table.insert(t, pos, v)` — insert at `pos`, shifting `t[pos..#t]` up by one.
/// Mutates `t`; returns nil. Wrong arity → `TypeError` (Lua: "wrong number of
/// arguments to 'insert'").
fn tInsert(ctx: *anyopaque, args: []const Value) anyerror!Value {
    const vm = vmOf(ctx);
    const t = try tableArg(vm, args, 0);
    const n = t.length();
    switch (args.len) {
        2 => try t.set(vm.gpa, Value.int(n + 1), args[1]),
        3 => {
            const pos = try intArg(vm, args, 1);
            // Lua: 1 <= pos <= #t+1 ("position out of bounds").
            if (pos < 1 or pos > n + 1) return error.TypeError;
            var i = n;
            while (i >= pos) : (i -= 1) {
                try t.set(vm.gpa, Value.int(i + 1), t.getInt(i));
            }
            try t.set(vm.gpa, Value.int(pos), args[2]);
        },
        else => return error.TypeError,
    }
    return Value.nil();
}

/// `table.remove(t, [pos])` — remove `t[pos]` (default `#t`), shift the tail down
/// by one, and return the removed value. Follows Lua 5.4 `ltablib.c:tremove`
/// edge handling (a `pos` other than `#t` must satisfy `1 <= pos <= #t+1`;
/// removing from an empty list is a no-op returning nil).
fn tRemove(ctx: *anyopaque, args: []const Value) anyerror!Value {
    const vm = vmOf(ctx);
    const t = try tableArg(vm, args, 0);
    const size = t.length();
    var pos: i64 = size;
    if (given(args, 1)) pos = try intArg(vm, args, 1);
    if (pos != size) {
        if (pos < 1 or pos > size + 1) return error.TypeError;
    }
    const removed = t.getInt(pos);
    var i = pos;
    while (i < size) : (i += 1) {
        try t.set(vm.gpa, Value.int(i), t.getInt(i + 1));
    }
    // `i` is now the final (emptied) slot — matches C's post-loop `pos`.
    try t.set(vm.gpa, Value.int(i), Value.nil());
    return removed;
}

/// `table.concat(t, [sep, [i, [j]]])` — join `t[i..j]` (default `1..#t`) with
/// `sep` (default ""), coercing each element via `interp.coerceConcat` (string
/// pass-through / number→text). A non string/number element → `TypeError` (Lua:
/// "invalid value (at index k) in table for 'concat'"). Result is interned.
fn tConcat(ctx: *anyopaque, args: []const Value) anyerror!Value {
    const vm = vmOf(ctx);
    const t = try tableArg(vm, args, 0);

    var sep_buf: [64]u8 = undefined;
    const sep: []const u8 = if (given(args, 1))
        (interp.coerceConcat(args[1], &sep_buf) catch return error.TypeError)
    else
        "";

    const lo: i64 = if (given(args, 2)) try intArg(vm, args, 2) else 1;
    const hi: i64 = if (given(args, 3)) try intArg(vm, args, 3) else t.length();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(vm.gpa);

    var k = lo;
    while (k <= hi) : (k += 1) {
        var buf: [64]u8 = undefined;
        const s = interp.coerceConcat(t.getInt(k), &buf) catch return error.TypeError;
        try out.appendSlice(vm.gpa, s);
        if (k < hi) try out.appendSlice(vm.gpa, sep);
    }
    return vm.heap.internValue(out.items);
}

/// `table.move(a1, f, e, t, [a2])` — copy `a1[f..e]` into `a2` (default `a1`)
/// starting at index `t`, handling overlap by copy direction. Returns `a2`.
/// Mirrors Lua 5.4 `ltablib.c:tmove`.
fn tMove(ctx: *anyopaque, args: []const Value) anyerror!Value {
    const vm = vmOf(ctx);
    const a1 = try tableArg(vm, args, 0);
    const f = try intArg(vm, args, 1);
    const e = try intArg(vm, args, 2);
    const tpos = try intArg(vm, args, 3);
    const a2 = if (given(args, 4)) try tableArg(vm, args, 4) else a1;

    if (e >= f) {
        // Forward when ranges don't overlap-up (or different tables); else
        // backward to preserve overlapping source bytes.
        if (tpos > e or tpos <= f or a1 != a2) {
            var i: i64 = 0;
            while (i <= e - f) : (i += 1) {
                try a2.set(vm.gpa, Value.int(tpos + i), a1.getInt(f + i));
            }
        } else {
            var i: i64 = e - f;
            while (i >= 0) : (i -= 1) {
                try a2.set(vm.gpa, Value.int(tpos + i), a1.getInt(f + i));
            }
        }
    }
    return Value.heap(&a2.header);
}

/// `table.pack(...)` — collect the varargs into a fresh table `t[1..n]`, set
/// `t.n = n`, and return it.
fn tPack(ctx: *anyopaque, args: []const Value) anyerror!Value {
    const vm = vmOf(ctx);
    const t = try vm.heap.newTable();
    for (args, 0..) |v, i| {
        try t.set(vm.gpa, Value.int(@intCast(i + 1)), v);
    }
    const n_key = try vm.heap.internValue("n");
    try t.set(vm.gpa, n_key, Value.int(@intCast(args.len)));
    return Value.heap(&t.header);
}

/// `table.unpack(t, [i, [j]])` primary projection — `t[i]` (default `i=1`).
fn tUnpack1(ctx: *anyopaque, args: []const Value) anyerror!Value {
    const vm = vmOf(ctx);
    const t = try tableArg(vm, args, 0);
    const i: i64 = if (given(args, 1)) try intArg(vm, args, 1) else 1;
    return t.getInt(i);
}

/// `table.unpack(t, [i, [j]])` multi path — write `t[i..j]` (default `i=1`,
/// `j=#t`) into `out`, returning the count actually written (`min(j-i+1,
/// out.len)`). All table reads (the `*Table` pointer and `i`/`j`) happen before
/// any `out` write, honouring the alias contract (`out` overlaps `args`).
fn tUnpackN(ctx: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
    const vm = vmOf(ctx);
    const t = try tableArg(vm, args, 0);
    const i: i64 = if (given(args, 1)) try intArg(vm, args, 1) else 1;
    const j: i64 = if (given(args, 2)) try intArg(vm, args, 2) else t.length();
    if (j < i) return 0;
    const count: usize = @intCast(j - i + 1);
    const write = @min(count, out.len);
    var k: usize = 0;
    while (k < write) : (k += 1) {
        out[k] = t.getInt(i + @as(i64, @intCast(k)));
    }
    return write;
}

// ---------------------------------------------------------------------------
// Registry
// ---------------------------------------------------------------------------

/// The `table.*` natives, concatenated into `interp.base_natives`.
// ---------------------------------------------------------------------------
// table.sort — in-place heapsort with an optional VM-reentrant comparator
// ---------------------------------------------------------------------------

/// `a < b` under the active comparator: the user closure (truthiness of its first
/// result) when `comp` is non-null, else mahina's numeric `<` (`arith.lt`).
fn sortLess(vm: *Vm, comp: ?Value, a: Value, b: Value) anyerror!bool {
    if (comp) |c| {
        var r: [1]Value = .{Value.nil()};
        const n = try vm.callValue(c, &.{ a, b }, r[0..1]);
        return n >= 1 and r[0].isTruthy();
    }
    return arith.lt(a, b);
}

/// Swap the 1-based array elements `i` and `j`, reading both fresh (the comparator
/// may have mutated the table since they were last seen).
fn sortSwap(t: *Table, gpa: std.mem.Allocator, i: i64, j: i64) interp.Error!void {
    const vi = t.get(Value.int(i));
    const vj = t.get(Value.int(j));
    try t.set(gpa, Value.int(i), vj);
    try t.set(gpa, Value.int(j), vi);
}

/// Max-heap sift-down over the 1-based subrange `[start, end]`. Each step reads
/// elements by index, so an inconsistent/mutating comparator only reshuffles the
/// (still in-bounds) result and always terminates — `root` strictly increases.
fn sortSiftDown(vm: *Vm, t: *Table, comp: ?Value, start: i64, end: i64) anyerror!void {
    var root = start;
    while (root * 2 <= end) {
        var child = root * 2;
        if (child + 1 <= end and try sortLess(vm, comp, t.get(Value.int(child)), t.get(Value.int(child + 1))))
            child += 1;
        if (try sortLess(vm, comp, t.get(Value.int(root)), t.get(Value.int(child)))) {
            try sortSwap(t, vm.gpa, root, child);
            root = child;
        } else return;
    }
}

/// `table.sort(list[, comp])` — sort `list[1..#list]` in place; returns nothing.
fn tSort(ctx: *anyopaque, args: []const Value) anyerror!Value {
    const vm = vmOf(ctx);
    const t = try tableArg(vm, args, 0);
    const comp: ?Value = if (args.len >= 2 and !args[1].isNil()) args[1] else null;
    const n = t.length();
    if (n < 2) return Value.nil();
    // Build the heap, then repeatedly extract the max to the back.
    var start = @divFloor(n, 2);
    while (start >= 1) : (start -= 1) try sortSiftDown(vm, t, comp, start, n);
    var end = n;
    while (end > 1) : (end -= 1) {
        try sortSwap(t, vm.gpa, 1, end);
        try sortSiftDown(vm, t, comp, 1, end - 1);
    }
    return Value.nil();
}

pub const natives = [_]function.BaseNative{
    .{ .name = "table.insert", .func = &tInsert, .module = "table", .field = "insert" },
    .{ .name = "table.remove", .func = &tRemove, .module = "table", .field = "remove" },
    .{ .name = "table.concat", .func = &tConcat, .module = "table", .field = "concat" },
    .{ .name = "table.move", .func = &tMove, .module = "table", .field = "move" },
    .{ .name = "table.pack", .func = &tPack, .module = "table", .field = "pack" },
    .{ .name = "table.unpack", .func = &tUnpack1, .multi = &tUnpackN, .module = "table", .field = "unpack" },
    .{ .name = "table.sort", .func = &tSort, .module = "table", .field = "sort" },
};

// ---------------------------------------------------------------------------
// Tests — direct native invocation against a live `Vm` (heap + allocator).
// Behavioural coverage across all execution modes lives in `interp.zig`'s
// `expectProgram` e2e suite; these pin the native ABI edges (the multi fn shape,
// error paths) that a source-level program can't reach as precisely.
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Build an array-part table `{vals...}` in `vm`'s heap.
fn buildSeq(vm: *Vm, vals: []const i64) !Value {
    const t = try vm.heap.newTable();
    for (vals, 0..) |v, i| try t.set(vm.gpa, Value.int(@intCast(i + 1)), Value.int(v));
    return Value.heap(&t.header);
}

test "table.unpack multi fn writes t[i..j], honouring out.len and range" {
    var vm = try Vm.init(testing.allocator);
    defer vm.deinit();
    const seq = try buildSeq(&vm, &.{ 10, 20, 30 });

    // Full range into a roomy buffer → all three, count == 3.
    var out: [8]Value = undefined;
    var n = try tUnpackN(@ptrCast(&vm), &.{seq}, &out);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqual(@as(i64, 10), out[0].asInt());
    try testing.expectEqual(@as(i64, 30), out[2].asInt());

    // out.len caps the count (fixed-count caller: local a,b = unpack(t)).
    var two: [2]Value = undefined;
    n = try tUnpackN(@ptrCast(&vm), &.{seq}, &two);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(i64, 20), two[1].asInt());

    // Explicit i,j sub-range.
    n = try tUnpackN(@ptrCast(&vm), &.{ seq, Value.int(2), Value.int(3) }, &out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(i64, 20), out[0].asInt());
    try testing.expectEqual(@as(i64, 30), out[1].asInt());

    // Empty range (j < i) → zero results, no writes.
    n = try tUnpackN(@ptrCast(&vm), &.{ seq, Value.int(3), Value.int(1) }, &out);
    try testing.expectEqual(@as(usize, 0), n);

    // Primary projection returns t[i] (default i=1).
    try testing.expectEqual(@as(i64, 10), (try tUnpack1(@ptrCast(&vm), &.{seq})).asInt());
    try testing.expectEqual(@as(i64, 30), (try tUnpack1(@ptrCast(&vm), &.{ seq, Value.int(3) })).asInt());
}

test "table.pack collects varargs and records n" {
    var vm = try Vm.init(testing.allocator);
    defer vm.deinit();

    const packed_v = try tPack(@ptrCast(&vm), &.{ Value.int(7), Value.nil(), Value.int(9) });
    const t = Table.fromHeader(packed_v.asHeap());
    try testing.expectEqual(@as(i64, 3), t.get(try vm.heap.internValue("n")).asInt());
    try testing.expectEqual(@as(i64, 7), t.getInt(1).asInt());
    try testing.expect(t.getInt(2).isNil());
    try testing.expectEqual(@as(i64, 9), t.getInt(3).asInt());

    // Zero args → empty table with n == 0.
    const empty = try tPack(@ptrCast(&vm), &.{});
    try testing.expectEqual(@as(i64, 0), Table.fromHeader(empty.asHeap()).get(try vm.heap.internValue("n")).asInt());
}

test "table.insert / remove shift the sequence and return removed value" {
    var vm = try Vm.init(testing.allocator);
    defer vm.deinit();
    const seq = try buildSeq(&vm, &.{ 1, 2, 3 });
    const t = Table.fromHeader(seq.asHeap());

    // Append, then positional insert at head.
    _ = try tInsert(@ptrCast(&vm), &.{ seq, Value.int(4) });
    _ = try tInsert(@ptrCast(&vm), &.{ seq, Value.int(1), Value.int(0) });
    try testing.expectEqual(@as(i64, 5), t.length());
    try testing.expectEqual(@as(i64, 0), t.getInt(1).asInt());
    try testing.expectEqual(@as(i64, 4), t.getInt(5).asInt());

    // Remove tail (default) returns the last element; table shrinks.
    const tail = try tRemove(@ptrCast(&vm), &.{seq});
    try testing.expectEqual(@as(i64, 4), tail.asInt());
    try testing.expectEqual(@as(i64, 4), t.length());

    // Remove at head shifts down and returns it.
    const head = try tRemove(@ptrCast(&vm), &.{ seq, Value.int(1) });
    try testing.expectEqual(@as(i64, 0), head.asInt());
    try testing.expectEqual(@as(i64, 1), t.getInt(1).asInt());
}

test "table.concat joins with separator and range; rejects non string/number" {
    var vm = try Vm.init(testing.allocator);
    defer vm.deinit();
    const seq = try buildSeq(&vm, &.{ 9, 8, 7, 6 });
    const sep = try vm.heap.internValue(",");

    const all = try tConcat(@ptrCast(&vm), &.{ seq, sep });
    try testing.expectEqualStrings("9,8,7,6", strOf(all));

    const ranged = try tConcat(@ptrCast(&vm), &.{ seq, try vm.heap.internValue("-"), Value.int(2), Value.int(3) });
    try testing.expectEqualStrings("8-7", strOf(ranged));

    // A table element is neither string nor number → TypeError.
    const t = Table.fromHeader(seq.asHeap());
    const inner = try vm.heap.newTable();
    try t.set(vm.gpa, Value.int(2), Value.heap(&inner.header));
    try testing.expectError(error.TypeError, tConcat(@ptrCast(&vm), &.{ seq, sep }));
}

test "table natives reject a non-table first argument" {
    var vm = try Vm.init(testing.allocator);
    defer vm.deinit();
    try testing.expectError(error.LuaError, tInsert(@ptrCast(&vm), &.{ Value.int(1), Value.int(2) }));
    try testing.expectError(error.LuaError, tUnpack1(@ptrCast(&vm), &.{Value.int(1)}));
    try testing.expectError(error.LuaError, tConcat(@ptrCast(&vm), &.{Value.int(1)}));
}

const string_mod = @import("../string.zig");

/// Read a heap string `Value`'s bytes (test helper).
fn strOf(v: Value) []const u8 {
    return string_mod.String.fromHeader(v.asHeap()).bytes();
}
