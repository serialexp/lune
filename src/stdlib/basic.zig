//! mahina stdlib — the basic-library scalar helpers `type`, `tostring`,
//! `tonumber`, `select`, `rawequal`/`rawget`/`rawset`/`rawlen`, plus the
//! string-returning `math.type` and the pure `os.difftime`.
//!
//! These are the "make it usable" core functions — every one a **pure,
//! deterministic** computation over its argument `Value`s (tier `core` in
//! `docs/lua-stdlib-inventory.csv`). They touch neither host effects, the trace
//! recorder, nor the safepoint counter, so they are determinism-invisible: a
//! `.fast`/`.full` interpreter run produces byte-identical output.
//!
//! Unlike `stdlib/math.zig` (which ignores `ctx`), several natives here need the
//! `*Vm` — to **intern** a result string (`type`/`tostring`/`math.type`) or to
//! reach the heap. So this module imports `interp` and recovers the VM via
//! `vmOf(ctx)`, exactly like `stdlib/base.zig`. The two genuinely-shared coercion
//! helpers (`interp.coerceConcat`, `interp.strBytes`) stay in `interp.zig` and are
//! referenced qualified, matching the `stdlib/table.zig` precedent.
//!
//! ## `select` and the multi-return ABI
//!
//! `select(n, ...)` returns the arguments after the n-th (or, for the literal
//! string `"#"`, their count). It is a `multi` native: the primary `func`
//! projection yields the first selected value, and the `multi` impl streams the
//! tail into the caller's register window. Per the `NativeMultiFn` aliasing
//! contract, `out` overlaps `args` (`out[k+1] == args[k]`); writing the tail
//! left-to-right is safe because every source index `n+j` is strictly greater
//! than the aliased destination index `j-1` (since `n >= 1`) — the classic
//! Lua "shift down" that never clobbers an unread source.

const std = @import("std");
const arith = @import("../arith.zig");
const value = @import("../value.zig");
const function = @import("../function.zig");
const interp = @import("../interp.zig");
const table_mod = @import("../table.zig");
const string_mod = @import("../string.zig");
const io = @import("../io.zig");

const Value = value.Value;
const Table = table_mod.Table;
const Vm = interp.Vm;

inline fn vmOf(ctx: *anyopaque) *Vm {
    return @ptrCast(@alignCast(ctx));
}

// ---------------------------------------------------------------------------
// type / tostring
// ---------------------------------------------------------------------------

/// `type(v)` — the Lua type name of `v` as a string. Reuses `Value.typeName`
/// (the single source of truth shared with diagnostics): numbers → "number",
/// closures and natives → "function", tables/typed-arrays → "table".
fn bType(ctx: *anyopaque, args: []const Value) anyerror!Value {
    const vm = vmOf(ctx);
    if (args.len == 0) return error.TypeError; // Lua: "bad argument #1 to 'type' (value expected)"
    return vm.typeNameValue(args[0]);
}

/// `tostring(v)` — render `v` to a string. A `__tostring` metamethod wins first
/// (it must return a string). Otherwise a string returns itself (no copy); any
/// other value is rendered through `io.writeValue` (the same text `print` emits,
/// so the two never disagree) into a bounded stack buffer, then interned.
fn bToString(ctx: *anyopaque, args: []const Value) anyerror!Value {
    const vm = vmOf(ctx);
    const v = if (args.len == 0) Value.nil() else args[0];
    if (try vm.metaToString(v)) |s| return s; // `__tostring` handler
    if (v.isHeap() and v.heapType() == .string) return v; // already a string
    // Non-string renderings are bounded: scalars (<~32 bytes) and the
    // "kind: 0x<id>" identity form for heap objects. 128 bytes is ample.
    var buf: [128]u8 = undefined;
    var w = io.Writer.fixed(&buf);
    io.writeValue(&w, v) catch unreachable; // fixed buffer is large enough
    return vm.heap.internValue(w.buffered());
}

