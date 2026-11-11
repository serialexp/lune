//! Doc 77 Phase 1: traces on tables that carry a metatable, on the paths
//! that do not call a metamethod. Language level, through `expectProgram`
//! (two GC disciplines x five trace modes, every output the cross-tier
//! parity check), with `inspect` hooks asserting that the loops were
//! actually recorded, with the guard shapes §4 and §5 prescribe.

const std = @import("std");
const util = @import("interp_testutil.zig");
const interp = @import("interp.zig");
const trace_ir = @import("trace_ir.zig");
const basic = @import("stdlib/basic.zig");

const Vm = interp.Vm;
const TraceMode = util.TraceMode;
const testing = std.testing;
const expectProgram = util.expectProgram;
const expectProgramTuned = util.expectProgramTuned;

/// Ops across the VM's committed traces.
fn countOps(vm: *const Vm, op: trace_ir.IrOp) usize {
    var n: usize = 0;
    for (vm.trace.registry.cache.items) |t| {
        for (t.code.instrs) |ins| {
            if (ins.op == op) n += 1;
        }
    }
    return n;
}

/// `guard_table`s across the committed traces that allow a metatable.
fn countAnyMetaGuards(vm: *const Vm) usize {
    var n: usize = 0;
    for (vm.trace.registry.cache.items) |t| {
        for (t.code.instrs) |ins| {
            if (ins.op == .guard_table and ins.aux & trace_ir.GUARD_TABLE_ANY_META != 0) n += 1;
        }
    }
    return n;
}

fn recorded(mode: TraceMode) bool {
    return mode != .off;
}

fn executed(mode: TraceMode) bool {
    return mode == .record_execute_noopt or mode == .record_execute or mode == .record_execute_native;
}

/// The loop was recorded under ANY_META and its trace ran.
fn expectAnyMetaTraceRan(vm: *Vm, mode: TraceMode) anyerror!void {
    if (!recorded(mode)) return;
    try testing.expect(countAnyMetaGuards(vm) > 0);
    if (executed(mode)) try testing.expect(vm.trace.entries > 0);
}

/// As `expectAnyMetaTraceRan`, and a metamethod miss was proven with
/// `load_meta`.
fn expectMetaMissTraceRan(vm: *Vm, mode: TraceMode) anyerror!void {
    try expectAnyMetaTraceRan(vm, mode);
    if (recorded(mode)) try testing.expect(countOps(vm, .load_meta) > 0);
}

test "doc 77 §5.3: present-field reads and overwrites on objects with a class metatable record and run" {
    try expectProgramTuned(
        \\local P = {}
        \\P.__index = P
        \\local ps = {}
        \\for i = 1, 8 do ps[i] = setmetatable({ x = i, vx = 1 }, P) end
        \\local s = 0
        \\for _ = 1, 50 do
        \\  for i = 1, 8 do
        \\    local p = ps[i]
        \\    p.x = p.x + p.vx
        \\    s = s + p.x
        \\  end
        \\end
        \\print(s)
    , "12000\n", .{ .inspect = expectAnyMetaTraceRan });
}

/// The loop's trace ran native with its hash cell seeded at every entry
/// (`seed_hash_declines` is the doc 22 §B.6 witness of a declined seed,
/// which reruns the entry on tier-1a).
fn expectNativeSeededRead(vm: *Vm, mode: TraceMode) anyerror!void {
    try expectAnyMetaTraceRan(vm, mode);
    if (mode == .record_execute_native) {
        try testing.expect(vm.trace.native_entries > 0);
        try testing.expectEqual(@as(u64, 0), vm.trace.seed_hash_declines);
    }
}

test "doc 77 §4.1: a present field of a slot table with a metatable is seeded at entry and read natively" {
    // `seedHashCell` resolves the cell of a table with a metatable; the
    // trace's `guard_table` owns the metatable check. A declined seed would
    // rerun every entry on tier-1a. `o` is a parameter so the table is a
    // slot root (an upvalue root gets no entry seed).
    try expectProgramTuned(
        \\local P = { __index = { y = 0 } }
        \\local t = setmetatable({ x = 2 }, P)
        \\local function run(o)
        \\  local s = 0
        \\  for i = 1, 200 do s = s + o.x end
        \\  return s
        \\end
        \\local a = run(t)
        \\local b = run(t)
        \\print(a, b, t.y)
    , "400\t400\t0\n", .{ .inspect = expectNativeSeededRead });
}

