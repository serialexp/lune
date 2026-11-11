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
const bytecode = @import("bytecode.zig");

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

/// A function metamethod was inlined: the loop's trace loads it from the
/// metatable (`load_meta`), pins it (`guard_func`) and ran.
fn expectMetaCallRan(vm: *Vm, mode: TraceMode) anyerror!void {
    if (!recorded(mode)) return;
    try testing.expect(countOps(vm, .load_meta) > 0);
    try testing.expect(countOps(vm, .guard_func) > 0);
    if (executed(mode)) try testing.expect(vm.trace.entries > 0);
}

test "doc 77 Phase 4: a function __index at the end of a table chain is called on the trace" {
    // The handler's state lives in a closed cell (`counter`); a cell open
    // over the anchor's own window still stops the recording (§6.6).
    try expectProgramTuned(
        \\local function counter()
        \\  local c = { n = 0 }
        \\  return c, function(_, k) c.n = c.n + 1; return 4 end
        \\end
        \\local c, h = counter()
        \\local Top = setmetatable({}, { __index = h })
        \\local o = setmetatable({}, { __index = Top })
        \\local s = 0
        \\for i = 1, 100 do s = s + o.z end
        \\print(s, c.n)
    , "400\t100\n", .{ .inspect = expectMetaCallRan });
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

/// A computed callee's cell open over the anchor's window was read as
/// the slot (`guard_uvslot`), not through the cell (`uvload`).
fn expectSlotAliasRead(vm: *Vm, mode: TraceMode) anyerror!void {
    try expectNoUvload(vm, mode);
    if (!recorded(mode)) return;
    try testing.expect(countOps(vm, .guard_uvslot) > 0);
    if (executed(mode)) try testing.expect(vm.trace.entries > 0);
}

test "doc 77 §6.6: a method's cell open over the anchor's own window reads the slot, with its stores" {
    // `k` lives in the loop's frame, which the trace keeps in registers:
    // the method reads the slot's value on the trace, so it sees the store
    // at i == 150 in order.
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
    , "3755\n", .{ .inspect = expectSlotAliasRead });
}

/// The first run's trace read the cell as its slot. Where traces run, the
/// second run fails that guard and its recording reads the closed cell
/// through the closure.
fn expectSlotAliasThenUvload(vm: *Vm, mode: TraceMode) anyerror!void {
    if (!recorded(mode)) return;
    try testing.expect(countOps(vm, .guard_uvslot) > 0);
    if (executed(mode)) try testing.expect(countOps(vm, .uvload) > 0);
}

test "doc 77 §6.6: a method over an earlier activation's closed cell fails the slot guard" {
    // `C.get` closes over `run`'s `k`. The second call keeps the first
    // call's closure, whose cell closed when that call returned: the same
    // proto, so `guard_func` passes, and `guard_uvslot` sends it to tier 0.
    try expectProgramTuned(
        \\local C = {}
        \\C.__index = C
        \\local function run(o, k, redefine)
        \\  if redefine then
        \\    function C.get(self) return self.v * k end
        \\  end
        \\  local s = 0
        \\  for i = 1, 200 do
        \\    if i == 100 then k = k + 1 end
        \\    s = s + o:get()
        \\  end
        \\  return s
        \\end
        \\local o = setmetatable({ v = 5 }, C)
        \\local r1 = run(o, 2, true)
        \\local r2 = run(o, 7, false)
        \\local r3 = run(o, 4, true)
        \\print(r1, r2, r3)
    , "2505\t3000\t4505\n", .{ .inspect = expectSlotAliasThenUvload });
}