// ---------------------------------------------------------------------------
// tonumber — relocated from interp.zig's bench stdlib (name kept: "tonumber")
// ---------------------------------------------------------------------------

/// `tonumber(v [, base])`. Numbers pass through. A string is trimmed and parsed:
/// with an explicit `base` as an integer in that base; otherwise auto (int first —
/// honoring a `0x` prefix — then float). Anything unparseable / non-numeric → nil.
/// The conversion itself lives in `arith.toNumber` — the ONE core shared with the
/// trace recorder's konst fold (doc 23 D2), so the two can never disagree.
fn bToNumber(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len == 0) return Value.nil();
    return arith.toNumber(args[0], if (args.len >= 2) args[1] else null);
}

// ---------------------------------------------------------------------------
// select
// ---------------------------------------------------------------------------

/// Resolve `select`'s first argument to a 1-based start index into the *tail*
/// (`args[1..]`). `"#"` is handled by callers before this. A negative `n` counts
/// from the end (`-1` = the last argument). Returns the 0-based index *into
/// `args`* of the first selected value, clamped so an out-of-range positive `n`
/// yields an empty selection (Lua errors on `n == 0` or `|n|` past the end; we
/// surface those as `TypeError`).
fn selectStart(vm: *Vm, args: []const Value) anyerror!usize {
    if (args.len == 0) return vm.badArg(1, "number", null);
    if (!args[0].isNumber()) return vm.badArg(1, "number", args[0]);
    const nargs: i64 = @intCast(args.len - 1); // count of values after the selector
    var n: i64 = undefined;
    if (args[0].isInt()) {
        n = args[0].asInt();
    } else {
        const f = args[0].asFloat();
        const two_pow_63 = 9223372036854775808.0;
        if (!std.math.isFinite(f) or @trunc(f) != f or f < -two_pow_63 or f >= two_pow_63) {
            return vm.badArgReason(1, "number has no integer representation");
        }
        n = @intFromFloat(f);
    }
    if (n < 0) n += nargs + 1; // -1 → last
    if (n < 1 or n > nargs + 1) return vm.badArgReason(1, "index out of range"); // n==nargs+1 → empty
    return @intCast(n); // 0-based index into args of the first selected value
}

/// `select("#", ...)` returns the count of extra args; this is the primary
/// projection helper distinguishing the `"#"` form from the numeric form.
pub fn isHashSelector(v: Value) bool {
    if (interp.strBytes(v)) |s| return s.len == 1 and s[0] == '#';
    return false;
}

fn bSelect1(ctx: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len >= 1 and isHashSelector(args[0])) {
        return Value.int(@intCast(args.len - 1));
    }
    const start = try selectStart(vmOf(ctx), args);
    if (start >= args.len) return Value.nil(); // empty selection
    return args[start];
}

fn bSelectN(ctx: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
    if (args.len >= 1 and isHashSelector(args[0])) {
        if (out.len >= 1) out[0] = Value.int(@intCast(args.len - 1));
        return @min(@as(usize, 1), out.len);
    }
    const start = try selectStart(vmOf(ctx), args);
    // Stream args[start..] into out. Safe under the aliasing contract: source
    // index (start + k) is always > destination's aliased index (k - 1).
    var k: usize = 0;
    while (start + k < args.len and k < out.len) : (k += 1) {
        out[k] = args[start + k];
    }
    return k;
}

// ---------------------------------------------------------------------------
// raw access (no metatables exist, so these match the ordinary semantics today)
// ---------------------------------------------------------------------------

fn tableArg(vm: *Vm, args: []const Value, i: usize) anyerror!*Table {
    if (i >= args.len) return vm.badArg(i + 1, "table", null);
    const v = args[i];
    if (!v.isHeap() or v.heapType() != .table) return vm.badArg(i + 1, "table", v);
    const t = Table.fromHeader(v.asHeap());
    // Gate (doc 14): grids are touched only by fused `a[i][j]`; a bare stdlib op
    // (rawget/rawset/rawlen/setmetatable) deflates the grid back to row tables.
    if (t.array.isGrid()) try vm.heap.deflateGrid(t);
    return t;
}