test "doc 77 §5.3: an absent read on a table whose metatable has no __index reads nil, until __index appears" {
    try expectProgramTuned(
        \\local mt = {}
        \\local t = setmetatable({ a = 1 }, mt)
        \\local function run()
        \\  local n = 0
        \\  for i = 1, 200 do
        \\    local v = t.b
        \\    if v == nil then n = n + 1 else n = n + v end
        \\  end
        \\  return n
        \\end
        \\local r1 = run()
        \\mt.__index = { b = 2 }
        \\local r2 = run()
        \\mt.__index = nil
        \\local r3 = run()
        \\print(r1, r2, r3)
    , "200\t400\t200\n", .{ .inspect = expectMetaMissTraceRan });
}

test "doc 77 §5.3: an absent integer key on an array with a metatable, until __index appears" {
    try expectProgramTuned(
        \\local mt = {}
        \\local a = setmetatable({ 1, 2, 3 }, mt)
        \\local function run()
        \\  local n = 0
        \\  for i = 1, 200 do
        \\    local v = a[5]
        \\    if v == nil then n = n + a[2] else n = n + v end
        \\  end
        \\  return n
        \\end
        \\local r1 = run()
        \\mt.__index = function(_, k) return k * 10 end
        \\local r2 = run()
        \\print(r1, r2)
    , "400\t10000\n", .{ .inspect = expectMetaMissTraceRan });
}

test "doc 77 §9.2: setmetatable between trace entries sends the old trace back to tier 0" {
    try expectProgram(
        \\local t = { a = 1 }
        \\local function run()
        \\  local n = 0
        \\  for i = 1, 200 do
        \\    local v = t.b
        \\    if v == nil then n = n + t.a else n = n + v end
        \\  end
        \\  return n
        \\end
        \\local r1 = run()
        \\setmetatable(t, {})
        \\local r2 = run()
        \\setmetatable(t, { __index = function() return 3 end })
        \\local r3 = run()
        \\setmetatable(t, nil)
        \\local r4 = run()
        \\print(r1, r2, r3, r4)
    , "200\t200\t600\t200\n");
}

test "doc 77 §9.2: stores into the metatable and into other tables' __index fields inside the loop" {
    // The `mt.flag` read makes both stores sunk, so the miss's lookup of
    // `mt.__index` goes through the pending-store forwarding first.
    try expectProgramTuned(
        \\local mt = { flag = 0 }
        \\local t = setmetatable({}, mt)
        \\local o = { __index = 0 }
        \\local n = 0
        \\for i = 1, 200 do
        \\  mt.flag = mt.flag + 1
        \\  o.__index = i
        \\  if t.k == nil then n = n + 1 end
        \\end
        \\print(n, mt.flag, o.__index)
    , "200\t200\t200\n", .{ .inspect = expectMetaMissTraceRan });
}

test "doc 77 §9.2: a metatable on the metatable is not consulted by the lookup" {
    // `mt.k` goes through mt's own metatable, but the metamethod lookup on
    // `mt` is raw: `t.k` is nil.
    try expectProgramTuned(
        \\local mt = setmetatable({}, { __index = { k = 5, __index = { k = 7 } } })
        \\local t = setmetatable({}, mt)
        \\local n = 0
        \\for i = 1, 200 do
        \\  if t.k == nil then n = n + 1 end
        \\end
        \\print(n, mt.k, t.k)
    , "200\t5\tnil\n", .{ .inspect = expectMetaMissTraceRan });
}

test "doc 77 §9.2: a frozen receiver with a metatable reads on trace and still refuses a store" {
    try expectProgram(
        \\local P = {}
        \\P.__index = P
        \\local o = table.freeze(setmetatable({ x = 3 }, P))
        \\local s = 0
        \\for i = 1, 200 do s = s + o.x end
        \\local ok = pcall(function()
        \\  for i = 1, 200 do o.x = i end
        \\end)
        \\print(s, ok, o.x)
    , "600\tfalse\t3\n");
}

test "doc 77 §5.4: #t on a table with a metatable is the border until __len appears" {
    try expectProgramTuned(
        \\local mt = {}
        \\local t = setmetatable({ 1, 2, 3 }, mt)
        \\local function run()
        \\  local s = 0
        \\  for i = 1, 200 do s = s + #t end
        \\  return s
        \\end
        \\local r1 = run()
        \\mt.__len = function() return 10 end
        \\local r2 = run()
        \\print(r1, r2, rawlen(t))
    , "600\t2000\t3\n", .{ .inspect = expectMetaMissTraceRan });
}

