//! Tests for `interp.zig` — gc.
//!
//! Extracted verbatim from `interp.zig`; bodies are unchanged.
//! Shared harness lives in `interp_testutil.zig`.

const interp = @import("interp.zig");
const std = @import("std");
const bytecode = @import("bytecode.zig");
const arith = @import("arith.zig");
const value = @import("value.zig");
const regwindow = @import("regwindow.zig");
const gc = @import("gc.zig");
const object = @import("object.zig");
const string = @import("string.zig");
const table = @import("table.zig");
const array = @import("array.zig");
const function = @import("function.zig");
const trace = @import("trace.zig");
const irinterp = @import("irinterp.zig");
const execlog = @import("execlog.zig");
const compiler = @import("compiler.zig");
const io = @import("io.zig");
const stdmath = @import("stdlib/math.zig");
const stdtable = @import("stdlib/table.zig");
const stdbase = @import("stdlib/base.zig");
const stdbasic = @import("stdlib/basic.zig");
const stdstring = @import("stdlib/string.zig");
const stderrors = @import("stdlib/errors.zig");
const stddebug = @import("stdlib/debug.zig");
const stdload = @import("stdlib/load.zig");
const stdpackage = @import("stdlib/package.zig");
const unicode_case = @import("gen/unicode_case.zig");
const Value = value.Value;
const Proto = bytecode.Proto;
const Instr = bytecode.Instr;
const Closure = function.Closure;
const RegWindow = regwindow.RegWindow;
const testing = std.testing;

const Vm = interp.Vm;

const util = @import("interp_testutil.zig");
const expectProgram = util.expectProgram;
const expectProgramByGc = util.expectProgramByGc;

// ---------------------------------------------------------------------------
// GC-specific behaviour (Phase 4). The stress mode above already proves
// behaviour-invariance for the realistic programs; these target the two
// failure modes that only a collector can have: a wrongly-freed constant, and
// a failure to reclaim at all.
// ---------------------------------------------------------------------------

test "gc: a constant printed only after a GC-heavy loop still survives" {
    // Under stress, GC runs at every safepoint in the loop — long before the
    // "survivor" literal is ever loaded into a register. It lives only in the
    // chunk's constant pool until then, so it survives iff proto-constant marking
    // works (the dangling-constant hazard).
    try expectProgram(
        \\local x = 0
        \\for i = 1, 8 do x = x + i end
        \\print("survivor", x)
    , "survivor\t36\n"); // sum 1..8 == 36
}

test "gc: per-iteration garbage is reclaimed (heap stays bounded)" {
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    const gpa = testing.allocator;

    // Each iteration builds a fresh table that becomes unreachable on the next
    // iteration. Without a collector the heap would hold ~200 tables; with one
    // (stress mode) at most a couple are live at any safepoint.
    const source =
        \\local last = 0
        \\for i = 1, 200 do
        \\  local t = {}
        \\  t[1] = i
        \\  last = t[1]
        \\end
        \\print(last)
    ;
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();

    var buf: [32]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    vm.out = &sink;
    // Baseline = the permanent base-library footprint (every installed native +
    // its module tables + the `arg` table), captured right after init. Measuring
    // against this keeps the bound robust as the stdlib grows instead of baking a
    // magic total that breaks each time a library lands.
    const base_objects = vm.heap.object_count;
    vm.heap.setGcStress(true);

    var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());

    _ = try vm.run(chunk.proto);
    try testing.expectEqualStrings("200\n", sink.buffered());

    // The decisive assertion: the live set is bounded, *not* proportional to the
    // 200 iterations. Beyond the permanent base set, only a handful survive (the
    // main closure, "last"/literals, and a couple of still-rooted tables) — far
    // below the ~200 a missing collector would leave.
    try testing.expect(vm.heap.object_count < base_objects + 24);
}