/// `rawequal(a, b)` — primitive equality, bypassing any `__eq`. With no
/// metatables this is exactly `Value.eql` (numbers compare across the int/float
/// boundary, heap objects by stable id).
fn bRawEqual(_: *anyopaque, args: []const Value) anyerror!Value {
    const a = if (args.len >= 1) args[0] else Value.nil();
    const b = if (args.len >= 2) args[1] else Value.nil();
    return Value.boolean(a.eql(b));
}

/// `rawget(t, k)` — `t[k]` without `__index`.
fn bRawGet(ctx: *anyopaque, args: []const Value) anyerror!Value {
    const t = try tableArg(vmOf(ctx), args, 0);
    const k = if (args.len >= 2) args[1] else Value.nil();
    return t.get(k);
}

/// `rawset(t, k, v)` — `t[k] = v` without `__newindex`; returns `t`. A nil key is
/// an error (Lua: "table index is nil"); a NaN key likewise ("table index is
/// NaN").
fn bRawSet(ctx: *anyopaque, args: []const Value) anyerror!Value {
    const vm = vmOf(ctx);
    const t = try tableArg(vm, args, 0);
    const k = if (args.len >= 2) args[1] else Value.nil();
    const v = if (args.len >= 3) args[2] else Value.nil();
    if (k.isNil()) return error.TypeError;
    if (k.isFloat() and std.math.isNan(k.asFloat())) return error.TypeError;
    try t.set(vm.gpa, k, v);
    return args[0];
}

/// `rawlen(v)` — length of a string (bytes) or table (a border), without `__len`.
fn bRawLen(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len == 0) return error.TypeError;
    const v = args[0];
    if (v.isHeap()) {
        switch (v.heapType()) {
            .string => return Value.int(@intCast(string_mod.String.fromHeader(v.asHeap()).len)),
            .table => return Value.int(Table.fromHeader(v.asHeap()).length()),
            else => {},
        }
    }
    return error.TypeError; // Lua: "table or string expected"
}

// ---------------------------------------------------------------------------
// setmetatable / getmetatable — the metatable accessors (chunk 2a)
// ---------------------------------------------------------------------------

/// `setmetatable(t, mt)` — install `mt` (a table, or `nil` to clear) as `t`'s
/// metatable; returns `t`. Raises if `t` is not a table, if `mt` is neither a
/// table nor nil, or if the **current** metatable carries a `__metatable` field
/// (a protected metatable — Lua forbids changing it). The metatable is a new GC
/// edge (`gc.blacken` marks `t.metatable`); the write barrier records it for a
/// future generational collector.
fn bSetMetatable(ctx: *anyopaque, args: []const Value) anyerror!Value {
    const vm = vmOf(ctx);
    const t = try tableArg(vm, args, 0);
    const mt_arg = if (args.len >= 2) args[1] else Value.nil();
    const new_mt: ?*Table = if (mt_arg.isNil())
        null
    else if (mt_arg.isHeap() and mt_arg.heapType() == .table)
        Table.fromHeader(mt_arg.asHeap())
    else
        return vm.badArg(2, "nil or table", mt_arg);
    // Protection: a current metatable with a non-nil `__metatable` cannot change.
    if (t.metatable) |cur| {
        if (!cur.get(vm.mm.metatable).isNil())
            return vm.raiseLocatedError("cannot change a protected metatable", 1);
    }
    t.metatable = new_mt;
    if (new_mt) |m| vm.heap.writeBarrier(&t.header, Value.heap(&m.header)); // no-op until Phase 4
    return args[0];
}

