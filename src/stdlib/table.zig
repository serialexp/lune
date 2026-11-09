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
//! not Lua's exact ordering of equal elements). The default comparator is `<` as
//! the `lt` instruction takes it: numbers and strings raw, anything else through
//! `__lt` (`sortLess`), and "attempt to compare …" when there is no handler. A
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
const native_act = @import("../native_act.zig");
const RegWindow = @import("../regwindow.zig").RegWindow;

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
/// arguments to 'insert'"). A frozen `t` raises once the arguments check out
/// (doc 76 §5): every insert writes.
fn tInsert(ctx: *anyopaque, args: []const Value) anyerror!Value {
    const vm = vmOf(ctx);
    const t = try tableArg(vm, args, 0);
    const n = t.length();
    switch (args.len) {
        2 => {
            if (t.isReadonly()) return vm.readonlyError();
            try t.set(vm.gpa, Value.int(n + 1), args[1]);
        },
        3 => {
            const pos = try vm.intArg(args, 1);
            // Lua: 1 <= pos <= #t+1 ("position out of bounds").
            if (pos < 1 or pos > n + 1) return vm.badArgReason(2, "position out of bounds");
            if (t.isReadonly()) return vm.readonlyError();
            var i = n;
            while (i >= pos) : (i -= 1) {
                try t.set(vm.gpa, Value.int(i + 1), t.getInt(i));
            }
            try t.set(vm.gpa, Value.int(pos), args[2]);
        },
        else => return vm.raiseLocatedError("wrong number of arguments to 'insert'", 1),
    }
    return Value.nil();
}

/// `table.remove(t, [pos])` — remove `t[pos]` (default `#t`), shift the tail down
/// by one, and return the removed value. Follows Lua 5.4 `ltablib.c:tremove`
/// edge handling (a `pos` other than `#t` must satisfy `1 <= pos <= #t+1`;
/// removing from an empty list is a no-op returning nil). It always stores
/// the emptied slot, so a frozen `t` raises once `pos` checks out (doc 76 §5).
fn tRemove(ctx: *anyopaque, args: []const Value) anyerror!Value {
    const vm = vmOf(ctx);
    const t = try tableArg(vm, args, 0);
    const size = t.length();
    var pos: i64 = size;
    if (given(args, 1)) pos = try vm.intArg(args, 1);
    if (pos != size) {
        if (pos < 1 or pos > size + 1) return vm.badArgReason(2, "position out of bounds");
    }
    if (t.isReadonly()) return vm.readonlyError();
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
        (interp.coerceConcat(args[1], &sep_buf) catch return vm.badArg(2, "string", args[1]))
    else
        "";

    const lo: i64 = try vm.optIntArg(args, 2, 1);
    const hi: i64 = if (given(args, 3)) try vm.intArg(args, 3) else t.length();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(vm.gpa);

    var k = lo;
    while (k <= hi) : (k += 1) {
        var buf: [64]u8 = undefined;
        const v = t.getInt(k);
        const s = interp.coerceConcat(v, &buf) catch {
            var msg_buf: [96]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "invalid value ({s}) at index {d} in table for 'concat'", .{ v.typeName(), k }) catch unreachable;
            return vm.raiseLocatedError(msg, 1);
        };
        try out.appendSlice(vm.gpa, s);
        if (k < hi) try out.appendSlice(vm.gpa, sep);
    }
    return vm.heap.internValue(out.items);
}