test "gc: a string only a trace's constant pool names is swept as in tier-0 (doc 61 Phase Q)" {
    // `tostring(7)` inside a hot loop folds to an interned "7" in the trace's
    // constant pool. Once `f` returns nothing else names it, so tier-0 sweeps it
    // and the later `tostring(7)` re-interns, taking an object id. A pool that
    // roots its constants keeps "7" alive in the JIT legs only, so they skip
    // that allocation and print the table one id lower.
    //
    // Doc 61 §6: `s` is dead after `#s`, so a collection frees "7" even
    // inside the loop. The stress legs collect at every safepoint and so
    // re-intern it on every iteration, 1999 ids more.
    try expectProgramByGc(
        \\local function f()
        \\  local n = 0
        \\  for i = 1, 2000 do local s = tostring(7) n = n + #s end
        \\  return n
        \\end
        \\print(f())
        \\for k = 1, 5000 do local junk = {} end
        \\local again = tostring(7)
        \\print({})
    , "2000\ntable: 0x146f\n", "2000\ntable: 0x1c3e\n", .{});
}

// Doc 61 §8 determinism. Each program leaves a heap value in a register
// that is dead from some exit on, collects, then re-interns that value and
// prints a fresh table's id: a tier whose slab still holds the stale value
// keeps it alive across the collection, skips the re-intern allocation and
// prints a lower id. Every trace mode must print its GC discipline's id.

/// The inner loop's `i` (R[a+3]) holds a string at its last iteration. It
/// is dead after the loop, so the linked loop-done flush may leave the slab
/// copy stale; the masked walk does not root it. `PRE` runs before `f`.
fn linkedForSource(comptime pre: []const u8) [:0]const u8 {
    return
    \\local function f(n)
    \\  local c = 0
    \\  for j = 1, 40 do
    \\    for i = 1, n do i = tostring(i) c = c + #i end
    \\  end
    \\  return c
    \\end
    \\
    ++ pre ++
        \\print(f(30))
        \\for k = 1, 5000 do local junk = {} end
        \\local again = tostring(30)
        \\print({})
    ;
}

const LoopDone = struct {
    /// The native leg linked the inner loop's completion, so the flush ran.
    /// (Under `gc_stress` the native body defers to the safepoint
    /// collections and never links.)
    fn linked(vm: *Vm, mode: util.TraceMode) anyerror!void {
        if (mode == .record_execute_native and !vm.heap.gc_stress) try testing.expect(vm.trace.native_loopdone_link_arms > 0);
    }

    /// A non-maskable proto declines the flush: no completion fuses.
    fn declined(vm: *Vm, mode: util.TraceMode) anyerror!void {
        if (mode == .record_execute_native) try testing.expectEqual(@as(u64, 0), vm.trace.native_loopdone_link_fused);
    }
};

// The CLI's recording threshold: at the harness default the inner loop's
// completion is never linked.
const cli_hotloop = (trace.TraceConfig{}).hotloop;

test "doc 61 §8: a linked numeric-for whose control variable holds a string agrees in every tier" {
    try expectProgramByGc(linkedForSource(""), "2040\ntable: 0x148c\n", "2040\ntable: 0x191e\n", .{ .hotloop = cli_hotloop, .inspect = &LoopDone.linked });
}

test "doc 61 §8: the same linked numeric-for over a non-maskable proto declines the flush and agrees" {
    try expectProgramByGc(linkedForSource("unmask(f)\n"), "2040\ntable: 0x148e\n", "2040\ntable: 0x1920\n", .{ .hotloop = cli_hotloop, .setup = &util.installUnmask, .inspect = &LoopDone.declined });
}

/// The native leg reached the chain's call A: a linked burst ran the inner
/// root in linked mode.
fn followedInner(vm: *Vm, mode: util.TraceMode) anyerror!void {
    if (mode == .record_execute_native and !vm.heap.gc_stress) try testing.expect(vm.trace.native_link_follow_count > 0);
}