/// `getmetatable(v)` — `v`'s metatable, or `nil`. If that metatable has a
/// `__metatable` field, return *that* value instead (the protection hook), so a
/// library can hide or lock its real metatable. Strings share the built-in
/// string metatable, so `getmetatable("")` is non-nil.
fn bGetMetatable(ctx: *anyopaque, args: []const Value) anyerror!Value {
    const vm = vmOf(ctx);
    const v = if (args.len >= 1) args[0] else Value.nil();
    const mt = vm.metatableOf(v) orelse return Value.nil();
    const prot = mt.get(vm.mm.metatable);
    if (!prot.isNil()) return prot;
    return Value.heap(&mt.header);
}

// ---------------------------------------------------------------------------
// math.type — string-returning, so it lives here (needs the *Vm), not math.zig
// ---------------------------------------------------------------------------

/// `math.type(x)` — "integer" / "float" / nil. Pure subtype query.
fn mType(ctx: *anyopaque, args: []const Value) anyerror!Value {
    const vm = vmOf(ctx);
    if (args.len == 0) return error.TypeError;
    const v = args[0];
    if (v.isInt()) return vm.heap.internValue("integer");
    if (v.isFloat()) return vm.heap.internValue("float");
    return Value.nil();
}

// ---------------------------------------------------------------------------
// os.difftime — pure arithmetic over timestamps (no host clock; `core` tier)
// ---------------------------------------------------------------------------

/// `os.difftime(t2, t1)` — `t2 - t1` in seconds, as a float. Pure: it never
/// reads a clock, so it carries no effect and stays in the deterministic core.
fn osDiffTime(_: *anyopaque, args: []const Value) anyerror!Value {
    if (args.len < 1 or !args[0].isNumber()) return error.TypeError;
    const t2 = args[0].toFloat();
    const t1 = if (args.len >= 2 and args[1].isNumber()) args[1].toFloat() else 0;
    return Value.float(t2 - t1);
}

// ---------------------------------------------------------------------------
// Registry
// ---------------------------------------------------------------------------

pub const natives = [_]function.BaseNative{
    // `.recorded` tags land together with their recorder arms (doc 23 D1):
    // a tag makes `recCall` dispatch to `trace.recBuiltin`, whose arm owns the
    // observed-shape abort matrix for that builtin.
    .{ .name = "type", .func = &bType, .recorded = .type, .fast = .type },
    .{ .name = "tostring", .func = &bToString, .recorded = .tostring },
    .{ .name = "tonumber", .func = &bToNumber, .recorded = .tonumber, .fast = .tonumber },
    .{ .name = "select", .func = &bSelect1, .multi = &bSelectN, .recorded = .select, .fast = .select },
    .{ .name = "rawequal", .func = &bRawEqual, .recorded = .rawequal, .fast = .rawequal },
    .{ .name = "rawget", .func = &bRawGet, .recorded = .rawget, .fast = .rawget },
    .{ .name = "rawset", .func = &bRawSet, .recorded = .rawset },
    .{ .name = "rawlen", .func = &bRawLen, .recorded = .rawlen, .fast = .rawlen },
    .{ .name = "setmetatable", .func = &bSetMetatable },
    .{ .name = "getmetatable", .func = &bGetMetatable },
    .{ .name = "math.type", .func = &mType, .module = "math", .field = "type", .recorded = .mtype },
    .{ .name = "os.difftime", .func = &osDiffTime, .module = "os", .field = "difftime" },
};

// ---------------------------------------------------------------------------
// Tests — direct native invocation against a live `Vm`. Behavioural coverage
// across all execution modes lives in `interp.zig`'s `expectProgram` suite;
// these pin the ABI/edge cases (select aliasing, raw* error paths).
// ---------------------------------------------------------------------------

const testing = std.testing;

fn bytesOf(v: Value) []const u8 {
    return interp.strBytes(v).?;
}