test "doc 77 §5.3: array overwrites on a table with __newindex record; a store to a hole still calls it" {
    try expectProgramTuned(
        \\local log = 0
        \\local mt = { __newindex = function(t, k, v) log = log + 1; rawset(t, k, v) end }
        \\local a = setmetatable({}, mt)
        \\for i = 1, 10 do rawset(a, i, 0) end
        \\for r = 1, 20 do
        \\  for i = 1, 10 do a[i] = a[i] + i end
        \\end
        \\a[12] = 1
        \\local s = 0
        \\for i = 1, 10 do s = s + a[i] end
        \\print(s, log, a[12])
    , "1100\t1\t1\n", .{ .inspect = expectAnyMetaTraceRan });
}

test "doc 77 §5.4: raw builtins, type and math.type on tables with metamethods never call them" {
    // `math.type` is hoisted: a native builtin read as a table field aborts
    // the recording on any table (`hashGetShape`), metatable or not.
    try expectProgramTuned(
        \\local mt = { __index = function() return 99 end, __len = function() return 7 end }
        \\local arr = setmetatable({ 1, 2, 3 }, mt)
        \\local obj = setmetatable({ x = 4 }, mt)
        \\local mtype = math.type
        \\local s = 0
        \\for i = 1, 200 do
        \\  s = s + rawlen(arr) + (rawget(obj, "y") == nil and 1 or 0) + rawget(arr, 2)
        \\  if type(obj) == "table" and mtype(obj) == nil and rawequal(obj, obj) then s = s + 1 end
        \\  rawset(obj, "x", i)
        \\end
        \\print(s, obj.x, obj.y, #arr)
    , "1400\t200\t99\t7\n", .{ .inspect = expectAnyMetaTraceRan });
}

test "doc 77 §5.3: a matrix whose outer table has a metatable records as nested tables" {
    // A metatable keeps the matrix out of the grid lane (`inflateToGrid`
    // declines it, and every metatable writer deflates a grid first), so
    // `g[i]` is a present `.value`-lane read on a table with a metatable.
    // The row is read into a local (the fused `g[i][j]` records only on a
    // grid) and one loop visits every cell, 50 times each.
    try expectProgramTuned(
        \\local g = {}
        \\for i = 1, 4 do
        \\  g[i] = {}
        \\  for j = 1, 4 do g[i][j] = i + j end
        \\end
        \\setmetatable(g, { __index = function() return 0 end })
        \\local s = 0
        \\for k = 0, 799 do
        \\  local row = g[k % 4 + 1]
        \\  local j = k // 4 % 4 + 1
        \\  row[j] = row[j] + 1
        \\  s = s + row[j]
        \\end
        \\print(s, g[5])
    , "24400\t0\n", .{ .inspect = expectAnyMetaTraceRan });
}

test "doc 77 §4.2: setmetatable is not a recorded builtin, so no trace sets a metatable" {
    // The native prologue checks a table's metatable once per entry
    // (`SlotInfo.meta_ok`), and `load_meta` is not re-run after a store:
    // both rest on nothing on trace setting one. Tagging setmetatable must
    // revisit that first.
    var found = false;
    for (basic.natives) |n| {
        if (!std.mem.eql(u8, n.name, "setmetatable")) continue;
        found = true;
        try testing.expect(n.recorded == null);
    }
    try testing.expect(found);
}

// ---- Phase 3: `__index` and `__newindex` tables (doc 77 §6.2) ----

test "doc 77 §6.2: method and field lookups through a two-level class chain record and run" {
    try expectProgramTuned(
        \\local Base = {}
        \\Base.__index = Base
        \\function Base.get(self) return self.v end
        \\Base.scale = 3
        \\local Mid = setmetatable({}, Base)
        \\Mid.__index = Mid
        \\local o = setmetatable({ v = 2 }, Mid)
        \\local arr = setmetatable({}, { __index = { 10, 20, 30 } })
        \\local s = 0
        \\for i = 1, 300 do
        \\  s = s + o:get() * o.scale + arr[2]
        \\end
        \\print(s)
    , "7800\n", .{ .inspect = expectMetaMissTraceRan });
}

test "doc 77 §6.2: replacing, removing and shadowing the __index table between entries" {
    try expectProgramTuned(
        \\local A = { k = 1 }
        \\local B = { k = 2 }
        \\local mt = { __index = A }
        \\local o = setmetatable({}, mt)
        \\local function run()
        \\  local s = 0
        \\  for i = 1, 100 do
        \\    local v = o.k
        \\    if v == nil then s = s + 100 else s = s + v end
        \\  end
        \\  return s
        \\end
        \\local r1 = run()
        \\mt.__index = B
        \\local r2 = run()
        \\A.k = 5
        \\mt.__index = A
        \\local r3 = run()
        \\o.k = 7
        \\local r4 = run()
        \\o.k = nil
        \\mt.__index = nil
        \\local r5 = run()
        \\mt.__index = function() return 9 end
        \\local r6 = run()
        \\print(r1, r2, r3, r4, r5, r6)
    , "100\t200\t500\t700\t10000\t900\n", .{ .inspect = expectMetaMissTraceRan });
}

test "doc 77 §6.2: a store into the __index table inside the loop is seen by the next lookup" {
    // The `Base.n` store sinks below the read of `Base.n` through the
    // chain; the hop's read goes through the pending-store forwarding.
    try expectProgramTuned(
        \\local Base = { n = 0 }
        \\Base.__index = Base
        \\local o = setmetatable({}, Base)
        \\local s = 0
        \\for i = 1, 200 do
        \\  Base.n = Base.n + 1
        \\  s = s + o.n
        \\end
        \\print(s, Base.n, rawget(o, "n"))
    , "20100\t200\tnil\n", .{ .inspect = expectMetaMissTraceRan });
}

test "doc 77 §6.2: a function __index at the end of a table chain stops the recording, tier 0 calls it" {
    try expectProgram(
        \\local calls = 0
        \\local Top = setmetatable({}, { __index = function(_, k) calls = calls + 1; return 4 end })
        \\local o = setmetatable({}, { __index = Top })
        \\local s = 0
        \\for i = 1, 100 do s = s + o.z end
        \\print(s, calls)
    , "400\t100\n");
}

/// A chain of `n` tables, each the `__index` of the one before, the last
/// holding `k = 1`; the loop reads `k` through all of them.
fn chainProgram(comptime n: usize) [:0]const u8 {
    return std.fmt.comptimePrint(
        \\local last = {{ k = 1 }}
        \\local cur = last
        \\for i = 1, {d} do cur = setmetatable({{}}, {{ __index = cur }}) end
        \\local s = 0
        \\for i = 1, 50 do s = s + cur.k end
        \\print(s)
    , .{n});
}

fn expectNoIndexChainAbort(vm: *Vm, mode: TraceMode) anyerror!void {
    if (!recorded(mode)) return;
    for (vm.trace.abort_log.items) |r| try testing.expect(r.reason != .index_chain);
    try testing.expect(countOps(vm, .load_meta) >= MAX_INDEX_CHAIN);
}

fn expectIndexChainAbort(vm: *Vm, mode: TraceMode) anyerror!void {
    if (!recorded(mode)) return;
    var seen = false;
    for (vm.trace.abort_log.items) |r| {
        if (r.reason == .index_chain) seen = true;
    }
    try testing.expect(seen);
}

const MAX_INDEX_CHAIN = @import("trace_recorder.zig").RecordingSession.MAX_INDEX_CHAIN;

test "doc 77 Q2: a chain of MAX_INDEX_CHAIN hops records; one more aborts index_chain" {
    try expectProgramTuned(chainProgram(MAX_INDEX_CHAIN), "50\n", .{ .record_aborts = true, .inspect = expectNoIndexChainAbort });
    try expectProgramTuned(chainProgram(MAX_INDEX_CHAIN + 1), "50\n", .{ .record_aborts = true, .inspect = expectIndexChainAbort });
}

test "doc 77 §6.2: an absent key stores through a __newindex table, a present one overwrites in place" {
    try expectProgramTuned(
        \\local sink = { x = 0, [1] = 0 }
        \\local w = setmetatable({ y = 0 }, { __newindex = sink })
        \\for i = 1, 200 do
        \\  w.x = i
        \\  w[1] = i * 2
        \\  w.y = i
        \\end
        \\print(sink.x, sink[1], rawget(w, "x"), rawget(w, 1), w.y, sink.y)
    , "200\t400\tnil\tnil\t200\tnil\n", .{ .inspect = expectMetaMissTraceRan });
}

test "doc 77 §6.2: a __newindex chain into a table without the key inserts on tier 0" {
    try expectProgram(
        \\local sink = {}
        \\local w = setmetatable({}, { __newindex = sink })
        \\local n = 0
        \\for i = 1, 100 do
        \\  w["k" .. (i % 3)] = i
        \\  n = n + 1
        \\end
        \\print(n, sink.k0, sink.k1, sink.k2, rawget(w, "k0"))
    , "100\t99\t100\t98\tnil\n");
}

test "doc 77 §6.2: a frozen receiver still stores through its __newindex table; a frozen target refuses" {
    try expectProgram(
        \\local sink = { x = 0 }
        \\local w = table.freeze(setmetatable({}, { __newindex = sink }))
        \\for i = 1, 100 do w.x = i end
        \\table.freeze(sink)
        \\local ok = pcall(function()
        \\  for i = 1, 100 do w.x = i end
        \\end)
        \\print(sink.x, ok)
    , "100\tfalse\n");
}

test "doc 77 §6.2: an __index chain into a grid reads it on tier 0 without recording the hop" {
    try expectProgram(
        \\local g = {}
        \\for i = 1, 4 do
        \\  g[i] = {}
        \\  for j = 1, 4 do g[i][j] = i * j end
        \\end
        \\local s = 0
        \\for r = 1, 10 do
        \\  for i = 1, 4 do s = s + g[i][2] end
        \\end
        \\local o = setmetatable({}, { __index = g })
        \\for i = 1, 100 do s = s + o[2][3] end
        \\print(s)
    , "800\n");
}

// ---- Phase 2: invariant lookups leave the loop body (doc 77 §5.5) ----

/// `op`s before (`pre`) and after (`body`) the preheader marker, across the
/// committed traces. A trace without a marker counts wholly as body.
const Placement = struct { pre: usize = 0, body: usize = 0 };

fn placementOf(vm: *const Vm, op: trace_ir.IrOp) Placement {
    var out: Placement = .{};
    for (vm.trace.registry.cache.items) |t| {
        var marker: ?usize = null;
        for (t.code.instrs, 0..) |ins, i| {
            if (ins.op == .preheader) {
                marker = i;
                break;
            }
        }
        for (t.code.instrs, 0..) |ins, i| {
            if (ins.op != op) continue;
            if (marker != null and i < marker.?) out.pre += 1 else out.body += 1;
        }
    }
    return out;
}

/// The modes whose committed traces went through tropt.
fn optimized(mode: TraceMode) bool {
    return mode == .record_execute or mode == .record_execute_native;
}

/// The whole chain read runs once per entry: no miss proof or metatable
/// load is left in the body. (A store's own `guard_hash` stays there.)
fn expectChainHoisted(vm: *Vm, mode: TraceMode) anyerror!void {
    try expectMetaMissTraceRan(vm, mode);
    if (!optimized(mode)) return;
    for ([_]trace_ir.IrOp{ .load_meta, .guard_absent }) |op| {
        const pl = placementOf(vm, op);
        try testing.expect(pl.pre > 0);
        try testing.expectEqual(@as(usize, 0), pl.body);
    }
    if (mode == .record_execute_native) try testing.expect(vm.trace.native_entries > 0);
}

test "doc 77 §5.5: a chain read of an invariant receiver runs once per entry" {
    // `o.scale` is two hops; nothing in the loop stores to a table. The
    // two lookups share `load_meta o` (CSE) and run before the loop.
    try expectProgramTuned(
        \\local Base = { scale = 3 }
        \\Base.__index = Base
        \\local Mid = setmetatable({}, Base)
        \\Mid.__index = Mid
        \\local o = setmetatable({}, Mid)
        \\local s = 0
        \\for i = 1, 300 do
        \\  s = s + o.scale + o.scale
        \\end
        \\print(s)
    , "1800\n", .{ .inspect = expectChainHoisted });
}

/// The chain's hops are hoisted, and an `hload` stays in the body.
fn expectHopsHoistedReadInBody(vm: *Vm, mode: TraceMode) anyerror!void {
    try expectMetaMissTraceRan(vm, mode);
    if (!optimized(mode)) return;
    try testing.expectEqual(@as(usize, 0), placementOf(vm, .load_meta).body);
    try testing.expect(placementOf(vm, .hload).body > 0);
}

test "doc 77 §5.5: a store to the key a chain reads keeps that read in the loop" {
    // `Base.n` is stored every iteration and read through `o`'s chain; the
    // hops are invariant, the final read is not.
    try expectProgramTuned(
        \\local Base = { n = 0 }
        \\Base.__index = Base
        \\local o = setmetatable({}, Base)
        \\local s = 0
        \\for i = 1, 200 do
        \\  s = s + o.n
        \\  Base.n = i
        \\end
        \\print(s, Base.n)
    , "19900\t200\n", .{ .inspect = expectHopsHoistedReadInBody });
}

test "doc 77 §5.5: a store to another key leaves the chain read hoisted" {
    try expectProgramTuned(
        \\local Base = { scale = 3, other = 0 }
        \\Base.__index = Base
        \\local Mid = setmetatable({}, Base)
        \\Mid.__index = Mid
        \\local o = setmetatable({}, Mid)
        \\local s = 0
        \\for i = 1, 300 do
        \\  s = s + o.scale
        \\  Base.other = i
        \\end
        \\print(s, Base.other)
    , "900\t300\n", .{ .inspect = expectChainHoisted });
}

test "doc 77 §5.5: the hoisted chain is read again at every entry" {
    // At i == 100 tier 0 replaces the `__index` table; the trace exits on
    // that branch, and the next entry runs its preheader against B.
    try expectProgramTuned(
        \\local A = { k = 1 }
        \\local B = { k = 2 }
        \\local mt = { __index = A }
        \\local o = setmetatable({}, mt)
        \\local s = 0
        \\for i = 1, 200 do
        \\  if i == 100 then mt.__index = B end
        \\  s = s + o.k
        \\end
        \\print(s)
    , "301\n", .{ .inspect = expectMetaMissTraceRan });
}

/// An integer-key `guard_absent` stays in the body.
fn expectIntAbsentInBody(vm: *Vm, mode: TraceMode) anyerror!void {
    try expectMetaMissTraceRan(vm, mode);
    if (!optimized(mode)) return;
    try testing.expect(placementOf(vm, .guard_absent).body > 0);
    try testing.expectEqual(@as(usize, 0), placementOf(vm, .load_meta).body);
}

test "doc 77 §5.5: an absent integer key stays checked in a loop that stores to an array" {
    // A store to any array may fill the hole, so the absence is not
    // hoisted; the `__index` hop still is. (An append after the absent
    // read aborts `store_after_load` today, so the store is an overwrite.)
    try expectProgramTuned(
        \\local t = setmetatable({}, { __index = { 5 } })
        \\local out = { 0, 0, 0, 0 }
        \\local s = 0
        \\for i = 1, 200 do
        \\  out[2] = i
        \\  s = s + t[1]
        \\end
        \\print(s, out[2])
    , "1000\t200\n", .{ .inspect = expectIntAbsentInBody });
}

test "doc 77 §5.5: a hoisted heap value outlives collections inside the loop" {
    // `tostring` allocates every iteration, so the collector runs inside
    // the loop on the stress legs; the hoisted method and its class stay
    // reachable through `o`'s metatable.
    try expectProgram(
        \\local C = {}
        \\C.__index = C
        \\function C.get(self) return self.v end
        \\local o = setmetatable({ v = 3 }, C)
        \\local n = 0
        \\for i = 1, 300 do
        \\  n = n + o:get() + #tostring(i)
        \\end
        \\print(n)
    , "1692\n");
}

// ---- Phase 4: a method's upvalues (doc 77 §6.6) ----

/// The traces read a method's upvalue with `uvload`.
fn expectUvload(vm: *Vm, mode: TraceMode) anyerror!void {
    if (!recorded(mode)) return;
    try testing.expect(countOps(vm, .uvload) > 0);
    if (mode == .record_execute_native) try testing.expect(vm.trace.native_entries > 0);
}

/// As `expectUvload`, with every `uvload` before the loop.
fn expectUvloadHoisted(vm: *Vm, mode: TraceMode) anyerror!void {
    try expectUvload(vm, mode);
    if (!optimized(mode)) return;
    const pl = placementOf(vm, .uvload);
    try testing.expect(pl.pre > 0);
    try testing.expectEqual(@as(usize, 0), pl.body);
}

/// As `expectUvload`, with a `uvload` in the loop.
fn expectUvloadInBody(vm: *Vm, mode: TraceMode) anyerror!void {
    try expectUvload(vm, mode);
    if (optimized(mode)) try testing.expect(placementOf(vm, .uvload).body > 0);
}

test "doc 77 §6.6: a method found through __index reads its closed upvalue once per entry" {
    try expectProgramTuned(
        \\local function factory()
        \\  local k = 3
        \\  local C = {}
        \\  C.__index = C
        \\  function C.get(self) return self.v + k end
        \\  local function run(o, n)
        \\    local s = 0
        \\    for i = 1, n do s = s + o:get() end
        \\    return s
        \\  end
        \\  return run, setmetatable({ v = 1 }, C)
        \\end
        \\local run, o = factory()
        \\print(run(o, 300), run(o, 10))
    , "1200\t40\n", .{ .inspect = expectUvloadHoisted });
}

test "doc 77 §6.6: an upvalue store in the loop keeps the method's upvalue read in it" {
    // `acc` is `run`'s own cell, stored every iteration (`ustore`); the
    // method's `k` is another cell, but a store to any cell keeps every
    // `uvload` in the loop.
    try expectProgramTuned(
        \\local function factory()
        \\  local k = 3
        \\  local acc = 0
        \\  local C = {}
        \\  C.__index = C
        \\  function C.get(self) return self.v + k end
        \\  local function run(o, n)
        \\    for i = 1, n do acc = acc + o:get() end
        \\    return acc
        \\  end
        \\  return run, setmetatable({ v = 1 }, C)
        \\end
        \\local run, o = factory()
        \\print(run(o, 300))
    , "1200\n", .{ .inspect = expectUvloadInBody });
}

test "doc 77 §6.6: a cell open below the anchor is read in place, and again at the next entry" {
    // `k` is main's local, open while `run` loops; main changes it between
    // the two calls.
    try expectProgramTuned(
        \\local k = 2
        \\local C = {}
        \\C.__index = C
        \\function C.get(self) return self.v * k end
        \\local function run(o)
        \\  local s = 0
        \\  for i = 1, 300 do s = s + o:get() end
        \\  return s
        \\end
        \\local o = setmetatable({ v = 5 }, C)
        \\local a = run(o)
        \\k = 7
        \\local b = run(o)
        \\print(a, b)
    , "3000\t10500\n", .{ .inspect = expectUvloadHoisted });
}

/// No trace read an upvalue with `uvload`.
fn expectNoUvload(vm: *Vm, mode: TraceMode) anyerror!void {
    _ = mode;
    try testing.expectEqual(@as(usize, 0), countOps(vm, .uvload));
}

test "doc 77 §6.6: a method's cell open over the anchor's own window stops the recording" {
    // `k` lives in the loop's frame, which the trace keeps in registers;
    // tier 0 runs the loop, and sees the store at i == 150.
    try expectProgramTuned(
        \\local k = 2
        \\local C = {}
        \\C.__index = C
        \\function C.get(self) return self.v * k end
        \\local o = setmetatable({ v = 5 }, C)
        \\local s = 0
        \\for i = 1, 300 do
        \\  if i == 150 then k = 3 end
        \\  s = s + o:get()
        \\end
        \\print(s)
    , "3755\n", .{ .inspect = expectNoUvload });
}

test "doc 77 §6.6: table, string and native upvalues of a method, across collections" {
    // `tostring` allocates every iteration, so the stress legs collect
    // inside the loop. Main stores into `cfg` between the two runs.
    try expectProgramTuned(
        \\local function factory()
        \\  local cfg = { scale = 2 }
        \\  local name = "abc"
        \\  local floor = math.floor
        \\  local C = {}
        \\  C.__index = C
        \\  function C.get(self) return floor(self.v / 2) * cfg.scale + #name end
        \\  local function run(o, n)
        \\    local s = 0
        \\    for i = 1, n do s = s + o:get() + #tostring(i) end
        \\    return s
        \\  end
        \\  return run, setmetatable({ v = 9 }, C), cfg
        \\end
        \\local run, o, cfg = factory()
        \\local a = run(o, 300)
        \\cfg.scale = 10
        \\print(a, run(o, 300))
    , "4092\t13692\n", .{ .inspect = expectUvloadHoisted });
}