/// `table.move(a1, f, e, t, [a2])` — copy `a1[f..e]` into `a2` (default `a1`)
/// starting at index `t`, handling overlap by copy direction. Returns `a2`.
/// Mirrors Lua 5.4 `ltablib.c:tmove`; a frozen `a2` raises when there is
/// something to move, after the range checks, as Luau's.
fn tMove(ctx: *anyopaque, args: []const Value) anyerror!Value {
    const vm = vmOf(ctx);
    const a1 = try tableArg(vm, args, 0);
    const f = try vm.intArg(args, 1);
    const e = try vm.intArg(args, 2);
    const tpos = try vm.intArg(args, 3);
    const a2 = if (given(args, 4)) try tableArg(vm, args, 4) else a1;

    if (e >= f) {
        if (!(f > 0 or e < std.math.maxInt(i64) + f)) return vm.badArgReason(3, "too many elements to move");
        if (tpos > std.math.maxInt(i64) - (e - f)) return vm.badArgReason(4, "destination wrap around");
        if (a2.isReadonly()) return vm.readonlyError();
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
/// A range the stack could never hold raises even here, as in Lua, whose
/// check does not depend on how many results the caller keeps.
fn tUnpack1(ctx: *anyopaque, args: []const Value) anyerror!Value {
    const vm = vmOf(ctx);
    const t = try tableArg(vm, args, 0);
    const i: i64 = try vm.optIntArg(args, 1, 1);
    const j: i64 = if (given(args, 2)) try vm.intArg(args, 2) else t.length();
    if (j < i) return Value.nil();
    try checkUnpackSpan(vm, i, j);
    return t.getInt(i);
}

/// Lua's "too many results to unpack": `j - i` (in u64, which cannot
/// overflow for `j >= i`) past what the whole stack could hold.
fn checkUnpackSpan(vm: *Vm, i: i64, j: i64) anyerror!void {
    const span = @as(u64, @bitCast(j)) -% @as(u64, @bitCast(i));
    if (span >= vm.regCapacity()) return vm.raiseLocatedError("too many results to unpack", 1);
}

/// `table.unpack(t, [i, [j]])` multi path — write `t[i..j]` (default `i=1`,
/// `j=#t`) into `out` and return the count `j-i+1`, which may exceed
/// `out.len` (the VM decides whether that is a truncation or an overflow,
/// `NativeMultiFn`). More than the whole stack could hold is Lua's "too many
/// results to unpack". All table reads (the `*Table` pointer and `i`/`j`)
/// happen before any `out` write, honouring the alias contract (`out`
/// overlaps `args`).
fn tUnpackN(ctx: *anyopaque, args: []const Value, out: []Value) anyerror!usize {
    const vm = vmOf(ctx);
    const t = try tableArg(vm, args, 0);
    const i: i64 = try vm.optIntArg(args, 1, 1);
    const j: i64 = if (given(args, 2)) try vm.intArg(args, 2) else t.length();
    if (j < i) return 0;
    try checkUnpackSpan(vm, i, j);
    const count: usize = @intCast(@as(u64, @bitCast(j)) -% @as(u64, @bitCast(i)) + 1);
    const write = @min(count, out.len);
    var k: usize = 0;
    while (k < write) : (k += 1) {
        out[k] = t.getInt(i + @as(i64, @intCast(k)));
    }
    return count;
}

// ---------------------------------------------------------------------------
// Registry
// ---------------------------------------------------------------------------

/// The `table.*` natives, concatenated into `interp.base_natives`.
// ---------------------------------------------------------------------------
// table.sort — in-place heapsort, a resumable native (doc 68 §5.1)
// ---------------------------------------------------------------------------

/// Where `table.sort`'s heapsort is (`SortState.step`).
const SortStep = enum(u3) {
    /// Building the heap: sift `start` down over `[start, n]`, then the one
    /// before it.
    heapify,
    /// Taking the largest to the back: swap `1` and `end`, then sift `1`
    /// down over `[1, end - 1]`.
    extract,
    /// Sifting `root` down over `[root, lim]`.
    sift,
    /// Waiting for `t[child] < t[child + 1]`: which child is the larger.
    pick,
    /// Waiting for `t[root] < t[child]`: whether `root` goes down.
    root,
};

/// `table.sort`'s heapsort as a state machine (doc 68 §7.2): it stops at
/// any comparison that needs a Lua call and carries on from that call's
/// result, wherever its state is kept, a Zig local (the native's own steps,
/// the Zig fallback) or the activation's registers (`native_act.zig`). The
/// comparisons, and the swaps between them, are the classic heapsort's, in
/// its order. Each reads the elements fresh, so a comparator that mutates
/// the table only reshuffles it, and the sort always terminates: `root`
/// strictly increases within a sift.
const SortState = struct {
    n: i64,
    start: i64,
    end: i64,
    root: i64,
    lim: i64,
    child: i64,
    extracting: bool,
    step: SortStep,

    /// How many integers hold it (`toWords`).
    const word_count = 8;
    comptime {
        std.debug.assert(word_count <= native_act.max_words);
        std.debug.assert(native_act.callReg(.sort) == native_act.wordReg(.sort) + word_count);
    }

    fn init(n: i64) SortState {
        return .{ .n = n, .start = @divFloor(n, 2), .end = n, .root = 0, .lim = 0, .child = 0, .extracting = false, .step = .heapify };
    }

    /// Where `run` carries on from: a step, or the pending comparison
    /// with its result in hand.
    const At = enum { heapify, extract, sift, pick, root, got_pick, got_root, sift_done };

    /// Run the sort until a comparison needs a Lua call, which it returns
    /// with the state saved at that comparison, or to the end (null).
    /// `result` is that comparison's, once its call is made; without one, a
    /// state saved at a comparison asks for it again.
    ///
    /// With a comparator `comp` (nil for none) every comparison is a call.
    /// Without one, `<` is taken as `lua_lessthan` takes it: numbers and
    /// strings compare raw, here, and anything else through `a`'s `__lt`,
    /// then `b`'s, as the `lt` instruction's `binMeta` does; with no handler
    /// it raises Lua's "attempt to compare …", unlocated, as Lua's sort (a C
    /// function) does.
    ///
    /// One labeled switch over a local copy, so the steps are direct jumps
    /// and the raw path runs as the plain loops would; compiled once with a
    /// comparator and once without.
    ///
    /// The swaps write `t` without checking that it is not frozen: only
    /// Lua code can freeze it, so the caller checks when the sort starts and
    /// after every call (`sortTable`).
    inline fn run(s: *SortState, vm: *Vm, t: *Table, comp: Value, result: ?bool) interp.Error!?SortCall {
        if (comp.isNil()) return s.runIn(vm, t, false, comp, result);
        return s.runIn(vm, t, true, comp, result);
    }

    inline fn runIn(s: *SortState, vm: *Vm, t: *Table, comptime has_comp: bool, comp: Value, result: ?bool) interp.Error!?SortCall {
        var x = s.*;
        defer s.* = x;
        var less = result orelse false;
        const from: At = if (result != null) switch (x.step) {
            .pick => .got_pick,
            .root => .got_root,
            .heapify, .extract, .sift => unreachable,
        } else switch (x.step) {
            .heapify => .heapify,
            .extract => .extract,
            .sift => .sift,
            .pick => .pick,
            .root => .root,
        };
        at: switch (from) {
            .heapify => {
                if (x.start < 1) {
                    x.extracting = true;
                    continue :at .extract;
                }
                x.root = x.start;
                x.lim = x.n;
                continue :at .sift;
            },
            .extract => {
                if (x.end <= 1) {
                    x.step = .extract;
                    return null;
                }
                try sortSwap(vm, t, 1, x.end);
                x.root = 1;
                x.lim = x.end - 1;
                continue :at .sift;
            },
            .sift => {
                if (x.root * 2 > x.lim) continue :at .sift_done;
                x.child = x.root * 2;
                if (x.child + 1 <= x.lim) continue :at .pick;
                continue :at .root;
            },
            .pick => {
                const l = t.get(Value.int(x.child));
                const r = t.get(Value.int(x.child + 1));
                less = rawLess(has_comp, l, r) orelse {
                    x.step = .pick;
                    return try sortCallOf(vm, has_comp, comp, l, r);
                };
                continue :at .got_pick;
            },
            .got_pick => {
                if (less) x.child += 1;
                continue :at .root;
            },
            .root => {
                const l = t.get(Value.int(x.root));
                const r = t.get(Value.int(x.child));
                less = rawLess(has_comp, l, r) orelse {
                    x.step = .root;
                    return try sortCallOf(vm, has_comp, comp, l, r);
                };
                continue :at .got_root;
            },
            .got_root => {
                if (!less) continue :at .sift_done;
                try sortSwap(vm, t, x.root, x.child);
                x.root = x.child;
                continue :at .sift;
            },
            .sift_done => {
                if (x.extracting) {
                    x.end -= 1;
                    continue :at .extract;
                }
                x.start -= 1;
                continue :at .heapify;
            },
        }
    }

    fn toWords(s: SortState) [native_act.max_words]i64 {
        var w: [native_act.max_words]i64 = @splat(0);
        w[0..word_count].* = .{ s.n, s.start, s.end, s.root, s.lim, s.child, @intFromBool(s.extracting), @intFromEnum(s.step) };
        return w;
    }

    fn fromWords(w: []const i64) SortState {
        return .{ .n = w[0], .start = w[1], .end = w[2], .root = w[3], .lim = w[4], .child = w[5], .extracting = w[6] != 0, .step = @enumFromInt(w[7]) };
    }

    /// Keep it in the registers from `at` on, as integers. `tagged` says
    /// they already are (a step that `load`ed them): only the payloads change
    /// then, which is half the stores per comparison.
    fn store(s: SortState, regs: RegWindow, at: usize, comptime tagged: bool) void {
        const w: [word_count]i64 = .{ s.n, s.start, s.end, s.root, s.lim, s.child, @intFromBool(s.extracting), @intFromEnum(s.step) };
        inline for (w, 0..) |x, k| {
            if (tagged) regs.payloads[at + k] = @bitCast(x) else regs.setInt(at + k, x);
        }
    }

    fn load(regs: RegWindow, at: usize) SortState {
        var w: [word_count]i64 = undefined;
        for (&w, at..) |*x, r| x.* = @bitCast(regs.bitsAt(r));
        return fromWords(&w);
    }
};

/// A comparison that needs a Lua call: `f(a, b)`, whose first result's
/// truthiness is `a < b`.
const SortCall = struct { f: Value, a: Value, b: Value };

/// `l < r` taken raw, or null when it needs a Lua call: always with a
/// comparator, and for anything but two numbers or two strings without.
inline fn rawLess(comptime has_comp: bool, l: Value, r: Value) ?bool {
    if (has_comp) return null;
    return arith.lt(l, r) catch null;
}

/// The call that decides `l < r` when `rawLess` can't.
inline fn sortCallOf(vm: *Vm, comptime has_comp: bool, comp: Value, l: Value, r: Value) interp.Error!SortCall {
    if (has_comp) return .{ .f = comp, .a = l, .b = r };
    return sortLtCall(vm, l, r);
}

/// The default comparator's `__lt` call, out of `run`'s raw path.
noinline fn sortLtCall(vm: *Vm, a: Value, b: Value) interp.Error!SortCall {
    const handler = ltHandler(vm, a) orelse ltHandler(vm, b) orelse {
        var buf: [arith.compare_fault_max]u8 = undefined;
        return vm.raiseLocatedError(arith.compareFaultText(&buf, a, b), 0);
    };
    return .{ .f = handler, .a = a, .b = b };
}

/// `v`'s `__lt` handler, or null when it has none.
fn ltHandler(vm: *Vm, v: Value) ?Value {
    const mt = vm.metatableOf(v) orelse return null;
    const h = mt.getHeap(vm.mm.lt);
    return if (h.isNil()) null else h;
}

/// Swap the 1-based array elements `i` and `j`, reading both fresh.
fn sortSwap(vm: *Vm, t: *Table, i: i64, j: i64) interp.Error!void {
    const vi = t.get(Value.int(i));
    const vj = t.get(Value.int(j));
    try t.set(vm.gpa, Value.int(i), vj);
    try t.set(vm.gpa, Value.int(j), vi);
}

/// Whether `v` can be called: a function, or a value with a `__call`.
fn isCallable(vm: *Vm, v: Value) bool {
    if (v.isHeap() and (v.heapType() == .function or v.heapType() == .native)) return true;
    const mt = vm.metatableOf(v) orelse return false;
    return !mt.getHeap(vm.mm.call).isNil();
}

/// The sort's table, as the sort finds it after a call. The comparator may
/// have frozen it, and from then on the sort may not write it, as nothing
/// may. It may have flattened it into a grid (doc 14), which a stdlib op
/// deflates first.
inline fn sortTable(vm: *Vm, v: Value) interp.Error!*Table {
    const t = Table.fromHeader(v.asHeap());
    if (t.isReadonly()) return vm.readonlyError();
    if (t.array.isGrid()) try vm.heap.deflateGrid(t);
    return t;
}

/// `table.sort(list[, comp])` — sort `list[1..#list]` in place; returns nothing.
/// A frozen `list` raises before anything else, even a short one, as Luau's.
/// The sort runs here until a comparison needs a Lua call; then it leaves
/// its state for its activation (doc 68 §5.1), which makes that call and
/// every later one as an ordinary call (`sortStep`). With no comparator and
/// no `__lt` it is all one native call.
fn tSort(ctx: *anyopaque, args: []const Value) anyerror!Value {
    const vm = vmOf(ctx);
    const t = try tableArg(vm, args, 0);
    if (t.isReadonly()) return vm.readonlyError();
    const comp: Value = if (given(args, 1)) args[1] else Value.nil();
    // Lua takes only a function; a callable table works too, as anywhere a
    // call is made.
    if (!comp.isNil() and !isCallable(vm, comp)) return vm.badArg(2, "function", comp);
    const n = t.length();
    if (n < 2) return Value.nil();
    var s = SortState.init(n);
    if (try s.run(vm, t, comp, null) == null) return Value.nil();
    vm.act_seed = .{ .kind = .sort, .words = s.toWords() };
    return error.ActivateNative;
}

/// One step of `table.sort`'s activation (`Vm.opNativeAct`): take the
/// result of the call it asked for (or, on its first step, the state the
/// native left), then run on to the next call, laid out in the call area,
/// or to the end. `R[0]` is the table and `R[1]` the comparator, as the
/// native was called.
pub fn sortStep(vm: *Vm, regs: RegWindow) interp.Error!native_act.Next {
    const at = native_act.wordReg(.sort);
    const c = native_act.callReg(.sort);
    const t = try sortTable(vm, regs.get(0));
    var s: SortState = undefined;
    var result: ?bool = null;
    const first = regs.get(at).isNil();
    if (first) {
        const seed = vm.takeActSeed();
        std.debug.assert(seed.kind == .sort);
        s = SortState.fromWords(&seed.words);
    } else {
        s = SortState.load(regs, at);
        result = regs.get(c).isTruthy();
    }
    const call = try s.run(vm, t, regs.get(1), result) orelse return .done;
    if (first) s.store(regs, at, false) else s.store(regs, at, true);
    regs.set(c, call.f);
    regs.set(c + 1, call.a);
    regs.set(c + 2, call.b);
    return .call;
}

/// `table.sort` called from Zig (`Vm.callValue`), where no activation can
/// be pushed: it finishes from the state the native left, making its calls
/// through `callValue` (`Vm.activationSync`).
pub fn sortSync(vm: *Vm, seed: native_act.Seed, args: []const Value) interp.Error!void {
    std.debug.assert(seed.kind == .sort);
    const comp: Value = if (given(args, 1)) args[1] else Value.nil();
    var s = SortState.fromWords(&seed.words);
    var result: ?bool = null;
    while (try s.run(vm, try sortTable(vm, args[0]), comp, result)) |call| {
        var r: [1]Value = .{Value.nil()};
        const n = try vm.callValue(call.f, &.{ call.a, call.b }, r[0..1]);
        result = n >= 1 and r[0].isTruthy();
    }
}

// ---------------------------------------------------------------------------
// table.freeze / table.isfrozen / table.clone — Luau's (doc 76 §5)
// ---------------------------------------------------------------------------

/// Whether `t`'s metatable is protected (has a `__metatable` field), which
/// `freeze` and `clone` refuse, as Luau's `luaL_getmetafield` checks do.
fn hasProtectedMetatable(vm: *Vm, t: *const Table) bool {
    const mt = t.metatable orelse return false;
    return !mt.get(vm.mm.metatable).isNil();
}

/// `table.freeze(t)` — make `t` read-only for good and return it: every later
/// store into it raises, `rawset`, `setmetatable` and the `table` functions
/// included. Shallow. Refuses a frozen `t` and a protected metatable.
fn tFreeze(ctx: *anyopaque, args: []const Value) anyerror!Value {
    const vm = vmOf(ctx);
    const t = try tableArg(vm, args, 0);
    if (t.isReadonly()) return vm.badArgReason(1, "table is already frozen");
    if (hasProtectedMetatable(vm, t)) return vm.badArgReason(1, "table has a protected metatable");
    t.header.flags.readonly = true;
    return args[0];
}

/// `table.isfrozen(t)` — whether `table.freeze` froze `t`.
fn tIsFrozen(ctx: *anyopaque, args: []const Value) anyerror!Value {
    const t = try tableArg(vmOf(ctx), args, 0);
    return Value.boolean(t.isReadonly());
}

/// `table.clone(t)` — a new table with `t`'s keys, values and metatable, never
/// frozen. Shallow; a copy of each part's representation (`Table.clone`), so
/// no rehash. Refuses a protected metatable.
fn tClone(ctx: *anyopaque, args: []const Value) anyerror!Value {
    const vm = vmOf(ctx);
    const t = try tableArg(vm, args, 0);
    if (hasProtectedMetatable(vm, t)) return vm.badArgReason(1, "table has a protected metatable");
    const copy = try vm.heap.cloneTable(t);
    return Value.heap(&copy.header);
}

pub const natives = [_]function.BaseNative{
    .{ .name = "table.insert", .func = &tInsert, .multi = function.noResults(&tInsert), .module = "table", .field = "insert" },
    .{ .name = "table.remove", .func = &tRemove, .module = "table", .field = "remove" },
    .{ .name = "table.concat", .func = &tConcat, .module = "table", .field = "concat" },
    .{ .name = "table.move", .func = &tMove, .module = "table", .field = "move" },
    .{ .name = "table.pack", .func = &tPack, .module = "table", .field = "pack" },
    .{ .name = "table.unpack", .func = &tUnpack1, .multi = &tUnpackN, .module = "table", .field = "unpack" },
    .{ .name = "table.sort", .func = &tSort, .multi = function.noResults(&tSort), .module = "table", .field = "sort" },
    .{ .name = "table.freeze", .func = &tFreeze, .module = "table", .field = "freeze" },
    .{ .name = "table.isfrozen", .func = &tIsFrozen, .module = "table", .field = "isfrozen" },
    .{ .name = "table.clone", .func = &tClone, .module = "table", .field = "clone" },
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

    // out.len caps the writes but not the count (fixed-count caller: local
    // a,b = unpack(t)); the VM truncates or overflows (`NativeMultiFn`).
    var two: [2]Value = undefined;
    n = try tUnpackN(@ptrCast(&vm), &.{seq}, &two);
    try testing.expectEqual(@as(usize, 3), n);
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

    // A table element is neither string nor number: Lua's "invalid value".
    const t = Table.fromHeader(seq.asHeap());
    const inner = try vm.heap.newTable();
    try t.set(vm.gpa, Value.int(2), Value.heap(&inner.header));
    try testing.expectError(error.LuaError, tConcat(@ptrCast(&vm), &.{ seq, sep }));
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