test "type / math.type name the subtype" {
    var vm = try Vm.init(testing.allocator);
    defer vm.deinit();
    try testing.expectEqualStrings("number", bytesOf(try bType(@ptrCast(&vm), &.{Value.int(1)})));
    try testing.expectEqualStrings("number", bytesOf(try bType(@ptrCast(&vm), &.{Value.float(1.5)})));
    try testing.expectEqualStrings("nil", bytesOf(try bType(@ptrCast(&vm), &.{Value.nil()})));
    try testing.expectEqualStrings("boolean", bytesOf(try bType(@ptrCast(&vm), &.{Value.boolean(true)})));

    try testing.expectEqualStrings("integer", bytesOf(try mType(@ptrCast(&vm), &.{Value.int(1)})));
    try testing.expectEqualStrings("float", bytesOf(try mType(@ptrCast(&vm), &.{Value.float(1.5)})));
    try testing.expect((try mType(@ptrCast(&vm), &.{try vm.heap.internValue("x")})).isNil());
}

test "type hands back one cached string per name, across a collection" {
    var vm = try Vm.init(testing.allocator);
    defer vm.deinit();
    const ctx: *anyopaque = @ptrCast(&vm);
    const tbl = try vm.heap.newTable();
    const cases = [_]struct { v: Value, name: []const u8 }{
        .{ .v = Value.int(1), .name = "number" },
        .{ .v = Value.nil(), .name = "nil" },
        .{ .v = Value.boolean(false), .name = "boolean" },
        .{ .v = try vm.heap.internValue("s"), .name = "string" },
        .{ .v = Value.heap(&tbl.header), .name = "table" },
    };
    var first: [cases.len]Value = undefined;
    for (cases, 0..) |c, i| {
        first[i] = try bType(ctx, &.{c.v});
        try testing.expectEqualStrings(c.name, bytesOf(first[i]));
    }
    // The cache is a GC root: after a collection each name is still the
    // object the intern table holds (a swept entry would be gone from it), and
    // `type` still returns it. Only the scalar inputs are asked again; the
    // table and string above are unrooted and the collection frees them.
    vm.collect();
    for (cases[0..3], 0..) |c, i| {
        const live = vm.heap.internedLookup(c.name) orelse return error.TestExpectedEqual;
        try testing.expectEqual(first[i].asHeap(), &live.header);
        try testing.expectEqual(first[i].asHeap(), (try bType(ctx, &.{c.v})).asHeap());
    }
}

test "type in a bare VM interns its result" {
    var vm = try Vm.initBare(testing.allocator);
    defer vm.deinit();
    try testing.expectEqualStrings("number", bytesOf(try bType(@ptrCast(&vm), &.{Value.int(1)})));
}

test "tostring renders scalars; passes strings through" {
    var vm = try Vm.init(testing.allocator);
    defer vm.deinit();
    try testing.expectEqualStrings("nil", bytesOf(try bToString(@ptrCast(&vm), &.{Value.nil()})));
    try testing.expectEqualStrings("42", bytesOf(try bToString(@ptrCast(&vm), &.{Value.int(42)})));
    try testing.expectEqualStrings("true", bytesOf(try bToString(@ptrCast(&vm), &.{Value.boolean(true)})));
    const s = try vm.heap.internValue("hi");
    try testing.expectEqual(s, try bToString(@ptrCast(&vm), &.{s})); // same object, no copy
}

test "tonumber: pass-through, parse, base" {
    var vm = try Vm.init(testing.allocator);
    defer vm.deinit();
    try testing.expectEqual(@as(i64, 7), (try bToNumber(@ptrCast(&vm), &.{Value.int(7)})).asInt());
    try testing.expectEqual(@as(i64, 42), (try bToNumber(@ptrCast(&vm), &.{try vm.heap.internValue("42")})).asInt());
    try testing.expectEqual(@as(f64, 3.5), (try bToNumber(@ptrCast(&vm), &.{try vm.heap.internValue(" 3.5 ")})).asFloat());
    try testing.expectEqual(@as(i64, 255), (try bToNumber(@ptrCast(&vm), &.{ try vm.heap.internValue("ff"), Value.int(16) })).asInt());
    try testing.expect((try bToNumber(@ptrCast(&vm), &.{try vm.heap.internValue("zz")})).isNil());
}