// Codex review of Phase 1: the capture of `k` after the loop nest makes the
// inner loop's control register live past it (captured registers are live at
// every pc), so the inner page declines its linked loop-done flush (site 5).
// The burst's call A still runs that page in linked mode; its loop-done is
// then an ordinary deopt at the header, and advancing past the loop as if it
// had committed dropped the final `c = c + 20` of every followed trip
// (98460).
test "doc 61 §5 site 5: a chain burst over an inner loop whose flush declines resumes at its header" {
    try util.expectProgramTuned(
        \\local c = 0
        \\for j = 1, 1000 do
        \\  if j % 2 == 0 then
        \\    for i = 1, 20 do c = c + i end
        \\  else
        \\    c = c + 1
        \\  end
        \\end
        \\local a,b,d,e,f,g,h,k,l = 1,2,3,4,5,6,7,8,9
        \\local function z() return k end
        \\print(c, z())
    , "105500\t8\n", .{ .hotloop = cli_hotloop, .inspect = &followedInner });
}

// Doc 61 Phase 2, codex's dead-φ counterexample (the reason doc 61 exists):
// the inner loop's register for `s` is dead at the inner header and after
// the loop, so the dead-φ filter gives it no writeback and the slab keeps
// an earlier table, whose string the unmasked walk kept alive past the
// re-intern of "x" — tier-0 printed 0x178f and the traced tiers 0x1790.
// Under the masked walk every tier roots the same registers.
test "doc 61 §8: a φ the dead-φ filter drops leaves the same heap in every tier" {
    try expectProgramByGc(
        \\local function fill()
        \\  local t = {}
        \\  for j = 1, 400 do
        \\    t[j] = {v = string.char(1000 + j)}
        \\  end
        \\  return t
        \\end
        \\local function clear(...) end
        \\
        \\local t = fill()
        \\local s = nil
        \\for j = 1, 400 do
        \\  for i = 1, 100 do s = t[j] end
        \\end
        \\t = nil
        \\clear(0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
        \\for k = 1, 5000 do local junk = {} end
        \\local x = string.char(1400)
        \\print({})
    , "table: 0x1791\n", "table: 0x1791\n", .{});
}

/// Doc 61 §9b witness: an ordinary (non-precise) allocating trace ran, and
/// natively its linked loop-done exit was followed.
fn ranAllocatingTrace(vm: *Vm, mode: util.TraceMode) anyerror!void {
    if (vm.heap.gc_stress) return; // allocating traces never enter under stress
    if (mode != .record_execute_noopt and mode != .record_execute and mode != .record_execute_native) return;
    var allocating = false;
    for (vm.trace.registry.cache.items) |t| {
        if (t.code.alloc_bound > 0 and t.code.deopt_mode == .entry_replay) allocating = true;
    }
    try testing.expect(allocating);
    try testing.expect(vm.trace.entries > 0);
    if (mode == .record_execute_native) {
        try testing.expect(vm.trace.native_entries > 0);
        try testing.expect(vm.trace.native_link_follow_count > 0);
    }
}

// Doc 61 Phase 3 (§9b): the same counterexample with the dead temp
// allocated on trace. `tostring` interns a string into `s` every inner
// iteration (`string.char` would abort on the `string` lookup); `s` is
// dead at the inner header and after the nest, so the allocating trace
// gives it no φ (doc 24 D3 kept it). Tier-0 leaves "1400" in the slot, the
// traced tiers an earlier string. Neither is rooted, so the re-intern of
// "1400" allocates in every tier.
test "doc 61 §9b: an allocating trace's dropped φ leaves the same heap in every tier" {
    try expectProgramByGc(
        \\local s = nil
        \\for j = 1, 400 do
        \\  for i = 1, 100 do s = tostring(1000 + j) end
        \\end
        \\for k = 1, 5000 do local junk = {} end
        \\local x = tostring(1400)
        \\print({})
    , "table: 0x15fd\n", "table: 0xb0ad\n", .{ .inspect = &ranAllocatingTrace });
}

// Site 3's exit-snapshot programs live with the register probe
// (interp_semantics_test.zig, "doc 61 §2 site 3"): an object id printed
// after `f` returns cannot see a stale register in `f`'s window.