test "doc 77 §6.6: a proxy whose __index and __newindex functions close over the loop's locals" {
    // The `bench/meta_proxy.lua` shape: the handlers read the loop frame's
    // `store`, `defaults` and `scale`, which the loop changes at i == 200.
    try expectProgramTuned(
        \\local store = { count = 0 }
        \\local defaults = { step = 3 }
        \\local scale = 1
        \\local proxy = setmetatable({}, {
        \\  __index = function(_, k)
        \\    local v = store[k]
        \\    if v == nil then v = defaults[k] end
        \\    return v * scale
        \\  end,
        \\  __newindex = function(_, k, v) store[k] = v end,
        \\})
        \\local s = 0
        \\for i = 1, 300 do
        \\  if i == 200 then scale = 2 end
        \\  proxy.count = (proxy.count + proxy.step) % 997
        \\  s = s + proxy.count
        \\end
        \\print(s, store.count)
    , "162290\t127\n", .{ .inspect = expectSlotAliasRead });
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

// ---- Phase 4: function `__index` and `__newindex` (doc 77 §6.1) ----

test "doc 77 Phase 4: a function __index gets the key as the instruction read it" {
    // `a[i / 1]` passes a float key; tier 0 does not narrow it for the call.
    try expectProgramTuned(
        \\local function mk()
        \\  local mtype = math.type
        \\  return { __index = function(t, k) if mtype(k) == "float" then return 1 end return 2 end }
        \\end
        \\local a = setmetatable({}, mk())
        \\local s = 0
        \\for i = 1, 200 do
        \\  s = s + a[i] + a[i / 1] + a["x"]
        \\end
        \\print(s)
    , "1000\n", .{ .inspect = expectMetaCallRan });
}

test "doc 77 Phase 4: a function __newindex takes any value, nil and tables included, and stores nothing" {
    try expectProgramTuned(
        \\local function sink()
        \\  local seen = { tables = 0, nils = 0, strs = 0 }
        \\  return seen, function(t, k, v)
        \\    local ty = type(v)
        \\    if ty == "nil" then seen.nils = seen.nils + 1
        \\    elseif ty == "table" then seen.tables = seen.tables + 1
        \\    else seen.strs = seen.strs + 1 end
        \\  end
        \\end
        \\local seen, h = sink()
        \\local o = setmetatable({}, { __newindex = h })
        \\local arr = setmetatable({}, { __newindex = h })
        \\local box = {}
        \\for i = 1, 200 do
        \\  o.k = box
        \\  o.k = nil
        \\  arr[i] = "s"
        \\end
        \\print(seen.tables, seen.nils, seen.strs, rawget(o, "k"), #arr)
    , "200\t200\t200\tnil\t0\n", .{ .inspect = expectMetaCallRan });
}

test "doc 77 Phase 4: replacing the __index function between entries, by one of the same or another proto, or a table" {
    // `scaled(2)` and `scaled(3)` share a proto: `guard_func` passes and the
    // factor is read through the new closure (§6.6). Another proto fails
    // the guard; a table chain ending in a function takes the hop first.
    try expectProgramTuned(
        \\local function scaled(f)
        \\  return function(_, k) return k * f end
        \\end
        \\local mt = { __index = scaled(2) }
        \\local o = setmetatable({}, mt)
        \\local function run()
        \\  local s = 0
        \\  for i = 1, 100 do s = s + o[i] end
        \\  return s
        \\end
        \\local r1 = run()
        \\mt.__index = scaled(3)
        \\local r2 = run()
        \\mt.__index = function(_, k) return -k end
        \\local r3 = run()
        \\mt.__index = setmetatable({ [1] = 1000 }, { __index = scaled(1) })
        \\local r4 = run()
        \\print(r1, r2, r3, r4)
    , "10100\t15150\t-5050\t6049\n", .{ .inspect = expectMetaCallRan });
}

test "doc 77 §7: an exit inside a function __index runs the handler once per iteration" {
    // The branch in the handler turns at k = 151: its guard exits coarse,
    // tier 0 re-runs the iteration, and the count stays one per read.
    try expectProgramTuned(
        \\local function mk()
        \\  local c = { n = 0 }
        \\  return c, function(_, k)
        \\    c.n = c.n + 1
        \\    if k > 150 then return 10 end
        \\    return 1
        \\  end
        \\end
        \\local c, h = mk()
        \\local o = setmetatable({}, { __index = h })
        \\local s = 0
        \\for i = 1, 300 do s = s + o[i] end
        \\print(s, c.n)
    , "1650\t300\n", .{ .inspect = expectMetaCallRan });
}

test "doc 77 Phase 4: a function __index that reads through another function __index" {
    try expectProgramTuned(
        \\local function mk()
        \\  local inner = setmetatable({}, { __index = function(_, k) return k + 1 end })
        \\  return setmetatable({}, { __index = function(_, k) return inner[k] * 2 end })
        \\end
        \\local outer = mk()
        \\local s = 0
        \\for i = 1, 200 do s = s + outer[i] end
        \\print(s)
    , "40600\n", .{ .inspect = expectMetaCallRan });
}

test "doc 77 Phase 4: a vararg or native __index, and a handler that allocates, stay with tier 0" {
    // A vararg handler's extra arguments are not modelled (`cross_frame`);
    // a native is called in place by tier 0; an allocating handler needs a
    // precise recording, which inlines nothing (doc 45).
    try expectProgram(
        \\local va = setmetatable({}, { __index = function(...) return select("#", ...) end })
        \\local nat = setmetatable({ q = 5 }, { __index = rawget })
        \\local s = 0
        \\for i = 1, 200 do s = s + va[i] + (nat[i] or 1) end
        \\print(s)
    , "600\n");
    try expectProgram(
        \\local function mk()
        \\  local made = { n = 0 }
        \\  return made, function(_, k) made.n = made.n + 1; return { k, k + 1 } end
        \\end
        \\local made, h = mk()
        \\local o = setmetatable({}, { __index = h })
        \\local s = 0
        \\for i = 1, 300 do
        \\  local p = o[i]
        \\  s = s + p[1] + p[2]
        \\end
        \\print(s, made.n)
    , "90600\t300\n");
}

// ---- Phase 4: operator metamethods (doc 77 §6.4) ----

test "doc 77 Phase 4: every arithmetic and bitwise operator, __unm and __bnot call their handler on the trace" {
    // Each handler sees its operands in source order (`val(a) * 10 -
    // val(b)`), constants included, and the unary ones get the operand
    // twice. `1.5 & v` asks `v`'s handler: a float has no integer form.
    try expectProgramTuned(
        \\local function val(x) if type(x) == "table" then return x.x end return x end
        \\local V = {}
        \\for _, n in ipairs({ "add", "sub", "mul", "div", "mod", "pow", "idiv", "band", "bor", "bxor", "shl", "shr", "sar" }) do
        \\  local w = #n
        \\  V["__" .. n] = function(a, b) return val(a) * 10 - val(b) + w end
        \\end
        \\V.__unm = function(a, b) return val(a) * 100 + val(b) end
        \\V.__bnot = function(a, b) return val(a) - val(b) + 1 end
        \\local v = setmetatable({ x = 3 }, V)
        \\local w = setmetatable({ x = 4 }, V)
        \\local s = 0
        \\for i = 1, 200 do
        \\  local k = i % 7
        \\  s = s + (v + w) + (v - k) + (k * w) + (v / 2) + (5 % w) + (v ^ w) + (k // v)
        \\  s = s + (v & w) + (k | v) + (w ~ 1) + (v << k) + (k >> w) + (v ~>> 2)
        \\  s = s + (-v) + (~w) + (1.5 & v)
        \\end
        \\print(s)
    , "148124\n", .{ .inspect = expectMetaCallRan });
}

test "doc 77 Phase 4: the first operand's handler wins, and a change to which one applies exits" {
    // `l` first has no metatable, then one without `__add` (both: `b`'s
    // handler, from either side), then one with it (`l`'s, on its side);
    // `B.__add` is replaced last.
    try expectProgramTuned(
        \\local A = { __add = function(a, b) return 1 end }
        \\local B = { __add = function(a, b) return 100 end }
        \\local plain = {}
        \\local nomm = setmetatable({}, { __sub = function() return 0 end })
        \\local b = setmetatable({}, B)
        \\local function run(l)
        \\  local s = 0
        \\  for i = 1, 100 do s = s + (l + b) + (b + l) end
        \\  return s
        \\end
        \\local r1 = run(plain)
        \\local r2 = run(nomm)
        \\setmetatable(plain, A)
        \\local r3 = run(plain)
        \\getmetatable(nomm).__add = function(a, b) return 7 end
        \\local r4 = run(nomm)
        \\B.__add = function(a, b) return 2 end
        \\local r5 = run(nomm)
        \\print(r1, r2, r3, r4, r5)
    , "20000\t20000\t10100\t10700\t900\n", .{ .inspect = expectMetaCallRan });
}

test "doc 77 Phase 4: a function __len is called with the table twice; rawlen and a removed __len read the border" {
    try expectProgramTuned(
        \\local L = { __len = function(t, u) return rawlen(t) * 10 + rawlen(u) end }
        \\local t = setmetatable({ 1, 2, 3 }, L)
        \\local function run()
        \\  local s = 0
        \\  for i = 1, 100 do s = s + #t + rawlen(t) end
        \\  return s
        \\end
        \\local r1 = run()
        \\L.__len = nil
        \\local r2 = run()
        \\L.__len = function(t) return 5 end
        \\local r3 = run()
        \\print(r1, r2, r3)
    , "3600\t600\t800\n", .{ .inspect = expectMetaCallRan });
}

test "doc 77 §7: an exit inside an arithmetic handler runs it once per iteration" {
    try expectProgramTuned(
        \\local function mk()
        \\  local c = { n = 0 }
        \\  return c, function(a, b)
        \\    c.n = c.n + 1
        \\    if b > 150 then return 10 end
        \\    return 1
        \\  end
        \\end
        \\local c, h = mk()
        \\local o = setmetatable({}, { __add = h })
        \\local s = 0
        \\for i = 1, 300 do s = s + (o + i) end
        \\print(s, c.n)
    , "1650\t300\n", .{ .inspect = expectMetaCallRan });
}

test "doc 77 Phase 4: a native operator handler, and an operand with no handler, stay with tier 0" {
    try expectProgram(
        \\local N = setmetatable({ 1, 2 }, { __unm = rawlen, __add = math.max })
        \\local s = 0
        \\for i = 1, 200 do s = s + -N end
        \\local ok = pcall(function()
        \\  local p = setmetatable({}, {})
        \\  for i = 1, 100 do s = s + (p + i) end
        \\end)
        \\print(s, ok)
    , "400\tfalse\n");
}

test "doc 77 Phase 4: __lt and __le in every value and branch form, and == over tables" {
    // `v > k` asks `__lt(k, v)` and `k >= w` asks `__le(w, k)` (relation
    // order), which an asymmetric handler tells apart. `v == u` calls
    // `__eq`; `v == v` and two plain tables compare by identity; a table
    // against nil folds to false.
    try expectProgramTuned(
        \\local function val(x) if type(x) == "table" then return x.x end return x end
        \\local V = {}
        \\V.__lt = function(a, b) return val(a) < val(b) end
        \\V.__le = function(a, b) return val(a) <= val(b) end
        \\V.__eq = function(a, b) return val(a) == val(b) end
        \\local v = setmetatable({ x = 3 }, V)
        \\local w = setmetatable({ x = 4 }, V)
        \\local u = setmetatable({ x = 3 }, V)
        \\local plain, other = {}, {}
        \\local s = 0
        \\for i = 1, 200 do
        \\  local k = i % 7
        \\  if v < w then s = s + 1 end
        \\  if w <= v then s = s + 2 end
        \\  if v > k then s = s + 4 end
        \\  if k >= w then s = s + 8 end
        \\  if v == u then s = s + 16 end
        \\  if v ~= w then s = s + 32 end
        \\  if v == v then s = s + 64 end
        \\  if plain == other then s = s + 128 end
        \\  if plain ~= plain then s = s + 256 end
        \\  if v == nil then s = s + 512 end
        \\  local a, b, c, d, e = v < w, v <= k, v == u, v ~= u, w > v
        \\  if a then s = s + 1000 end
        \\  if b then s = s + 2000 end
        \\  if c then s = s + 4000 end
        \\  if d then s = s + 8000 end
        \\  if e then s = s + 16000 end
        \\end
        \\print(s)
    , "4451624\n", .{ .inspect = expectMetaCallRan });
}

/// Doc 77 §7: the branch a compare handler's result takes is an ordinary
/// attachable exit that resumes at a successor of the compare-and-branch,
/// never at the instruction itself (which would call the handler again).
fn expectCompareBranchAttachable(vm: *Vm, mode: TraceMode) anyerror!void {
    try expectMetaCallRan(vm, mode);
    if (!recorded(mode)) return;
    var seen: usize = 0;
    for (vm.trace.registry.cache.items) |t| {
        const c = &t.code;
        for (0..c.instrs.len) |e| {
            if (c.instrs[e].op != .guard_true and c.instrs[e].op != .guard_false) continue;
            const b = c.anchorSourcePc(e) orelse continue;
            if (c.anchor.proto.code[b].op != .jlt) continue;
            const p = c.exitResumePc(e) orelse continue;
            const cb = bytecode.condBranchOf(c.anchor.proto.code[b], b).?;
            try testing.expect(p == b + 1 or p == cb.target);
            seen += 1;
        }
    }
    try testing.expect(seen > 0);
}

test "doc 77 §7: a compare handler whose answer turns runs once per iteration, and its branch exit attaches" {
    try expectProgramTuned(
        \\local function mk()
        \\  local c = { n = 0 }
        \\  return c, function(a, b)
        \\    c.n = c.n + 1
        \\    return a.x < b.x
        \\  end
        \\end
        \\local c, h = mk()
        \\local M = { __lt = h }
        \\local a = setmetatable({ x = 0 }, M)
        \\local b = setmetatable({ x = 150 }, M)
        \\local s = 0
        \\for i = 1, 300 do
        \\  a.x = i
        \\  if a < b then s = s + 1 else s = s + 10 end
        \\end
        \\print(s, c.n)
    , "1659\t300\n", .{ .inspect = expectCompareBranchAttachable });
}

/// What `expectExitContract` saw: guards inside a handler (route 1), guards
/// of an instruction after its handler returned (route 2), and attachable
/// exits after a handler at a later instruction (route 3).
const ExitRoutes = struct { inlined: usize = 0, mid: usize = 0, later_attachable: usize = 0 };

/// Doc 77 §7, read off each committed trace's exit provenance. Route 1: a
/// guard at inline depth > 0 is coarse; it attaches nowhere, names no
/// anchor source pc (which sibling handoff and the bridge classifiers go
/// through) and is no bridge candidate. Route 2: a depth-0 guard of an
/// instruction whose handler was inlined, placed after that handler, is
/// coarse too, except a compare-and-branch's branch, which attaches at a
/// successor and never at the instruction (§7 amendment). Route 3: a guard
/// of a later instruction attaches as any guard does.
fn exitRoutes(vm: *Vm) !ExitRoutes {
    var seen: ExitRoutes = .{};
    for (vm.trace.registry.cache.items) |t| {
        const c = &t.code;
        const proto = c.anchor.proto;
        var body: usize = 0;
        for (c.instrs, 0..) |ins, i| if (ins.op == .preheader) {
            body = i;
            break;
        };
        // The first body index of an inlined handler, by its call pc in
        // the anchor frame.
        const first = try testing.allocator.alloc(?usize, proto.code.len);
        defer testing.allocator.free(first);
        @memset(first, null);
        var last_call: usize = 0;
        for (c.exit_prov) |e| {
            const gp = switch (e.prov) {
                .guard => |g| g,
                .link_terminal => continue,
            };
            if (gp.inline_depth == 0) continue;
            try testing.expect(!c.exitAttachable(e.index));
            try testing.expect(c.exitResumePc(e.index) == null);
            try testing.expect(c.anchorSourcePc(e.index) == null);
            try testing.expect(!c.isBridgeCandidate(e.index));
            seen.inlined += 1;
            const edge = gp.path[0];
            if (edge.caller_proto_id != proto.id or e.index < body or edge.call_pc >= first.len) continue;
            if (first[edge.call_pc] == null) first[edge.call_pc] = e.index;
            last_call = @max(last_call, e.index);
        }
        for (c.exit_prov) |e| {
            const gp = switch (e.prov) {
                .guard => |g| g,
                .link_terminal => continue,
            };
            if (gp.inline_depth != 0 or gp.source_proto_id != proto.id or gp.source_pc >= first.len) continue;
            if (first[gp.source_pc]) |f| if (e.index > f) {
                seen.mid += 1;
                if (gp.role == .branch_cond) {
                    if (c.exitResumePc(e.index)) |rp| try testing.expect(rp != gp.source_pc);
                } else try testing.expect(!c.exitAttachable(e.index));
                continue;
            };
            if (last_call != 0 and e.index > last_call and c.exitAttachable(e.index)) seen.later_attachable += 1;
        }
    }
    return seen;
}

fn expectExitContract(vm: *Vm, mode: TraceMode) anyerror!void {
    try expectMetaCallRan(vm, mode);
    if (!recorded(mode)) return;
    const seen = try exitRoutes(vm);
    try testing.expect(seen.inlined > 0);
    try testing.expect(seen.mid > 0);
    if (mode != .record_only) try testing.expect(seen.later_attachable > 0);
}

test "doc 77 §7: exits by route, with every handler kind exiting once its answer turns" {
    // Each handler counts its calls and has a branch, a result type or a
    // row element that turns mid-run: a guard inside the handler fails
    // (route 1), or one of its instruction after it returned (route 2:
    // the sum's type, the fused read's second lookup). Each count is the
    // iteration count, so no exit called a handler twice. `i == 280` is a
    // later instruction's branch, which attaches (route 3).
    try expectProgramTuned(
        \\local function mk()
        \\  local c = { idx = 0, new = 0, add = 0, unm = 0, len = 0, lt = 0, call = 0, row = 0 }
        \\  local M = {}
        \\  M.__index = function(t, k)
        \\    c.idx = c.idx + 1
        \\    if t.n > 200 then return 2 end
        \\    return 1
        \\  end
        \\  M.__newindex = function(t, k, v)
        \\    c.new = c.new + 1
        \\    if v > 220 then rawset(t, "n", v) end
        \\  end
        \\  M.__add = function(a, b)
        \\    c.add = c.add + 1
        \\    if a.n > 230 then return 0.5 end
        \\    return a.n + b
        \\  end
        \\  M.__unm = function(a)
        \\    c.unm = c.unm + 1
        \\    return a.n > 240 and 1 or -1
        \\  end
        \\  M.__len = function(a)
        \\    c.len = c.len + 1
        \\    return a.n > 250 and 7 or 3
        \\  end
        \\  M.__lt = function(a, b)
        \\    c.lt = c.lt + 1
        \\    return a.n < b
        \\  end
        \\  M.__call = function(self, x)
        \\    c.call = c.call + 1
        \\    if x > 260 then return 4 end
        \\    return 2
        \\  end
        \\  local rows = {}
        \\  for i = 1, 300 do rows[i] = { i, i * 2 } end
        \\  rows[270] = { 270, 0.5 }
        \\  local F = setmetatable({}, { __index = function(_, k)
        \\    c.row = c.row + 1
        \\    return rows[k]
        \\  end })
        \\  return c, M, F
        \\end
        \\local c, M, F = mk()
        \\local o = setmetatable({ n = 0 }, M)
        \\local s = 0
        \\for i = 1, 300 do
        \\  rawset(o, "n", i)
        \\  s = s + o.x
        \\  o.y = i
        \\  s = s + (o + 1) + -o + #o + o(i) + F[i][2]
        \\  if o < 150 then s = s + 1 else s = s + 2 end
        \\  if i == 280 then s = s + 0.25 end
        \\end
        \\print(s, c.idx, c.new, c.add, c.unm, c.len, c.lt, c.call, c.row)
    , "119041.75\t300\t300\t300\t300\t300\t300\t300\t300\n", .{ .inspect = expectExitContract });
}

test "doc 77 Phase 4: __eq is asked only for two distinct tables, the first operand's handler first" {
    // `run(p, p)` and `run(r, r)` never call; `run(r, p)` calls `p`'s
    // handler (`r`'s metatable has none) until `F.__eq` appears; removing
    // `E.__eq` leaves identity. Three calls an iteration while one runs.
    try expectProgramTuned(
        \\local function mk()
        \\  local c = { n = 0 }
        \\  return c, function(a, b) c.n = c.n + 1; return a.k == b.k end
        \\end
        \\local c, h = mk()
        \\local E = { __eq = h }
        \\local F = {}
        \\local p = setmetatable({ k = 1 }, E)
        \\local q = setmetatable({ k = 1 }, E)
        \\local r = setmetatable({ k = 2 }, F)
        \\local function run(x, y)
        \\  local s = 0
        \\  for i = 1, 100 do
        \\    if x == y then s = s + 1 end
        \\    if x ~= y then s = s + 10 end
        \\    local e = x == y
        \\    if e then s = s + 100 end
        \\  end
        \\  return s
        \\end
        \\local r1 = run(p, q)
        \\local r2 = run(p, p)
        \\local r3 = run(r, p)
        \\local r4 = run(r, r)
        \\F.__eq = function(a, b) return true end
        \\local r5 = run(r, p)
        \\E.__eq = nil
        \\local r6 = run(p, q)
        \\print(r1, r2, r3, r4, r5, r6, c.n)
    , "10100\t10100\t1000\t10100\t10100\t1000\t600\n", .{ .inspect = expectMetaCallRan });
}

test "doc 77 Phase 4: a compare handler's result is taken for its truthiness" {
    // `__lt` returns a number (0 included) or nil, and counts its calls
    // before answering, so the turn to nil exits after the handler's store
    // and the count says it ran once per iteration. A table result, a
    // native handler and an allocating one stay with tier 0.
    try expectProgramTuned(
        \\local c = { n = 0 }
        \\local M = {}
        \\M.__lt = function(a, b)
        \\  c.n = c.n + 1
        \\  if a.x > 100 then return nil end
        \\  return a.x
        \\end
        \\local a = setmetatable({ x = 0 }, M)
        \\local b = setmetatable({ x = 0 }, M)
        \\local s = 0
        \\for i = 1, 200 do
        \\  a.x = i % 150
        \\  if a < b then s = s + 1 end
        \\end
        \\print(s, c.n)
    , "151\t200\n", .{ .inspect = expectMetaCallRan });
    try expectProgram(
        \\local T = setmetatable({}, { __le = function(a, b) return { a } end, __lt = rawequal })
        \\local s = 0
        \\for i = 1, 200 do
        \\  if T <= T then s = s + 1 end
        \\  if T < T then s = s + 2 end
        \\end
        \\print(s)
    , "600\n");
}

test "doc 77 Phase 4: a table compared against nil or false records" {
    try expectProgramTuned(
        \\local xs = {}
        \\for i = 1, 100 do xs[i] = (i % 3 == 0) and {} or false end
        \\local n = 0
        \\for r = 1, 3 do
        \\  for i = 1, 100 do
        \\    local v = xs[i]
        \\    if v == nil then n = n + 100 end
        \\    if v ~= false then n = n + 1 end
        \\  end
        \\end
        \\print(n)
    , "99\n", .{ .record_aborts = true, .inspect = expectNoBadTypeAbort });
}

/// No recording stopped at a type it could not handle, and a trace ran.
fn expectNoBadTypeAbort(vm: *Vm, mode: TraceMode) anyerror!void {
    if (!recorded(mode)) return;
    for (vm.trace.abort_log.items) |r| try testing.expect(r.reason != .bad_type);
    if (executed(mode)) try testing.expect(vm.trace.entries > 0);
}

/// A function metamethod was inlined and no recording stopped at a call.
fn expectMetaCallRanNoCallAbort(vm: *Vm, mode: TraceMode) anyerror!void {
    try expectMetaCallRan(vm, mode);
    if (recorded(mode)) for (vm.trace.abort_log.items) |r| try testing.expect(r.op != .call);
}

test "doc 77 §6.7: a table's __call is called as h(obj, args...) and its results land in the call's window" {
    // Two results, one, and none (a statement call, whose shifted span
    // reaches one slot past the frame: the handler's window sits above it,
    // as tier 0 puts it). The handler counts its calls in a field.
    try expectProgramTuned(
        \\local C = {}
        \\C.__call = function(self, a, b)
        \\  self.n = self.n + 1
        \\  return self.k * a + (b or 0), a
        \\end
        \\local o = setmetatable({ n = 0, k = 3 }, C)
        \\local s = 0
        \\for i = 1, 300 do
        \\  local x, y = o(i, 2)
        \\  s = s + x + y
        \\  s = s + o(1)
        \\  o(i)
        \\end
        \\print(s, o.n)
    , "182100\t900\n", .{ .record_aborts = true, .inspect = expectMetaCallRanNoCallAbort });
}

test "doc 77 §6.7: a changed or removed __call exits to tier 0" {
    // The handler is replaced in its metatable, then the table's metatable
    // is replaced; removing `__call` makes tier 0 raise at the call.
    try expectProgramTuned(
        \\local C = {}
        \\C.__call = function(self, a) return a + 1 end
        \\local o = setmetatable({}, C)
        \\local s = 0
        \\for i = 1, 300 do
        \\  if i == 100 then C.__call = function(self, a) return a * 2 end end
        \\  if i == 200 then setmetatable(o, { __call = function(self, a, b) return (b or 7) - a end }) end
        \\  s = s + o(i)
        \\end
        \\local M = { __call = function(_, x) return x end }
        \\local q = setmetatable({}, M)
        \\local ok, err = pcall(function()
        \\  local z = 0
        \\  for i = 1, 300 do
        \\    if i == 250 then M.__call = nil end
        \\    z = z + q(i)
        \\  end
        \\  return z
        \\end)
        \\print(s, ok, (string.find(err, "attempt to call a table value", 1, true)) ~= nil)
    , "10406\tfalse\ttrue\n", .{ .inspect = expectMetaCallRan });
}

test "doc 77 §6.7: a native or vararg __call stays with tier 0" {
    try expectProgram(
        \\local N = setmetatable({}, { __call = rawequal })
        \\local t = 0
        \\for i = 1, 300 do
        \\  if N(N) then t = t + 1 end
        \\end
        \\local m = setmetatable({}, { __call = function(self, ...) return ... end })
        \\local function three(i) return i, i + 1, i + 2 end
        \\local w = 0
        \\for i = 1, 300 do
        \\  local a, b, c = m(three(i))
        \\  w = w + a + b + c
        \\end
        \\local it = setmetatable({ lim = 5 }, { __call = function(self, st, c)
        \\  if c >= self.lim then return nil end
        \\  return c + 1
        \\end })
        \\local u = 0
        \\for r = 1, 100 do
        \\  for c in it, nil, 0 do u = u + c end
        \\end
        \\print(t, w, u)
    , "300\t136350\t1500\n");
}