test "select: # count, positive and negative indices, multi stream" {
    var vm = try Vm.init(testing.allocator);
    defer vm.deinit();
    const hash = try vm.heap.internValue("#");
    const a = try vm.heap.internValue("a");
    const b = try vm.heap.internValue("b");
    const c = try vm.heap.internValue("c");

    try testing.expectEqual(@as(i64, 3), (try bSelect1(@ptrCast(&vm), &.{ hash, a, b, c })).asInt());
    // primary projection: select(2, a,b,c) → "b"
    try testing.expectEqualStrings("b", bytesOf(try bSelect1(@ptrCast(&vm), &.{ Value.int(2), a, b, c })));
    // negative: select(-1, a,b,c) → "c"
    try testing.expectEqualStrings("c", bytesOf(try bSelect1(@ptrCast(&vm), &.{ Value.int(-1), a, b, c })));

    // multi stream from index 2 → (b, c)
    var out: [8]Value = undefined;
    const n = try bSelectN(@ptrCast(&vm), &.{ Value.int(2), a, b, c }, &out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("b", bytesOf(out[0]));
    try testing.expectEqualStrings("c", bytesOf(out[1]));

    // out-of-range index errors.
    try testing.expectError(error.LuaError, bSelect1(@ptrCast(&vm), &.{ Value.int(0), a }));
    try testing.expectError(error.LuaError, bSelect1(@ptrCast(&vm), &.{ Value.int(5), a, b }));
}

test "rawequal / rawget / rawset / rawlen" {
    var vm = try Vm.init(testing.allocator);
    defer vm.deinit();
    try testing.expect((try bRawEqual(@ptrCast(&vm), &.{ Value.int(1), Value.float(1.0) })).asBool());
    try testing.expect(!(try bRawEqual(@ptrCast(&vm), &.{ try vm.heap.internValue("a"), try vm.heap.internValue("b") })).asBool());

    const t = try vm.heap.newTable();
    const tv = Value.heap(&t.header);
    try t.set(vm.gpa, Value.int(1), Value.int(10));
    try t.set(vm.gpa, Value.int(2), Value.int(20));

    try testing.expectEqual(@as(i64, 20), (try bRawGet(@ptrCast(&vm), &.{ tv, Value.int(2) })).asInt());
    try testing.expectEqual(@as(i64, 2), (try bRawLen(@ptrCast(&vm), &.{tv})).asInt());
    try testing.expectEqual(@as(i64, 5), (try bRawLen(@ptrCast(&vm), &.{try vm.heap.internValue("hello")})).asInt());

    // rawset returns the table; the write is visible.
    const ret = try bRawSet(@ptrCast(&vm), &.{ tv, Value.int(3), Value.int(30) });
    try testing.expectEqual(tv, ret);
    try testing.expectEqual(@as(i64, 30), t.getInt(3).asInt());

    // nil key errors; non-table rawget/rawlen errors.
    try testing.expectError(error.TypeError, bRawSet(@ptrCast(&vm), &.{ tv, Value.nil(), Value.int(1) }));
    try testing.expectError(error.LuaError, bRawGet(@ptrCast(&vm), &.{ Value.int(1), Value.int(1) }));
    try testing.expectError(error.TypeError, bRawLen(@ptrCast(&vm), &.{Value.int(1)}));
}

test "os.difftime is pure subtraction" {
    var vm = try Vm.init(testing.allocator);
    defer vm.deinit();
    try testing.expectEqual(@as(f64, 5.0), (try osDiffTime(@ptrCast(&vm), &.{ Value.int(15), Value.int(10) })).asFloat());
    try testing.expectEqual(@as(f64, 15.0), (try osDiffTime(@ptrCast(&vm), &.{Value.int(15)})).asFloat());
}
