//! Tests for `interp.zig` — trace.
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
const TraceMode = util.TraceMode;
const expectProgram = util.expectProgram;

// ---------------------------------------------------------------------------
// Trace recorder wiring (Phase 5). The IR + counting unit tests live in
// `trace.zig`; these prove the interpreter actually drives the recorder — the
// `enabled` toggle gates counting, and a hot loop registers a back-edge anchor.
// ---------------------------------------------------------------------------

/// Compile+run `source` with the recorder `enabled`, leaving `vm` inspectable.
/// Returns the compiled `Chunk` — the caller **must** `deinit` it, but only after
/// inspecting any cached traces: a `Trace`'s `anchor.proto` points into the
/// chunk's arena, so freeing the chunk first would dangle it.
fn runForTrace(vm: *Vm, gpa: std.mem.Allocator, source: [:0]const u8, enabled: bool) !compiler.Chunk {
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");

    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();

    vm.trace.config.enabled = enabled;
    // This harness inspects *recording* in isolation (Phase 5a). Keep tier-1a
    // execution off so back-edge counts / cache shape reflect pure recording;
    // Phase-6 execution is exercised by `expectProgram` and its own tests. Keep
    // the optimizer off too, so `dumpTrace` shape assertions see the *raw*
    // recorded IR (folding/CSE/DCE are exercised by the `tropt` tests).
    vm.trace.config.execute = false;
    vm.trace.config.optimize = false;
    vm.trace.config.hotloop = 4; // record short test loops
    var buf: [256]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;

    var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    errdefer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    _ = try vm.run(chunk.proto);
    return chunk;
}

/// Configure `vm.trace` for `mode` (mirrors `runCaptured`'s mode wiring) with a small
/// `hotloop` so short test loops go hot. Shared by the two-epoch H-2 part-3 tests.
fn configTraceMode(vm: *Vm, mode: TraceMode) void {
    vm.trace.config.enabled = mode != .off;
    vm.trace.config.execute = mode == .record_execute or mode == .record_execute_noopt or mode == .record_execute_native;
    vm.trace.config.optimize = mode == .record_execute or mode == .record_execute_native;
    vm.trace.config.native_codegen = mode == .record_execute_native;
    vm.trace.config.hotloop = 4;
}

test "H-2 part 3: a trace const does not survive a top-level epoch boundary (cross-epoch id parity)" {
    // The end-to-end determinism regression for docs/design/17 H-2 part 3. On ONE VM:
    //   * epoch 1 runs a hot loop reading a *static* string key `t.foo` — recording a
    //     trace whose const pool holds the interned "foo" (id A). Epoch 1 returns, so at
    //     `depth==0` the static proto tree is unrooted; "foo" is now rooted ONLY by that
    //     cached trace's const.
    //   * epoch 2 (a second `vm.run` on the same VM) interns a marker at id B (> A),
    //     forces GC, re-interns "foo" AT RUNTIME (`"f".."oo"`), and reports the `pairs`
    //     order of {foo, marker}.
    // WITHOUT the `clearCache()` at the epoch boundary, a record mode keeps "foo" alive
    // at id A across the boundary, so it re-interns to A (< B) and sorts BEFORE the
    // marker — while `.off` sweeps it and re-interns to a fresh id C (> B). Divergent
    // `pairs` order. WITH the clear, the epoch-1 trace is retired before epoch 2 runs,
    // so "foo" is swept in every mode alike and all modes agree ("marker foo ").
    const gpa = testing.allocator;
    const s1: [:0]const u8 =
        \\local t = { foo = 1 }
        \\local s = 0
        \\for i = 1, 200 do s = s + t.foo end
        \\print(s)
    ;
    const s2: [:0]const u8 =
        \\local marker = "mar" .. "ker"
        \\for i = 1, 3000 do local junk = {} end
        \\local foo2 = "f" .. "oo"
        \\local tt = {}
        \\tt[foo2] = 1
        \\tt[marker] = 2
        \\local order = ""
        \\for k in pairs(tt) do order = order .. k .. " " end
        \\print(order)
    ;
    const H = struct {
        // Run s1 then s2 on ONE VM; return epoch-2's printed output (heap-owned).
        // NB: compile c2 *after* epoch 1 runs. String literals intern weakly (only
        // rooted via a live closure), so compiling c2 up front would let epoch 1's GC
        // (esp. under gc_stress) sweep c2's not-yet-live constants → dangling loads in
        // epoch 2. Interleaving compile+run keeps each chunk's constants live from the
        // moment they exist. (This models a real REPL: parse+compile+run per statement.)
        fn twoEpoch(a: std.mem.Allocator, src1: [:0]const u8, src2: [:0]const u8, mode: TraceMode, stress: bool) ![]u8 {
            const parser = @import("parser.zig");
            const diag = @import("diag.zig");
            var diags = diag.Diagnostics.init(a);
            defer diags.deinit();

            var vm = try Vm.init(a);
            defer vm.deinit();
            vm.heap.gc_stress = stress;
            configTraceMode(&vm, mode);

            // Epoch 1 — records the t.foo trace.
            var sink1_buf: [64]u8 = undefined;
            var sink1 = io.Writer.fixed(&sink1_buf);
            vm.out = &sink1;
            var t1 = try parser.parse(a, src1, &diags);
            defer t1.deinit();
            var c1 = try compiler.compile(a, vm.heap, src1, t1.root, &diags);
            defer c1.deinit();
            try testing.expect(!diags.hasErrors());
            _ = try vm.run(c1.proto);

            // Epoch 2 — beginTopLevelEpoch clears epoch-1's cache first.
            var sink2_buf: [64]u8 = undefined;
            var sink2 = io.Writer.fixed(&sink2_buf);
            vm.out = &sink2;
            var t2 = try parser.parse(a, src2, &diags);
            defer t2.deinit();
            var c2 = try compiler.compile(a, vm.heap, src2, t2.root, &diags);
            defer c2.deinit();
            try testing.expect(!diags.hasErrors());
            _ = try vm.run(c2.proto);
            return a.dupe(u8, sink2.buffered());
        }
    };
    inline for (.{ false, true }) |stress| {
        const off = try H.twoEpoch(gpa, s1, s2, .off, stress);
        defer gpa.free(off);
        // Every record mode's epoch-2 output must match `.off` (and the fixed order).
        inline for (.{ .record_only, .record_execute_noopt, .record_execute, .record_execute_native }) |mode| {
            const rec = try H.twoEpoch(gpa, s1, s2, mode, stress);
            defer gpa.free(rec);
            try testing.expectEqualStrings(off, rec);
        }
        try testing.expectEqualStrings("marker foo \n", off);
    }
}

test "H-2 part 3: clearCache retires every trace + resets all derived tiering/diagnostic state" {
    // The direct guard on `clearCache`'s reset set (docs/design/17 H-2 part 3): run a
    // program that populates the trace cache + exec logs + the abort log, then call
    // `clearCache` and assert EVERY field in the reset set is empty/null — so a future
    // field added to the recorder that clearCache forgets is caught here rather than as
    // a cross-epoch use-after-free or a stale-index diagnostic corruption.
    const gpa = testing.allocator;
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    // NB: the abort-log seed loop must stay UNRECORDABLE. `#tostring(i)` served
    // until doc 24 c2 made scalar tostring record end-to-end; `tostring(t)` of a
    // table still aborts at `recBTostring` (`.bad_type` — non-scalar argument),
    // which is what populates `abort_log` below.
    const source =
        \\local t = { k = 1 }
        \\local s = 0
        \\for i = 1, 200 do s = s + t.k end
        \\local u = 0
        \\for i = 1, 200 do u = u + #tostring(t) end
        \\print(s + u)
    ;
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    vm.trace.config.enabled = true;
    vm.trace.config.execute = true;
    vm.trace.config.optimize = true;
    vm.trace.config.record_exec_log = true; // populate exec_logs
    vm.trace.config.record_aborts = true; // populate abort_log (the tostring loop is a host barrier)
    vm.trace.config.coverage = true; // populate the coverage map (so its clear is load-bearing)
    vm.trace.config.hotloop = 4;
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;
    var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    _ = try vm.run(chunk.proto);

    // Sanity: the run actually populated the structures we care about (so the post-clear
    // assertions below aren't trivially satisfied by an already-empty state).
    try testing.expect(vm.trace.cache.items.len >= 1);
    try testing.expect(vm.trace.exec_logs.items.len >= 1);
    try testing.expect(vm.trace.abort_log.items.len >= 1);
    try testing.expect(vm.trace.coverage.count() >= 1);

    vm.trace.clearCache();

    // Everything in the reset set is empty/null after the clear.
    try testing.expectEqual(@as(usize, 0), vm.trace.cache.items.len);
    try testing.expectEqual(@as(usize, 0), vm.trace.counters.count());
    try testing.expectEqual(@as(usize, 0), vm.trace.gate.count());
    try testing.expectEqual(@as(usize, 0), vm.trace.penalty.count());
    try testing.expectEqual(@as(usize, 0), vm.trace.guard_failures.count());
    try testing.expectEqual(@as(usize, 0), vm.trace.exec_logs.items.len);
    try testing.expectEqual(@as(usize, 0), vm.trace.coverage.count());
    try testing.expectEqual(@as(usize, 0), vm.trace.abort_log.items.len);
    try testing.expect(vm.trace.wants_side_trace == null);
    try testing.expect(vm.trace.wants_prime_side == null);
    try testing.expect(vm.trace.pending_exit_anchor == null);
    try testing.expect(vm.trace.pending_replay_anchor == null);
    if (vm.trace.exec_recorder) |*r| try testing.expect(r.log == null);
    for (vm.trace.hotcount) |h| try testing.expectEqual(@as(u16, 0), h);
    // A-ii: the structural-edge cache + the whole region model (logical defs/intern
    // AND the physical classification indices) all empty after the flush.
    try testing.expectEqual(@as(usize, 0), vm.trace.edge_cache.count());
    try testing.expectEqual(@as(usize, 0), vm.trace.region_defs.count());
    try testing.expectEqual(@as(usize, 0), vm.trace.region_intern.entries.items.len);
    try testing.expectEqual(@as(usize, 0), vm.trace.source_exit_regions.count());
    try testing.expectEqual(@as(usize, 0), vm.trace.dest_entry_regions.count());
}

test "H-2 part 3: the JIT still records fresh traces in a second epoch after the cache clear" {
    // Guard against the counter/gate reset in `clearCache` accidentally wedging
    // re-recording: after the epoch-1 clear, an epoch-2 hot loop must still record.
    const gpa = testing.allocator;
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    const src: [:0]const u8 =
        \\local s = 0
        \\for i = 1, 200 do s = s + i end
        \\print(s)
    ;
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, src, &diags);
    defer tree.deinit();
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    vm.trace.config.enabled = true;
    vm.trace.config.hotloop = 4;
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;
    var chunk = try compiler.compile(gpa, vm.heap, src, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());

    _ = try vm.run(chunk.proto); // epoch 1
    try testing.expect(vm.trace.cache.items.len >= 1);
    _ = try vm.run(chunk.proto); // epoch 2 — beginTopLevelEpoch cleared the cache first
    // A fresh trace was recorded in epoch 2 (not left wedged by the reset).
    try testing.expect(vm.trace.cache.items.len >= 1);
}

test "doc 24 c2: an allocating tostring loop records, commits guard_gc with the stamped bound, and runs end-to-end" {
    // The scalar shape (`u = u + #tostring(i)`) end-to-end at the VM level: the
    // loop must RECORD (pre-doc-24 it aborted at the builtin call), the
    // committed trace must carry `alloc_bound == 1` with a guard_gc whose aux
    // was stamped from the recorder's `.alloc` count, and the traced run's
    // output must be byte-identical to the arithmetic truth.
    const gpa = testing.allocator;
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    const source =
        \\local u = 0
        \\for i = 1, 200 do u = u + #tostring(i) end
        \\print(u)
    ;
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    vm.trace.config.enabled = true;
    vm.trace.config.execute = true;
    vm.trace.config.optimize = true;
    vm.trace.config.hotloop = 4;
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;
    var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    _ = try vm.run(chunk.proto);
    // 9×1 + 90×2 + 101×3 = 492 — and the loop ran hot, so most iterations
    // committed on-trace with on-trace interning.
    try testing.expectEqualStrings("492\n", sink.buffered());

    // The committed trace: exactly one `.alloc` op per iteration → bound 1,
    // stamped into the guard_gc's aux at commit.
    var found = false;
    for (vm.trace.cache.items) |t| {
        if (t.alloc_bound == 0) continue;
        found = true;
        try testing.expectEqual(@as(u32, 1), t.alloc_bound);
        var n_guard_gc: usize = 0;
        for (t.instrs) |ins| {
            if (ins.op == .guard_gc) {
                n_guard_gc += 1;
                try testing.expectEqual(@as(i32, 1), ins.aux);
            }
        }
        try testing.expectEqual(@as(usize, 1), n_guard_gc);
    }
    try testing.expect(found);
}

test "doc 24 c3: a snew-class string loop records, commits, and runs end-to-end with native JIT" {
    // The str_manip core shape end-to-end at the VM level: sub + reverse on an
    // observed base string, char + rep on computed scalars — the whole snew
    // class in one hot loop. Must RECORD (pre-c3 every string builtin aborted),
    // commit with the right `alloc_bound`, and produce byte-identical output
    // under the full pipeline (record -> tropt -> tier-1a/native execute).
    // Tier-1a config, deliberately: THIS trace's `i % 10` has no native
    // lowering yet (TODO.md item 3), and under `native_codegen` the safety
    // net would decline entry ENTIRELY (skip, never tier-1a) — the loop
    // would run tier-0 and the "executes end-to-end" claim would be vacuous.
    // Native snew execution end-to-end is proven by the mod-free threshold-
    // bouncing test (c4) and at the nativegen_lowering_test level.
    const gpa = testing.allocator;
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    const source =
        \\local sub = string.sub
        \\local rev = string.reverse
        \\local char = string.char
        \\local rep = string.rep
        \\local base = "héllo wörld héllo wörld"
        \\local u = 0
        \\-- NB: `rev(sub(...))` would put the inner call in last-arg position,
        \\-- which compiles to a MULTRET call (b/c = all_results) — a recording
        \\-- frontier that aborts .cross_frame (see TODO.md). The intermediate
        \\-- local keeps every call in the pinned-arity shape; rev's argument is
        \\-- then a PROVEN ssub result (no guard_string on it).
        \\for i = 1, 200 do
        \\  local t = sub(base, i % 10 + 1, i % 10 + 4)
        \\  u = u + #rev(t)
        \\  u = u + #rep(char(64 + i % 26 + 1), i % 5)
        \\end
        \\print(u)
    ;
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();

    // Tier-0 truth first: the same source with tracing off.
    var truth: [64]u8 = undefined;
    var truth_len: usize = 0;
    {
        var vm = try Vm.init(gpa);
        defer vm.deinit();
        var buf: [64]u8 = undefined;
        var sink = io.Writer.fixed(&buf);
        vm.out = &sink;
        var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
        defer chunk.deinit();
        try testing.expect(!diags.hasErrors());
        _ = try vm.run(chunk.proto);
        truth_len = sink.buffered().len;
        @memcpy(truth[0..truth_len], sink.buffered());
        try testing.expect(truth_len > 0);
    }

    // Traced + native: byte-identical output, and the committed trace carries
    // the snew ops with alloc_bound == 4 (ssub, srev, schar1, srep2).
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    vm.trace.config.enabled = true;
    vm.trace.config.execute = true;
    vm.trace.config.optimize = true;
    vm.trace.config.hotloop = 4;
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;
    var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    _ = try vm.run(chunk.proto);
    try testing.expectEqualStrings(truth[0..truth_len], sink.buffered());
    // The committed allocating trace really EXECUTED (tier-1a) — not just
    // recorded; entries==0 here would mean a vacuous tier-0-only comparison.
    try testing.expect(vm.trace.entries > 0);

    var found = false;
    for (vm.trace.cache.items) |t| {
        if (t.alloc_bound == 0) continue;
        found = true;
        try testing.expectEqual(@as(u32, 4), t.alloc_bound);
        var has = [_]bool{ false, false, false, false };
        var n_guard_gc: usize = 0;
        for (t.instrs) |ins| {
            switch (ins.op) {
                .ssub => has[0] = true,
                .srev => has[1] = true,
                .schar1 => has[2] = true,
                .srep2 => has[3] = true,
                .guard_gc => {
                    n_guard_gc += 1;
                    try testing.expectEqual(@as(i32, 4), ins.aux);
                },
                else => {},
            }
        }
        for (has) |h| try testing.expect(h);
        try testing.expectEqual(@as(usize, 1), n_guard_gc);
    }
    try testing.expect(found);
}

test "doc 24 c4: gc_stress forces allocating traces back to tier-0 with identical output" {
    // Codex #1/#14: under `gc_stress` tier-0 collects at every safepoint; a
    // native burst would skip those collections, so the `!gc_stress` entry
    // conjunct must bounce EVERY entry of an allocating trace and the whole
    // loop runs tier-0-pure — with byte-identical output.
    const gpa = testing.allocator;
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    const source =
        \\local sub = string.sub
        \\local rev = string.reverse
        \\local base = "abcdefghijklmnop"
        \\local u = 0
        \\for i = 1, 200 do
        \\  local t = sub(base, i % 8 + 1, i % 8 + 4)
        \\  u = u + #rev(t) + #tostring(i)
        \\end
        \\print(u)
    ;
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();

    // Tier-0 truth WITHOUT stress (stress never changes output, only pacing).
    var truth: [64]u8 = undefined;
    var truth_len: usize = 0;
    {
        var vm = try Vm.init(gpa);
        defer vm.deinit();
        var buf: [64]u8 = undefined;
        var sink = io.Writer.fixed(&buf);
        vm.out = &sink;
        var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
        defer chunk.deinit();
        try testing.expect(!diags.hasErrors());
        _ = try vm.run(chunk.proto);
        truth_len = sink.buffered().len;
        @memcpy(truth[0..truth_len], sink.buffered());
    }

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    vm.heap.gc_stress = true;
    vm.trace.config.enabled = true;
    vm.trace.config.execute = true;
    vm.trace.config.optimize = true;
    // Tier-1a config, deliberately: the body's `%` has no native lowering, and
    // under `native_codegen` the safety net would decline entry ENTIRELY
    // (skip, never tier-1a) — masking the very guard_gc bounce this test pins.
    vm.trace.config.hotloop = 4;
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;
    var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    _ = try vm.run(chunk.proto);
    try testing.expectEqualStrings(truth[0..truth_len], sink.buffered());
    // The dispatcher DID keep trying the trace — each entry bounced at the
    // guard_gc header with zero allocations until the low-yield gate parked
    // the anchor; tier-0 (collecting at every safepoint) did all the work.
    try testing.expect(vm.trace.entries > 0);
}

test "doc 24 c4: observation blackout — an armed safepoint recorder keeps allocating traces OUT of the executors" {
    // Codex #2: with `record_safepoint_lines` armed (keyframe/suspend
    // observation), replay must see every tier-0 safepoint line — a native or
    // tier-1a burst of an allocating trace would swallow them. The c2 trial-
    // walk + driveChain skips must therefore decline entry entirely: the
    // allocating trace still RECORDS and COMMITS (recording is entry-neutral),
    // but `vm.trace.entries` stays 0 and the output is tier-0's.
    const gpa = testing.allocator;
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    const source =
        \\local rep = string.rep
        \\local char = string.char
        \\local u = 0
        \\for i = 1, 200 do
        \\  u = u + #rep(char(65 + i % 26), i % 5)
        \\end
        \\print(u)
    ;
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    vm.record_safepoint_lines = true;
    vm.source = source;
    vm.trace.config.enabled = true;
    vm.trace.config.execute = true;
    vm.trace.config.optimize = true;
    // Tier-1a config, deliberately: with `native_codegen` on, this mod-laden
    // body would be declined by the native safety net regardless of the
    // blackout, making the `entries == 0` assertion below vacuous. Under
    // tier-1a config the ONLY thing keeping the trace out is the blackout
    // (the gc_stress test above proves this config otherwise enters).
    vm.trace.config.hotloop = 4;
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;
    var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    _ = try vm.run(chunk.proto);
    try testing.expectEqualStrings("400\n", sink.buffered()); // 40 x (0+1+2+3+4)

    // The allocating trace committed…
    var committed_alloc = false;
    for (vm.trace.cache.items) |t| {
        if (t.alloc_bound > 0) committed_alloc = true;
    }
    try testing.expect(committed_alloc);
    // …but was never ENTERED (the blackout skip fires before the entry
    // counter bump; this program has no other hot trace to muddy the count).
    try testing.expectEqual(@as(u64, 0), vm.trace.entries);
}

test "doc 24 c4: threshold bouncing across real GC cycles — heap schedule and output identical across modes" {
    // The "guard_gc failing after many committed bursts" leg at VM scale: an
    // unbounded fresh-string loop (`tostring(i)` for 4000 distinct i) crosses
    // `next_gc` repeatedly. Tier-0 collects at its dispatch safepoints; the
    // traced run's guard_gc must bounce each crossing back to tier-0 so the
    // COLLECTION SCHEDULE is reproduced exactly — asserted via output byte-
    // identity AND final `object_count`/`next_gc`/`next_obj_id` equality.
    const gpa = testing.allocator;
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    const source =
        \\local rev = string.reverse
        \\local u = 0
        \\for i = 1, 4000 do
        \\  local s = tostring(i)
        \\  local dead = rev(s)
        \\  u = u + #dead
        \\end
        \\print(u)
    ;
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();

    var t0_out: [64]u8 = undefined;
    var t0_len: usize = 0;
    var t0_objs: usize = 0;
    var t0_next_gc: usize = 0;
    var t0_next_id: u64 = 0;
    {
        var vm = try Vm.init(gpa);
        defer vm.deinit();
        var buf: [64]u8 = undefined;
        var sink = io.Writer.fixed(&buf);
        vm.out = &sink;
        var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
        defer chunk.deinit();
        try testing.expect(!diags.hasErrors());
        _ = try vm.run(chunk.proto);
        t0_len = sink.buffered().len;
        @memcpy(t0_out[0..t0_len], sink.buffered());
        t0_objs = vm.heap.object_count;
        t0_next_gc = vm.heap.next_gc;
        t0_next_id = vm.heap.next_obj_id;
    }

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    vm.trace.config.enabled = true;
    vm.trace.config.execute = true;
    vm.trace.config.optimize = true;
    vm.trace.config.native_codegen = @import("nativegen.zig").is_x64_linux;
    vm.trace.config.hotloop = 4;
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;
    var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    _ = try vm.run(chunk.proto);
    try testing.expectEqualStrings(t0_out[0..t0_len], sink.buffered());
    try testing.expectEqual(t0_objs, vm.heap.object_count);
    try testing.expectEqual(t0_next_gc, vm.heap.next_gc);
    try testing.expectEqual(t0_next_id, vm.heap.next_obj_id);
    // Sanity: the trace really RAN (mod-free body, so nothing declines it) —
    // natively where the platform supports it. NB: a `%` anywhere in the loop
    // would flip `native_codegen`'s safety net to "decline entirely" (mod has
    // no lowering yet, TODO item 3) and silently turn this into a tier-0-only
    // comparison; that vacuous variant was caught during authoring.
    try testing.expect(vm.trace.entries > 0);
    if (@import("nativegen.zig").is_x64_linux)
        try testing.expect(vm.trace.native_entries > 0);
}

test "chunk rooting: a host-compiled retained chunk survives GC before it runs" {
    // docs/design/03 §"Chunk-constant rooting" — the regression. A host compiles chunk
    // B (whose distinctive literal is a `load_const`), retains it, runs chunk A (which
    // GCs at every safepoint under stress), then runs B. WITHOUT `retainChunk`, B's
    // "compdeferlit" is swept during A's run (B has no closure yet → its constants are
    // unrooted) and B's `load_const` dangles. WITH it, the retain roots B's whole tree
    // so the literal survives and B prints it. (Negative control: removing the
    // `retained_chunks` loop in `forEachRootHeader` reddens/UAFs this.)
    const gpa = testing.allocator;
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();

    const src_a: [:0]const u8 = "for i = 1, 3000 do local junk = {} end\n";
    const src_b: [:0]const u8 = "print(\"compdeferlit\")\n";

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    vm.heap.gc_stress = true; // sweep at every safepoint during A's run

    // Compile B first (interns "compdeferlit"), then A. Neither is run yet.
    var tb = try parser.parse(gpa, src_b, &diags);
    defer tb.deinit();
    var cb = try compiler.compile(gpa, vm.heap, src_b, tb.root, &diags);
    defer cb.deinit();
    var ta = try parser.parse(gpa, src_a, &diags);
    defer ta.deinit();
    var ca = try compiler.compile(gpa, vm.heap, src_a, ta.root, &diags);
    defer ca.deinit();
    try testing.expect(!diags.hasErrors());

    try vm.retainChunk(cb.proto); // keep B alive across A's GC-heavy run — the fix

    var sink_a: [16]u8 = undefined;
    var wa = io.Writer.fixed(&sink_a);
    vm.out = &wa;
    _ = try vm.run(ca.proto); // GCs repeatedly; "compdeferlit" rooted only by the retain

    var sink_b: [32]u8 = undefined;
    var wb = io.Writer.fixed(&sink_b);
    vm.out = &wb;
    _ = try vm.run(cb.proto); // B's `load_const` must still resolve
    vm.releaseChunk(cb.proto);

    try testing.expectEqualStrings("compdeferlit\n", wb.buffered());
}

test "chunk rooting: releaseChunk unroots a retained chunk's constants" {
    // Retain roots the constants (survive a stress GC); release unroots them (swept by
    // the next stress GC). B is never run, so its only reference is the retain.
    const gpa = testing.allocator;
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();

    const src_b: [:0]const u8 = "print(\"releaselit\")\n"; // never run; literal is a constant
    const src_c: [:0]const u8 = "for i = 1, 100 do local j = {} end\n"; // GC driver

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    vm.heap.gc_stress = true;
    var sink: [16]u8 = undefined;
    var w = io.Writer.fixed(&sink);
    vm.out = &w;

    var tb = try parser.parse(gpa, src_b, &diags);
    defer tb.deinit();
    var cb = try compiler.compile(gpa, vm.heap, src_b, tb.root, &diags);
    defer cb.deinit();
    var tc = try parser.parse(gpa, src_c, &diags);
    defer tc.deinit();
    var cc = try compiler.compile(gpa, vm.heap, src_c, tc.root, &diags);
    defer cc.deinit();
    try testing.expect(!diags.hasErrors());

    try vm.retainChunk(cb.proto);
    _ = try vm.run(cc.proto); // stress GC — "releaselit" rooted by the retain
    try testing.expect(vm.heap.internedLookup("releaselit") != null);

    vm.releaseChunk(cb.proto);
    _ = try vm.run(cc.proto); // stress GC — now unrooted
    try testing.expect(vm.heap.internedLookup("releaselit") == null);
}

test "chunk rooting: releaseChunk preserves survivor order (orderedRemove, not swapRemove)" {
    // Root-discovery order = retain order (docs/design/03), so releasing a NON-last
    // borrow must keep the survivors' relative order: releasing X from [X,Y,Z] leaves
    // [Y,Z]. A `swapRemove` would leave [Z,Y] and shift snapshot bytes.
    const gpa = testing.allocator;
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();

    var vm = try Vm.init(gpa);
    defer vm.deinit();

    const sx: [:0]const u8 = "print(\"olx\")\n";
    const sy: [:0]const u8 = "print(\"oly\")\n";
    const sz: [:0]const u8 = "print(\"olz\")\n";
    var tx = try parser.parse(gpa, sx, &diags);
    defer tx.deinit();
    var cx = try compiler.compile(gpa, vm.heap, sx, tx.root, &diags);
    defer cx.deinit();
    var ty = try parser.parse(gpa, sy, &diags);
    defer ty.deinit();
    var cy = try compiler.compile(gpa, vm.heap, sy, ty.root, &diags);
    defer cy.deinit();
    var tz = try parser.parse(gpa, sz, &diags);
    defer tz.deinit();
    var cz = try compiler.compile(gpa, vm.heap, sz, tz.root, &diags);
    defer cz.deinit();
    try testing.expect(!diags.hasErrors());

    try vm.retainChunk(cx.proto);
    try vm.retainChunk(cy.proto);
    try vm.retainChunk(cz.proto);
    vm.releaseChunk(cx.proto); // remove the FIRST — the case that distinguishes the two

    try testing.expectEqual(@as(usize, 2), vm.retained_chunks.items.len);
    try testing.expectEqual(@as(*const Proto, cy.proto), vm.retained_chunks.items[0]);
    try testing.expectEqual(@as(*const Proto, cz.proto), vm.retained_chunks.items[1]);

    vm.releaseChunk(cy.proto);
    vm.releaseChunk(cz.proto);
}

test "chunk rooting: retained-chunk output is byte-identical across all 10 modes" {
    // Rooting retained chunks is a mode-invariant host action (unlike trace consts), so
    // a program that retains + runs a deferred chunk produces identical output in every
    // mode. B's literal `"alit"` is interned at B's compile (early), rooted across A's
    // GC-heavy run by the retain, and sorts BEFORE the runtime-built marker in `pairs`.
    const gpa = testing.allocator;
    const src_a: [:0]const u8 = "for i = 1, 3000 do local junk = {} end\n";
    const src_b: [:0]const u8 =
        \\local s = 0
        \\for i = 1, 200 do s = s + i end
        \\local marker = "mar" .. "ker"
        \\local tt = {}
        \\tt["alit"] = 1
        \\tt[marker] = 2
        \\local order = ""
        \\for k in pairs(tt) do order = order .. k .. " " end
        \\print(order)
    ;
    const H = struct {
        fn run(a: std.mem.Allocator, sa: [:0]const u8, sb: [:0]const u8, mode: TraceMode, stress: bool) ![]u8 {
            const parser = @import("parser.zig");
            const diag = @import("diag.zig");
            var diags = diag.Diagnostics.init(a);
            defer diags.deinit();
            var vm = try Vm.init(a);
            defer vm.deinit();
            vm.heap.gc_stress = stress;
            configTraceMode(&vm, mode);

            var tbb = try parser.parse(a, sb, &diags);
            defer tbb.deinit();
            var cbb = try compiler.compile(a, vm.heap, sb, tbb.root, &diags);
            defer cbb.deinit();
            var taa = try parser.parse(a, sa, &diags);
            defer taa.deinit();
            var caa = try compiler.compile(a, vm.heap, sa, taa.root, &diags);
            defer caa.deinit();
            try testing.expect(!diags.hasErrors());

            try vm.retainChunk(cbb.proto);
            var dump: [16]u8 = undefined;
            var wd = io.Writer.fixed(&dump);
            vm.out = &wd;
            _ = try vm.run(caa.proto);

            var sink: [64]u8 = undefined;
            var w = io.Writer.fixed(&sink);
            vm.out = &w;
            _ = try vm.run(cbb.proto);
            vm.releaseChunk(cbb.proto);
            return a.dupe(u8, w.buffered());
        }
    };
    inline for (.{ false, true }) |stress| {
        const off = try H.run(gpa, src_a, src_b, .off, stress);
        defer gpa.free(off);
        inline for (.{ .record_only, .record_execute_noopt, .record_execute, .record_execute_native }) |mode| {
            const rec = try H.run(gpa, src_a, src_b, mode, stress);
            defer gpa.free(rec);
            try testing.expectEqualStrings(off, rec);
        }
        try testing.expectEqualStrings("alit marker \n", off);
    }
}

test "trace toggle gates back-edge counting" {
    const gpa = testing.allocator;
    const source =
        \\local acc = 0
        \\for i = 1, 100 do acc = acc + i end
        \\print(acc)
    ;
    // Disabled: the hotness seam is inert — no counters touched.
    {
        var vm = try Vm.init(gpa);
        defer vm.deinit();
        var chunk = try runForTrace(&vm, gpa, source, false);
        defer chunk.deinit();
        try testing.expectEqual(@as(usize, 0), vm.trace.counters.count());
    }
    // Enabled: the loop's anchor goes hot and a trace is recorded.
    {
        var vm = try Vm.init(gpa);
        defer vm.deinit();
        var chunk = try runForTrace(&vm, gpa, source, true);
        defer chunk.deinit();
        try testing.expect(vm.trace.counters.count() >= 1);
        // The hottest anchor crossed the hotness threshold (one back-edge per
        // iteration; one is consumed by trace close, so it lands just under 100).
        var it = vm.trace.counters.valueIterator();
        var max: u32 = 0;
        while (it.next()) |v| max = @max(max, v.*);
        try testing.expect(max >= vm.trace.config.hotloop);
        try testing.expect(max <= 100);
        // The simple counting loop is fully recordable → exactly one cached trace.
        try testing.expectEqual(@as(usize, 1), vm.trace.cache.items.len);
    }
}

test "doc 19: a hot loop inside a load-chunk traces exactly like the static chunk" {
    // Flipped from the H-2 part 1 gate test (docs/design/19): loaded chunks now
    // trace. The identical hot loop records a trace whether it lives in the STATIC
    // main chunk or in a `load`ed chunk — safe because the chunk's proto-literal
    // konsts are rooted VM-lifetime via `loaded_chunks` in both root walks
    // (`forEachRootHeader`), so a trace konst over them is always redundant and the
    // old sole-root divergence is unreachable. Load-bearing: removing the
    // `loaded_chunks` loop from `forEachRootHeader` re-opens the H-2 hazard (see
    // the end-to-end determinism test below), while re-adding the old
    // `Proto.dynamic` arm gate reddens the dynamic half here.
    const gpa = testing.allocator;
    // STATIC: the loop is in the main chunk → records.
    {
        var vm = try Vm.init(gpa);
        defer vm.deinit();
        var chunk = try runForTrace(&vm, gpa,
            \\local t = { victim = 1 }
            \\local s = 0
            \\for i = 1, 200 do s = s + t.victim end
            \\print(s)
        , true);
        defer chunk.deinit();
        try testing.expectEqual(@as(usize, 1), vm.trace.cache.items.len);
    }
    // LOADED: the same loop, compiled at runtime via `load` → records identically.
    {
        var vm = try Vm.init(gpa);
        defer vm.deinit();
        var chunk = try runForTrace(&vm, gpa,
            \\local f = load([[
            \\  local t = { victim = 1 }
            \\  local s = 0
            \\  for i = 1, 200 do s = s + t.victim end
            \\  return s
            \\]])
            \\print(f())
        , true);
        defer chunk.deinit();
        try testing.expectEqual(@as(usize, 1), vm.trace.cache.items.len);
    }
}

test "doc 19: dropped load-chunk string id is byte-identical across all modes (end-to-end)" {
    // The July H-2 scenario, now pinned under the doc-19 rooting model. A `load`ed
    // chunk's hot loop reads a proto-literal string key `t.victim` (interned at id
    // A). The closure is dropped, a runtime-built marker string is interned at id
    // B (> A), a GC cycle is forced, then `"victim"` is *re-interned at runtime*
    // (`"vic".."tim"`) and its id observed through the `pairs` order of a fresh
    // table.
    //   * Pre-doc-19 the gate made every mode SWEEP "victim" (no trace kept it),
    //     so it re-interned at C > B and the marker sorted first.
    //   * Post-doc-19 the `loaded_chunks` root keeps "victim" alive at id A in
    //     EVERY mode — including `.off`, which runs the same mark phase — so it
    //     re-interns to A (< B) and sorts BEFORE the marker, in all 10 modes
    //     alike. The determinism property is the same (one id timeline); only the
    //     uniform timeline changed. Load-bearing: dropping the `loaded_chunks`
    //     loop from `forEachRootHeader` diverges record modes (trace konst roots
    //     "victim") from `.off` (sweeps it) — the original H-2 hole.
    // The 3000-table garbage loop forces a real collection even under
    // `gc_stress=false` (the GC threshold starts at 1024 live objects), so the
    // non-stress half of the matrix actually sweeps too.
    try expectProgram(
        \\local f = load("local t = {victim=1} local s=0 for i=1,200 do s=s+t.victim end return s")
        \\local _ = f()
        \\f = nil
        \\local marker = "mar" .. "ker"
        \\for i = 1, 3000 do local junk = {} end
        \\local vic = "vic" .. "tim"
        \\local tt = {}
        \\tt[vic] = 1
        \\tt[marker] = 2
        \\local order = ""
        \\for k in pairs(tt) do order = order .. k .. " " end
        \\print(order)
        \\
    ,
        "victim marker \n",
    );
}

test "doc 19: a static trace inlines a loaded callee (flipped recCall gate)" {
    // Flipped from the H-2 recCall gate test (docs/design/19): a trace anchored in
    // a STATIC proto that inline-calls a `load`ed fixed-arity nested callee each
    // iteration now inlines it and commits, exactly like a static callee — the
    // callee's proto-literal konsts entering the trace const pool is safe because
    // the `loaded_chunks` root makes them redundant in both walks. The callee must
    // stay a fixed-arity NESTED function (a directly-loaded root is vararg via
    // `vararg_root = true` and aborts at `cp.is_vararg`, which would mask the
    // inline path this test pins).
    const gpa = testing.allocator;
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    const source =
        \\local g = load("return function(x) return x + 1 end")()
        \\local s = 0
        \\for i = 1, 300 do s = g(s) end
        \\print(s)
    ;
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    vm.trace.config.enabled = true;
    vm.trace.config.execute = false;
    vm.trace.config.optimize = false;
    vm.trace.config.hotloop = 4;
    vm.trace.config.record_aborts = true; // populate abort_log so we can read the reason
    var buf: [256]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;
    var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    _ = try vm.run(chunk.proto);
    // The static anchor records and commits, inlining the loaded callee.
    try testing.expectEqual(@as(usize, 1), vm.trace.cache.items.len);
}

/// Run `source` with tier-1a execution **and** exec-log recording on (small
/// `hotloop` so test loops go hot), capturing `print` output into `sink`. Returns
/// the compiled chunk so the caller can inspect `vm.trace.exec_logs` while the
/// anchor proto stays alive (free the chunk after asserting). `record` selects the
/// instrumented executor — pass false to exercise the uninstrumented path with an
/// otherwise identical config (the parity canary).
fn runForExecLog(vm: *Vm, gpa: std.mem.Allocator, source: [:0]const u8, sink: *io.Writer, record: bool) !compiler.Chunk {
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");

    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();

    vm.out = sink;
    vm.trace.config.enabled = true;
    vm.trace.config.execute = true;
    vm.trace.config.record_exec_log = record;
    vm.trace.config.hotloop = 4; // record short test loops

    var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    errdefer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    _ = try vm.run(chunk.proto);
    return chunk;
}

test "exec log captures a hot loop's iterations and its exit ramp" {
    const gpa = testing.allocator;
    const source =
        \\local acc = 0
        \\for i = 1, 100 do acc = acc + i end
        \\print(acc)
    ;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    var chunk = try runForExecLog(&vm, gpa, source, &sink, true);
    defer chunk.deinit();

    // One cached trace → one exec log keyed by its cache index (0).
    try testing.expectEqual(@as(usize, 1), vm.trace.cache.items.len);
    try testing.expectEqual(@as(usize, 1), vm.trace.exec_logs.items.len);
    const log = vm.trace.exec_logs.items[0];
    try testing.expectEqual(@as(u32, 0), log.trace_id);
    try testing.expect(!log.entries_capped);
    try testing.expect(log.entries.items.len >= 1);

    const entry = log.entries.items[0];
    // The trace spun real iterations before deopting.
    try testing.expect(entry.iterations > 0);
    // The event stream carries values, at least one surviving guard, commits, and a
    // terminal side-exit (the loop-bound guard failing is the exit ramp).
    var values: usize = 0;
    var guards: usize = 0;
    var commits: usize = 0;
    for (entry.events) |e| switch (e.kind) {
        .value => values += 1,
        .guard_pass => guards += 1,
        .commit => commits += 1,
        .exit => {},
    };
    try testing.expect(values > 0);
    try testing.expect(guards > 0);
    try testing.expect(commits > 0);
    // The last event is the exit ramp, and it names a real IR instruction.
    const last = entry.events[entry.events.len - 1];
    try testing.expectEqual(execlog.ExecEventKind.exit, last.kind);
    try testing.expect(last.ref < vm.trace.cache.items[0].instrs.len);
    try testing.expectEqual(execlog.ExitKind.guard, entry.exit_kind);
    try testing.expectEqual(@as(u32, last.ref), entry.exit_ref);
}

test "exec-log detail cap truncates iterations but keeps the count and exit" {
    const gpa = testing.allocator;
    const source =
        \\local acc = 0
        \\for i = 1, 100 do acc = acc + i end
        \\print(acc)
    ;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    vm.trace.config.exec_log_max_iters = 2; // cap the spinning detail hard
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    var chunk = try runForExecLog(&vm, gpa, source, &sink, true);
    defer chunk.deinit();

    const entry = vm.trace.exec_logs.items[0].entries.items[0];
    try testing.expect(entry.capped); // detail truncated
    // Detail truncated to <= 2 committed iterations of events…
    var commits: usize = 0;
    for (entry.events) |e| {
        if (e.kind == .commit) commits += 1;
    }
    try testing.expect(commits <= 2);
    // …but the real yield is still recorded, and the exit ramp survives the cap.
    try testing.expect(entry.iterations > 2);
    try testing.expectEqual(execlog.ExecEventKind.exit, entry.events[entry.events.len - 1].kind);
}

test "exec-log entry cap stops recording further entries" {
    const gpa = testing.allocator;
    const source =
        \\local acc = 0
        \\for i = 1, 100 do acc = acc + i end
        \\print(acc)
    ;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    vm.trace.config.exec_log_max_entries = 0; // record nothing, just flag it
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    var chunk = try runForExecLog(&vm, gpa, source, &sink, true);
    defer chunk.deinit();

    const log = vm.trace.exec_logs.items[0];
    try testing.expect(log.entries_capped);
    try testing.expectEqual(@as(usize, 0), log.entries.items.len);
}

test "exec-log recording is observation-only (record on/off agree)" {
    const gpa = testing.allocator;
    const source =
        \\local acc = 0
        \\for i = 1, 100 do acc = acc + i end
        \\print(acc)
    ;
    var off_buf: [64]u8 = undefined;
    var off_sink = io.Writer.fixed(&off_buf);
    {
        var vm = try Vm.init(gpa);
        defer vm.deinit();
        var chunk = try runForExecLog(&vm, gpa, source, &off_sink, false);
        defer chunk.deinit();
        try testing.expectEqual(@as(usize, 0), vm.trace.exec_logs.items.len);
    }
    var on_buf: [64]u8 = undefined;
    var on_sink = io.Writer.fixed(&on_buf);
    {
        var vm = try Vm.init(gpa);
        defer vm.deinit();
        var chunk = try runForExecLog(&vm, gpa, source, &on_sink, true);
        defer chunk.deinit();
    }
    // Instrumentation must not perturb the program's observable output.
    try testing.expectEqualStrings(off_sink.buffered(), on_sink.buffered());
}

test "per-guard PC: last_exit_instr is set on zero-iteration guard failure" {
    // A loop where types change mid-run so the recorded trace fails a guard
    // on its very first execution. With hotloop=4, iteration 5 records and
    // iteration 6 executes — the `if i == 6` branch changes direction, so
    // guard_false on the eq result fails with completed=0.
    const gpa = testing.allocator;
    const source =
        \\local x = 0
        \\for i = 1, 100 do
        \\    if i == 6 then x = x + 0.5 else x = x + 1 end
        \\end
        \\print(x)
    ;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    vm.trace.config.hotguard = 1000; // prevent fingerprint-miss side traces
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    var chunk = try runForExecLog(&vm, gpa, source, &sink, true);
    defer chunk.deinit();

    // The trace MUST have been executed and failed at a guard.
    try testing.expect(vm.trace.last_exit_instr != std.math.maxInt(u32));
    try testing.expectEqual(@as(usize, 1), vm.trace.cache.items.len);
    const t = vm.trace.cache.items[0];
    const ei = vm.trace.last_exit_instr;
    try testing.expect(ei < t.instrs.len);

    // The failing instruction must be a guard.
    const failed = t.instrs[ei];
    try testing.expect(switch (failed.op) {
        .guard_int, .guard_float, .guard_number, .guard_true, .guard_false => true,
        else => false,
    });
    // And its aux must carry the bytecode PC where it was recorded.
    try testing.expect(failed.aux > 0);
}

test "side traces: type-changing loop records a second trace at the same anchor" {
    // When a guard in the root trace fails repeatedly (type change), a side
    // trace is recorded at the same loop header, and same-anchor chaining
    // runs the correct trace for each iteration's types.
    const gpa = testing.allocator;
    const source =
        \\local x = 0
        \\for i = 1, 20 do
        \\    if i == 6 then x = x + 0.5 else x = x + 1 end
        \\end
        \\print(x)
    ;
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");

    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();
    try testing.expect(!diags.hasErrors());

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    vm.trace.config.enabled = true;
    vm.trace.config.execute = true;
    vm.trace.config.hotloop = 4;
    vm.trace.config.hotguard = 3; // low threshold for test
    vm.trace.config.min_trip_entry = 0; // exercise side traces on a short test loop
    vm.trace.config.record_exec_log = true;

    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;

    var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    _ = try vm.run(chunk.proto);

    // Two traces should exist at the same anchor: the root trace (int path)
    // and the side trace (float path, recorded after guard failures).
    try testing.expect(vm.trace.cache.items.len >= 2);
    // Guard failures are cleared when the side trace arms, and no new
    // failures are counted once 2+ traces exist (avoids unbounded growth).
    // Output must be correct despite the type change mid-loop.
    // i=1..5: x=5 (int); i=6: x=5.5 (float); i=7..20: x=19.5.
    try testing.expectEqualStrings("19.5\n", sink.buffered());
}

test "side traces: without side traces the anchor blacklists; with them it stays live" {
    // Run the same type-changing program twice: once with a hotguard threshold
    // so high that no side trace fires (the anchor blacklists), and once with
    // a low threshold (side trace keeps the anchor alive).  Both must produce
    // correct output — side traces are a performance optimisation, not a
    // correctness requirement.
    const gpa = testing.allocator;
    const source =
        \\local x = 0
        \\for i = 1, 30 do
        \\    if i == 6 then x = x + 0.5 else x = x + 1 end
        \\end
        \\print(x)
    ;
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");

    // --- Run 1: no side traces (hotguard > iteration count) ---
    {
        var diags = diag.Diagnostics.init(gpa);
        defer diags.deinit();
        var tree = try parser.parse(gpa, source, &diags);
        defer tree.deinit();
        try testing.expect(!diags.hasErrors());

        var vm = try Vm.init(gpa);
        defer vm.deinit();
        vm.trace.config.enabled = true;
        vm.trace.config.execute = true;
        vm.trace.config.hotloop = 4;
        vm.trace.config.hotguard = 1000; // effectively never
        vm.trace.config.min_trip_entry = 0; // exercise entry on a short test loop
        vm.trace.config.max_penalty = 8; // blacklists after 8 zero-yield entries

        var buf: [64]u8 = undefined;
        var sink = io.Writer.fixed(&buf);
        vm.out = &sink;
        var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
        defer chunk.deinit();
        _ = try vm.run(chunk.proto);

        // Only the root trace exists — no side trace was ever recorded.
        try testing.expectEqual(@as(usize, 1), vm.trace.cache.items.len);
        // The anchor is NOT blacklisted: type fingerprinting skips the
        // trace when x becomes float instead of entering-and-failing,
        // so no penalty accumulates.
        try testing.expectEqual(@as(usize, 0), vm.trace.gate.count());
        // Output is still correct — tier-0 handles the type-changed iterations.
        // i=1..5: x=5; i=6: x=5.5; i=7..30: x = 5.5 + 24 = 29.5.
        try testing.expectEqualStrings("29.5\n", sink.buffered());
    }

    // --- Run 2: side traces enabled (hotguard = 3) ---
    {
        var diags = diag.Diagnostics.init(gpa);
        defer diags.deinit();
        var tree = try parser.parse(gpa, source, &diags);
        defer tree.deinit();
        try testing.expect(!diags.hasErrors());

        var vm = try Vm.init(gpa);
        defer vm.deinit();
        vm.trace.config.enabled = true;
        vm.trace.config.execute = true;
        vm.trace.config.hotloop = 4;
        vm.trace.config.hotguard = 3; // fire a side trace after 3 guard failures
        vm.trace.config.min_trip_entry = 0; // exercise side traces on a short test loop
        vm.trace.config.max_penalty = 8; // (would blacklist without side traces)

        var buf: [64]u8 = undefined;
        var sink = io.Writer.fixed(&buf);
        vm.out = &sink;
        var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
        defer chunk.deinit();
        _ = try vm.run(chunk.proto);

        // Two traces: the root trace (int path) and the side trace (float path).
        try testing.expect(vm.trace.cache.items.len >= 2);
        // The anchor is NOT blacklisted — the float side trace commits useful
        // iterations (> min_useful), clearing the penalty before it maxes out.
        try testing.expectEqual(@as(usize, 0), vm.trace.gate.count());
        // Same correct output.
        try testing.expectEqualStrings("29.5\n", sink.buffered());
    }
}

/// Disassemble a `vm`'s sole cached trace into `buf` for shape assertions. `buf`
/// is sized comfortably above any test trace. The caller must keep the trace's
/// `anchor.proto` alive (see `runForTrace`) — `writeTrace` prints `proto.name`.
fn dumpTrace(buf: []u8, vm: *Vm) ![]const u8 {
    try testing.expectEqual(@as(usize, 1), vm.trace.cache.items.len);
    var w = io.Writer.fixed(buf);
    try trace.writeTrace(&w, vm.trace.cache.items[0]);
    return w.buffered();
}

test "recorder: a numeric-for loop records guards + arithmetic + a loop close" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var chunk = try runForTrace(&vm, gpa,
        \\local acc = 0
        \\for i = 1, 50 do acc = acc + i end
        \\print(acc)
    , true);
    defer chunk.deinit(); // keep the proto alive: the trace's anchor points into it

    var buf: [8192]u8 = undefined;
    const text = try dumpTrace(&buf, &vm);
    // Inputs are read as slot_loads; integer operands are pinned with guard_int;
    // the body `acc + i` and the for-loop increment are `add`; the iteration is
    // closed by `loop`.
    try testing.expect(std.mem.indexOf(u8, text, "slot_load") != null);
    try testing.expect(std.mem.indexOf(u8, text, "guard_int") != null);
    try testing.expect(std.mem.indexOf(u8, text, "add") != null);
    try testing.expect(std.mem.indexOf(u8, text, "guard_true") != null); // for-loop continuation
    try testing.expect(std.mem.indexOf(u8, text, "loop") != null);

    const t = vm.trace.cache.items[0];
    // acc and the loop index are loop-carried, so they surface as slot-bound φs.
    var n_phi: usize = 0;
    for (t.instrs) |ins| {
        if (ins.op == .phi and ins.aux >= 0) n_phi += 1;
    }
    try testing.expect(n_phi >= 1);
    try testing.expect(t.entry_slots.len >= 1);
    // No host/cross-frame op was hit, so nothing was blacklisted.
    try testing.expectEqual(@as(usize, 0), vm.trace.gate.count());
}

test "recorder: a while loop records a truthiness guard on its condition" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var chunk = try runForTrace(&vm, gpa,
        \\local i = 1
        \\local acc = 0
        \\while i <= 50 do acc = acc + i; i = i + 1 end
        \\print(acc)
    , true);
    defer chunk.deinit(); // keep the proto alive: the trace's anchor points into it

    var buf: [8192]u8 = undefined;
    const text = try dumpTrace(&buf, &vm);
    // The `i <= 50` test compiles to `le` + a conditional jump; tier-0 takes the
    // loop body, so the recorder pins the condition true (guard_true).
    try testing.expect(std.mem.indexOf(u8, text, "le") != null);
    try testing.expect(std.mem.indexOf(u8, text, "guard_true") != null);
    try testing.expect(std.mem.indexOf(u8, text, "add") != null);
    try testing.expect(std.mem.indexOf(u8, text, "loop") != null);
}

test "recorder: dead expression temporaries are dropped from the exit snapshot (task A)" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    // `(i + 7) * (i + 7)` computes through expression-stack temporaries at slots
    // >= base+4. They are written and re-read within the iteration (never
    // slot_loaded → write-only), and dead at the loop header / after the loop, so
    // the recorder's watermark filter drops them from the exit snapshot.
    var chunk = try runForTrace(&vm, gpa,
        \\local acc = 0
        \\for i = 1, 50 do acc = acc + (i + 7) * (i + 7) end
        \\print(acc)
    , true);
    defer chunk.deinit(); // keep the proto alive: the trace's anchor points into it

    try testing.expectEqual(@as(usize, 1), vm.trace.cache.items.len);
    const t = vm.trace.cache.items[0];

    // Recover the numeric-for base from the bytecode so the assertion does not
    // hard-code the compiler's register allocation. Control regs are base..base+3;
    // base+4 is the first temporary slot (the watermark).
    var base: ?u16 = null;
    for (chunk.proto.code) |ins| {
        if (ins.op == .for_loop) {
            base = ins.a;
            break;
        }
    }
    const watermark: usize = @as(usize, base.?) + 4;

    // Every surviving slot-bound φ is either below the watermark (a real local /
    // loop control) or a slot the trace actually read — never a dead temporary.
    var saw_acc = false;
    for (t.instrs) |ins| {
        if (ins.op != .phi or ins.aux < 0) continue;
        const slot: u16 = @intCast(ins.aux);
        const was_read = std.mem.indexOfScalar(u16, t.entry_slots, slot) != null;
        try testing.expect(@as(usize, slot) < watermark or was_read);
        if (slot == 0) saw_acc = true; // `acc` is the first local → slot 0
    }
    // The loop-carried accumulator is still committed.
    try testing.expect(saw_acc);
    // And no high write-only temporary leaked through.
    for (t.instrs) |ins| {
        if (ins.op != .phi or ins.aux < 0) continue;
        const slot: u16 = @intCast(ins.aux);
        if (@as(usize, slot) >= watermark)
            try testing.expect(std.mem.indexOfScalar(u16, t.entry_slots, slot) != null);
    }
}

test "recorder: a while loop keeps its write-only temporaries (no for_loop watermark)" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    // A while loop has no `for_loop`, so the watermark stays at its `maxInt`
    // sentinel and nothing is filtered. The `i <= 50` condition computes into a
    // write-only temporary (defined, never slot_loaded), which must survive in the
    // exit snapshot — proving the filter is inert without an anchoring for_loop.
    var chunk = try runForTrace(&vm, gpa,
        \\local i = 1
        \\local acc = 0
        \\while i <= 50 do acc = acc + i; i = i + 1 end
        \\print(acc)
    , true);
    defer chunk.deinit(); // keep the proto alive: the trace's anchor points into it

    const t = vm.trace.cache.items[0];
    // There must be at least one defined-but-never-read (write-only) slot still in
    // the snapshot — exactly what the for-loop filter would have removed.
    var saw_write_only = false;
    for (t.instrs) |ins| {
        if (ins.op != .phi or ins.aux < 0) continue;
        const slot: u16 = @intCast(ins.aux);
        if (std.mem.indexOfScalar(u16, t.entry_slots, slot) == null) saw_write_only = true;
    }
    try testing.expect(saw_write_only);
}

test "recorder: a recurring literal is interned to one const-pool entry" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    // `i * 7` appears twice; before konst interning that recorded two separate
    // `7` constants. runForTrace keeps the optimizer OFF, so the const pool here
    // reflects pure recording — the literal must appear exactly once.
    var chunk = try runForTrace(&vm, gpa,
        \\local acc = 0
        \\for i = 1, 50 do acc = acc + i * 7 + i * 7 end
        \\print(acc)
    , true);
    defer chunk.deinit(); // keep the proto alive: the trace's anchor points into it

    try testing.expectEqual(@as(usize, 1), vm.trace.cache.items.len);
    const t = vm.trace.cache.items[0];
    var sevens: usize = 0;
    for (t.consts) |c| {
        if (c.isInt() and c.asInt() == 7) sevens += 1;
    }
    try testing.expectEqual(@as(usize, 1), sevens);
}

test "konst interning lets CSE collapse a repeated subexpression end-to-end" {
    const gpa = testing.allocator;
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    var vm = try Vm.init(gpa);
    defer vm.deinit();

    const source =
        \\local acc = 0
        \\for i = 1, 50 do acc = acc + i * 7 + i * 7 end
        \\print(acc)
    ;
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();

    // Record AND run the optimizer at commit (execute stays on tier-0 — we only
    // inspect the committed, optimized trace, not tier-1a output).
    vm.trace.config.enabled = true;
    vm.trace.config.execute = false;
    vm.trace.config.optimize = true;
    vm.trace.config.hotloop = 4;
    var buf: [256]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;

    var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit(); // keep the proto alive: the trace's anchor points into it
    try testing.expect(!diags.hasErrors());
    _ = try vm.run(chunk.proto);

    try testing.expectEqual(@as(usize, 1), vm.trace.cache.items.len);
    const t = vm.trace.cache.items[0];
    // The two `i * 7` subexpressions are now identical (same slot_load ref + same
    // interned konst ref), so CSE collapses them to a single `mul`. Before konst
    // interning, CSE could not fire here and both muls survived.
    var muls: usize = 0;
    for (t.instrs) |ins| {
        if (ins.op == .mul) muls += 1;
    }
    try testing.expectEqual(@as(usize, 1), muls);
}

test "doc 24 c3: identical ssubs are NEVER CSE'd, and compaction remaps ssub.aux (the three-operand op)" {
    const gpa = testing.allocator;
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    var vm = try Vm.init(gpa);
    defer vm.deinit();

    // Two IDENTICAL sub calls per iteration (same string, same konst bounds),
    // preceded by the proven CSE vehicle (`i * 7 + i * 7` — the second mul
    // collapses, see the konst-interning test above), so compaction SHIFTS
    // every later ref — the ssubs' aux (the end-index ref, invisible to the
    // two-operand remap path) must be explicitly remapped or it would dangle.
    const source =
        \\local sub = string.sub
        \\local base = "abcdefgh"
        \\local acc = 0
        \\for i = 1, 50 do
        \\  acc = acc + i * 7 + i * 7
        \\  local x = sub(base, 2, 5)
        \\  local y = sub(base, 2, 5)
        \\  acc = acc + #x + #y
        \\end
        \\print(acc)
    ;
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();

    vm.trace.config.enabled = true;
    vm.trace.config.execute = false; // inspect the committed, optimized trace
    vm.trace.config.optimize = true;
    vm.trace.config.hotloop = 4;
    var buf: [256]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;

    var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    _ = try vm.run(chunk.proto);
    // 14 x (1+..+50) + 50 x (4 + 4) = 17850 + 400.
    try testing.expectEqualStrings("18250\n", sink.buffered());

    try testing.expectEqual(@as(usize, 1), vm.trace.cache.items.len);
    const t = vm.trace.cache.items[0];
    // The `.alloc` class is codex #8: a repeat is a FALLIBLE op tier-0
    // performs (host scratch precedes the intern), so identical ssubs must
    // BOTH survive — CSE'ing one away would drop an allocation the id-stream
    // bound accounts for. And each aux must still resolve to the konst 5 end
    // bound after DCE shifted the ref space.
    var n_ssub: usize = 0;
    for (t.instrs) |ins| {
        if (ins.op != .ssub) continue;
        n_ssub += 1;
        const jref = t.instrs[@intCast(ins.aux)];
        try testing.expectEqual(trace.IrOp.konst, jref.op);
        try testing.expectEqual(Value.int(5).payload.bits, t.consts[@intCast(jref.aux)].payload.bits);
    }
    try testing.expectEqual(@as(usize, 2), n_ssub);
    try testing.expectEqual(@as(u32, 2), t.alloc_bound);
    // The second `i * 7` was CSE'd — proof that compaction actually ran and
    // the aux checks above exercised a genuinely REMAPPED ref space.
    var muls: usize = 0;
    for (t.instrs) |ins| {
        if (ins.op == .mul) muls += 1;
    }
    try testing.expectEqual(@as(usize, 1), muls);
}

test "recorder: a non-recursive fixed-arity leaf call is inlined into one trace" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var chunk = try runForTrace(&vm, gpa,
        \\local function id(x) return x end
        \\local acc = 0
        \\for i = 1, 50 do acc = acc + id(i) end
        \\print(acc)
    , true);
    defer chunk.deinit();

    // Cross-frame tracing (Phase 0): the body's `call` to a fixed-arity, non-
    // recursive Lua leaf is inlined into the trace (guard_func + seeded callee
    // slots + return mapping) rather than aborting, so the loop records exactly
    // one trace, the recording closes cleanly, and the anchor is *not*
    // blacklisted (an aborted anchor would have been gated — `gate.count() >= 1`).
    try testing.expectEqual(@as(usize, 1), vm.trace.cache.items.len);
    try testing.expectEqual(@as(usize, 0), vm.trace.gate.count());
    try testing.expect(!vm.trace.isRecording());
}

test "recorder: a vararg call in the loop body still aborts cleanly" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var chunk = try runForTrace(&vm, gpa,
        \\local function f(...) return 1 end
        \\local acc = 0
        \\for i = 1, 50 do acc = acc + f(i) end
        \\print(acc)
    , true);
    defer chunk.deinit();

    // A vararg callee has no compile-time-fixed register window to seed, so the
    // recorder must still abort (cross_frame) — no trace cached, recording done.
    try testing.expectEqual(@as(usize, 0), vm.trace.cache.items.len);
    try testing.expect(vm.trace.gate.count() >= 1);
    try testing.expect(!vm.trace.isRecording());
}

test "recorder: a callee reached through an upvalue records a snapshot input + guard_func" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    // Cluster sub-lever 1: `inner`'s hot loop calls `A`, reached through an upvalue
    // (`get_upval`). The recorder cannot read an upvalue in the executor, so it
    // snapshots the loop-invariant callee into a synthetic slab slot *above* the
    // anchor window, emits a `slot_load` on that slot (seeded by the dispatch loop)
    // and a `guard_func` pinning the runtime callee identity, and records exactly one
    // `InputSeed` describing how to re-resolve it on entry.
    var chunk = try runForTrace(&vm, gpa,
        \\local function A(i, j) return i * 100 + j end
        \\local function inner()
        \\  local s = 0
        \\  for j = 1, 80 do s = s + A(2, j) end
        \\  return s
        \\end
        \\print(inner())
    , true);
    defer chunk.deinit(); // keep the proto alive: the trace's anchor points into it

    try testing.expectEqual(@as(usize, 1), vm.trace.cache.items.len);
    const t = vm.trace.cache.items[0];

    // Exactly one synthetic input, resolved from an upvalue, slotted above the anchor.
    try testing.expectEqual(@as(usize, 1), t.inputs.len);
    try testing.expectEqual(trace.InputKind.upvalue, t.inputs[0].kind);
    try testing.expect(t.inputs[0].slot >= vm.trace.rec.anchor_num_registers);

    // The snapshot is read by a `slot_load` on exactly that synthetic slot, and a
    // `guard_func` pins the callee proto.
    var saw_input_load = false;
    var saw_guard_func = false;
    for (t.instrs) |ins| {
        if (ins.op == .slot_load and ins.aux == @as(i32, t.inputs[0].slot)) saw_input_load = true;
        if (ins.op == .guard_func) saw_guard_func = true;
    }
    try testing.expect(saw_input_load);
    try testing.expect(saw_guard_func);
}

test "recorder: a callee reached through a global records a snapshot input + guard_func" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    // The global analogue: `A` is a loop-invariant global (`get_global`, a raw
    // `globals.get`). Same snapshot+guard mechanism, but the `InputSeed.kind` is
    // `.global` and `source` indexes the constant pool (the global key).
    var chunk = try runForTrace(&vm, gpa,
        \\function A(i, j) return i * 100 + j end
        \\local s = 0
        \\for j = 1, 80 do s = s + A(2, j) end
        \\print(s)
    , true);
    defer chunk.deinit();

    try testing.expectEqual(@as(usize, 1), vm.trace.cache.items.len);
    const t = vm.trace.cache.items[0];
    try testing.expectEqual(@as(usize, 1), t.inputs.len);
    try testing.expectEqual(trace.InputKind.global, t.inputs[0].kind);
    try testing.expect(t.inputs[0].slot >= vm.trace.rec.anchor_num_registers);

    var saw_guard_func = false;
    for (t.instrs) |ins| {
        if (ins.op == .guard_func) saw_guard_func = true;
    }
    try testing.expect(saw_guard_func);
}

test "recorder: a set_upval in the loop body aborts cleanly" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    // Snapshotting is only sound while the upvalue cell is *stable* across the traced
    // region. A `set_upval` writes the cell, so the recorder must abort (it is NOT in
    // the record switch) — no trace cached, the anchor gated.
    var chunk = try runForTrace(&vm, gpa,
        \\local up = 0
        \\local function inner()
        \\  for j = 1, 80 do up = up + j end
        \\  return up
        \\end
        \\print(inner())
    , true);
    defer chunk.deinit();

    try testing.expectEqual(@as(usize, 0), vm.trace.cache.items.len);
    try testing.expect(vm.trace.gate.count() >= 1);
    try testing.expect(!vm.trace.isRecording());
}

test "recorder: a set_global in the loop body aborts cleanly" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    // The global counterpart: a `set_global` writes the snapshotted cell, so the
    // recorder aborts rather than recording a stale-input trace.
    var chunk = try runForTrace(&vm, gpa,
        \\g = 0
        \\local s = 0
        \\for j = 1, 80 do g = g + j; s = s + j end
        \\print(s)
    , true);
    defer chunk.deinit();

    try testing.expectEqual(@as(usize, 0), vm.trace.cache.items.len);
    try testing.expect(vm.trace.gate.count() >= 1);
    try testing.expect(!vm.trace.isRecording());
}

test "recorder S1: inlined callee slots are seeded — no callee-index slot_load" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    // The callee reads its parameter `x` and a non-param local `t`. S1 seeds every
    // callee slot `.def` at the `.call` (params → the arg's SSA ref, the rest →
    // konst(nil)), so when the body records, `refOf` resolves those reads to the
    // seeded SSA values and NEVER emits a `slot_load` on a callee register index
    // (slot >= the anchor frame's `num_registers`). A `slot_load` there would be an
    // out-of-window trace input reading uninitialised slab — the exact OOB S1 stops.
    var chunk = try runForTrace(&vm, gpa,
        \\local function f(x) local t = x + 1 return t * t end
        \\local acc = 0
        \\for i = 1, 50 do acc = acc + f(i) end
        \\print(acc)
    , true);
    defer chunk.deinit(); // keep the proto alive: the trace's anchor points into it

    try testing.expectEqual(@as(usize, 1), vm.trace.cache.items.len);
    const t = vm.trace.cache.items[0];
    const anchor_window: i32 = @intCast(chunk.proto.num_registers);

    // The inlining actually happened: a guard_func pins the runtime callee identity.
    var saw_guard_func = false;
    for (t.instrs) |ins| {
        if (ins.op == .guard_func) saw_guard_func = true;
        // S1 invariant: no trace input (`slot_load`) reads a callee-window slot.
        if (ins.op == .slot_load) try testing.expect(ins.aux < anchor_window);
    }
    try testing.expect(saw_guard_func);
}

test "recorder S2: callee SSA slots are dropped from the loop-closing phi set" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    // Callee slots are dead at the outer loop boundary (the call returns before the
    // loop closes), so `commit()`'s phi loop must cap writeback to the anchor window
    // and drop them. Every slot-bound phi (`aux >= 0`) must name a slot strictly
    // below the anchor frame's `num_registers`; a phi at a callee index would make
    // the `.loop` flush write OOB past the executor's single RegWindow.
    var chunk = try runForTrace(&vm, gpa,
        \\local function f(x) local t = x + 1 return t * t end
        \\local acc = 0
        \\for i = 1, 50 do acc = acc + f(i) end
        \\print(acc)
    , true);
    defer chunk.deinit(); // keep the proto alive: the trace's anchor points into it

    try testing.expectEqual(@as(usize, 1), vm.trace.cache.items.len);
    const t = vm.trace.cache.items[0];
    const anchor_window: i32 = @intCast(chunk.proto.num_registers);
    for (t.instrs) |ins| {
        if (ins.op != .phi or ins.aux < 0) continue; // skip the PHI_INTERNAL sentinel
        try testing.expect(ins.aux < anchor_window);
    }
}

test "recorder S3: the verifier window is the anchor frame, below the reserved scratch" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    // S3 pins `assertWellFormed`'s slot bound to the executor's *real* window
    // (`anchor_num_registers`), NOT the grown `reg_map.len`. This test makes that
    // bound load-bearing: it confirms the recorder physically reserved callee
    // scratch ABOVE the anchor window (so callee slots were written at reg_map
    // indices the executor never touches), while the verifier bound stayed pinned
    // to the narrow anchor window. If the two coincided the S3 assertion would be
    // vacuous; here `reg_map.len` strictly exceeds it, so pinning to the narrow
    // bound is what actually catches an OOB callee `aux`.
    var chunk = try runForTrace(&vm, gpa,
        \\local function f(x) local t = x + 1 return t * t end
        \\local acc = 0
        \\for i = 1, 50 do acc = acc + f(i) end
        \\print(acc)
    , true);
    defer chunk.deinit();

    try testing.expectEqual(@as(usize, 1), vm.trace.cache.items.len);
    // The recorder's window bound equals the anchor (top-level main) frame's regs.
    try testing.expectEqual(chunk.proto.num_registers, vm.trace.rec.anchor_num_registers);
    // …and the reserved scratch genuinely extends past it (callee windows live here).
    try testing.expect(vm.trace.rec.reg_map.len > @as(usize, vm.trace.rec.anchor_num_registers));
}

test "recorder: maxrecord bounds trace length (overlong traces abort)" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    // A body that emits more than two IR instructions per iteration; with a tiny
    // budget the recording trips `too_long` and is discarded.
    vm.trace.config.maxrecord = 2;
    var chunk = try runForTrace(&vm, gpa,
        \\local acc = 0
        \\for i = 1, 50 do acc = acc + i + i + i end
        \\print(acc)
    , true);
    defer chunk.deinit();

    try testing.expectEqual(@as(usize, 0), vm.trace.cache.items.len);
    try testing.expect(vm.trace.gate.count() >= 1);
    try testing.expect(!vm.trace.isRecording());
}

// --- hash-field (string-keyed) tracing recorder units (doc 11, H0) ----------
// `obj.field` lowers to `get_index`/`set_index` with an interned *string* key, so
// the recorder routes it to `recHashGet`/`recHashSet` instead of the integer-array
// path. These drive real Lua source through `runForTrace` (so the key is a genuine
// `load_const` `konst`, which the const-key rule requires) and assert the recorded
// IR shape / the abort behaviour. The 8-mode byte-identical proof lives in the
// `expectProgram` tests above; these pin the *shape* the optimizer/native consume.

test "recorder (hash field): a constant-key field read records href + guard_hash + hload + type guard" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var chunk = try runForTrace(&vm, gpa,
        \\local t = {x = 7}
        \\local s = 0
        \\for i = 1, 50 do s = s + t.x end
        \\print(s)
    , true);
    defer chunk.deinit(); // keep the proto alive: the trace's anchor points into it

    var buf: [8192]u8 = undefined;
    const text = try dumpTrace(&buf, &vm);
    // The read decomposes into: guard_table(table) → href(table, "x") →
    // guard_hash(href) → hload(href) → guard_int (the field is an int, pinned so a
    // later type change side-exits). Mirrors the array aref/aload sequence.
    try testing.expect(std.mem.indexOf(u8, text, "guard_table") != null);
    try testing.expect(std.mem.indexOf(u8, text, "href") != null);
    try testing.expect(std.mem.indexOf(u8, text, "guard_hash") != null);
    try testing.expect(std.mem.indexOf(u8, text, "hload") != null);
    try testing.expect(std.mem.indexOf(u8, text, "guard_int") != null);
    // A pure field read sinks no store.
    try testing.expect(std.mem.indexOf(u8, text, "hstore") == null);
    try testing.expectEqual(@as(usize, 1), vm.trace.cache.items.len);
    try testing.expectEqual(@as(usize, 0), vm.trace.gate.count());
}

test "recorder (hash field): an RMW field store (t.n = t.n + 1) sinks the hstore below the load" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var chunk = try runForTrace(&vm, gpa,
        \\local t = {n = 0}
        \\for i = 1, 50 do t.n = t.n + 1 end
        \\print(t.n)
    , true);
    defer chunk.deinit();

    var buf: [8192]u8 = undefined;
    const text = try dumpTrace(&buf, &vm);
    // The read records an hload; the write is a read-modify-write, so its hstore is
    // deferred (C1 store-sinking) and flushed at trace close — it must appear *after*
    // the hload in the stream, never before. A store that landed inline (before the
    // loop close) would diverge on deopt-replay.
    const i_load = std.mem.indexOf(u8, text, "hload");
    const i_store = std.mem.indexOf(u8, text, "hstore");
    try testing.expect(i_load != null);
    try testing.expect(i_store != null);
    try testing.expect(i_load.? < i_store.?);
    try testing.expectEqual(@as(usize, 1), vm.trace.cache.items.len);
}

test "recorder (hash field): a float-valued field RMW records (nbody-shaped arithmetic)" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var chunk = try runForTrace(&vm, gpa,
        \\local p = {x = 0.0}
        \\for i = 1, 50 do p.x = p.x + 0.5 end
        \\print(p.x)
    , true);
    defer chunk.deinit();

    var buf: [8192]u8 = undefined;
    const text = try dumpTrace(&buf, &vm);
    // A float field is in scope (int/float are the two scalar-guardable types); the
    // field is pinned with guard_float, and the RMW store still sinks.
    try testing.expect(std.mem.indexOf(u8, text, "hload") != null);
    try testing.expect(std.mem.indexOf(u8, text, "guard_float") != null);
    try testing.expect(std.mem.indexOf(u8, text, "hstore") != null);
    try testing.expectEqual(@as(usize, 1), vm.trace.cache.items.len);
}

test "recorder (hash field): an absent constant-key access aborts (no trace)" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    // `t.y` is absent at record time. The present-key rule forbids it: an absent-key
    // read is `__index`/migrate territory, and an absent-key store could grow/rehash
    // and dangle every hoisted cell. The recorder aborts → no trace, anchor gated.
    var chunk = try runForTrace(&vm, gpa,
        \\local t = {x = 1}
        \\local c = 0
        \\for i = 1, 50 do if t.y then c = c + 1 end end
        \\print(c)
    , true);
    defer chunk.deinit();

    try testing.expectEqual(@as(usize, 0), vm.trace.cache.items.len);
    try testing.expect(vm.trace.gate.count() >= 1);
    try testing.expect(!vm.trace.isRecording());
}

test "recorder (hash field): a metatable-bearing table aborts (.has_metatable)" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    // A present, constant-key, int field that would otherwise record — but the table
    // carries a metatable, so a present slot could go absent (or `__index` could fire)
    // on a later iteration. The recorder aborts on the metatable edge.
    var chunk = try runForTrace(&vm, gpa,
        \\local t = setmetatable({x = 1}, {})
        \\local s = 0
        \\for i = 1, 50 do s = s + t.x end
        \\print(s)
    , true);
    defer chunk.deinit();

    try testing.expectEqual(@as(usize, 0), vm.trace.cache.items.len);
    try testing.expect(vm.trace.gate.count() >= 1);
    try testing.expect(!vm.trace.isRecording());
}

test "recorder (hash field): a heap-valued (string) field aborts (scalar-only restriction)" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    // The field value is a string (heap). Only int/float fields trace: the scalar
    // exec-log encoder can't serialize a heap value, and a non-scalar field has no
    // strict type guard to pin it across iterations. Aborts as a `.value` lane does.
    var chunk = try runForTrace(&vm, gpa,
        \\local t = {x = "hi"}
        \\local n = 0
        \\for i = 1, 50 do if t.x then n = n + 1 end end
        \\print(n)
    , true);
    defer chunk.deinit();

    try testing.expectEqual(@as(usize, 0), vm.trace.cache.items.len);
    try testing.expect(vm.trace.gate.count() >= 1);
    try testing.expect(!vm.trace.isRecording());
}

test "recorder (hash field): a computed (non-konst) key aborts (const-key rule)" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    // `t[k]` with `k` a runtime variable reaches the hash path (k holds a string), but
    // its key ref is a `slot_load`, not a `konst`. A runtime-varying key cannot be
    // pinned to one cell, so the recorder aborts (v1 scope: only literal `t.field`).
    var chunk = try runForTrace(&vm, gpa,
        \\local t = {a = 1}
        \\local k = "a"
        \\local s = 0
        \\for i = 1, 50 do s = s + t[k] end
        \\print(s)
    , true);
    defer chunk.deinit();

    try testing.expectEqual(@as(usize, 0), vm.trace.cache.items.len);
    try testing.expect(vm.trace.gate.count() >= 1);
    try testing.expect(!vm.trace.isRecording());
}

// --- hash-cell alias classification after deferred stores (doc 08 §2026-08-20) --
// A hash-field load with hstores pending in the deferred-store buffer used to be a
// blanket abort. It now classifies each pending store against the load's (table
// ref, key konst): NO (different key, or an astore — a hash cell and an in-bounds
// array slot can never alias) keeps scanning and falls through to the heap read;
// MUST (same key konst + same table SSA ref) forwards the pending value with no
// re-emitted load chain; MAY (same key, *different* table refs) aborts fail-closed
// — never guard a runtime identity relation between loop-varying refs.

test "recorder (hash alias): different keys on one table classify NO — both RMWs record, neither load forwarded" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    // `t.b`'s read runs with `t.a`'s hstore still pending. Different key konst →
    // NO alias: the read falls through to a real heap load chain, both stores sink.
    var chunk = try runForTrace(&vm, gpa,
        \\local t = {a = 0, b = 0}
        \\for i = 1, 50 do
        \\  t.a = t.a + 1
        \\  t.b = t.b + 2
        \\end
        \\print(t.a + t.b)
    , true);
    defer chunk.deinit();

    var buf: [8192]u8 = undefined;
    const text = try dumpTrace(&buf, &vm);
    // Two heap reads (nothing forwarded), two sunk stores.
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, text, "hload"));
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, text, "hstore"));
    try testing.expectEqual(@as(usize, 1), vm.trace.cache.items.len);
    try testing.expectEqual(@as(usize, 0), vm.trace.gate.count());
}

test "recorder (hash alias): same cell forwards MUST with last-writer-wins and no re-emitted load chain" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    // Three reads of `t.x`, but only the FIRST touches the heap: the second RMW's
    // read forwards the first pending store's value, and `s = s + t.x` forwards the
    // *newest* pending store (last-writer-wins — the buffer is walked newest→oldest).
    // Both stores stay in the buffer and flush in source order at trace close.
    var chunk = try runForTrace(&vm, gpa,
        \\local t = {x = 1}
        \\local s = 0
        \\for i = 1, 50 do
        \\  t.x = t.x + 1
        \\  t.x = t.x * 2
        \\  s = s + t.x
        \\end
        \\print(s)
    , true);
    defer chunk.deinit();

    var buf: [8192]u8 = undefined;
    const text = try dumpTrace(&buf, &vm);
    // Structural: exactly ONE hload (the first read); the two forwarded reads emit
    // no href/guard_hash/hload of their own. The store side keeps its two hstores.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "hload"));
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, text, "hstore"));
    // Ordered flush: the sunk stores appear after the load, in source order.
    const i_load = std.mem.indexOf(u8, text, "hload").?;
    const i_store = std.mem.indexOf(u8, text, "hstore").?;
    try testing.expect(i_load < i_store);
    try testing.expectEqual(@as(usize, 1), vm.trace.cache.items.len);
    try testing.expectEqual(@as(usize, 0), vm.trace.gate.count());
}

test "recorder (hash alias): every sunk hstore's VALUE ref carries its own numeric guard (the store-side type pin)" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    // The load-bearing structural assertion behind the type-drift e2e tests: the
    // upstream operand guards (recArith's) pin the store value in most reachable
    // shapes, so an e2e test alone cannot detect the loss of `recHashSet`'s
    // `guardNum` on the store VALUE — the pin that makes a drifted value side-exit
    // *before* the sunk write lands (and that keeps a MUST-forwarded read's type
    // honest). Assert it directly on the raw IR: each hstore's value operand (.b)
    // must be guarded by an earlier guard_int/guard_float ON THAT SAME REF.
    var chunk = try runForTrace(&vm, gpa,
        \\local t = {n = 0}
        \\for i = 1, 50 do t.n = t.n + 1 end
        \\print(t.n)
    , true);
    defer chunk.deinit();

    try testing.expectEqual(@as(usize, 1), vm.trace.cache.items.len);
    const t = vm.trace.cache.items[0];
    var n_hstore: usize = 0;
    for (t.instrs, 0..) |ins, i| {
        if (ins.op != .hstore) continue;
        n_hstore += 1;
        var pinned = false;
        for (t.instrs[0..i]) |prior| {
            if ((prior.op == .guard_int or prior.op == .guard_float) and prior.a == ins.b) {
                pinned = true;
                break;
            }
        }
        try testing.expect(pinned);
    }
    try testing.expect(n_hstore >= 1); // the loop above must have checked something
}

test "recorder (hash alias): same key through two table refs classifies MAY and aborts (fail-closed)" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    // `t` and `u` hold the SAME table at runtime, but they are different slots, so
    // the recorder materializes two distinct slot_load refs — it cannot prove they
    // alias (MUST) or don't (NO). Forwarding would need a guard on a runtime
    // identity *relation* between two loop-varying refs; the rule is abort instead.
    var chunk = try runForTrace(&vm, gpa,
        \\local t = {x = 0}
        \\local u = t
        \\local s = 0
        \\for i = 1, 50 do
        \\  t.x = t.x + 1
        \\  s = s + u.x
        \\end
        \\print(s)
    , true);
    defer chunk.deinit();

    try testing.expectEqual(@as(usize, 0), vm.trace.cache.items.len);
    try testing.expect(vm.trace.gate.count() >= 1);
    try testing.expect(!vm.trace.isRecording());
}

test "recorder (hash alias): a pending astore never aliases a hash load (NO) — mixed loop records" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    // `t.x`'s read runs with `q[1]`'s astore pending. An in-bounds astore can't
    // grow/migrate the table, and a hash cell is never an array slot, so the
    // classification is airtight NO: the hash read falls through and both record.
    var chunk = try runForTrace(&vm, gpa,
        \\local q = {0}
        \\local t = {x = 5}
        \\local s = 0
        \\for i = 1, 50 do
        \\  q[1] = q[1] + 1
        \\  s = s + t.x
        \\end
        \\print(s + q[1])
    , true);
    defer chunk.deinit();

    var buf: [8192]u8 = undefined;
    const text = try dumpTrace(&buf, &vm);
    try testing.expect(std.mem.indexOf(u8, text, "astore") != null);
    try testing.expect(std.mem.indexOf(u8, text, "hload") != null);
    try testing.expectEqual(@as(usize, 1), vm.trace.cache.items.len);
    try testing.expectEqual(@as(usize, 0), vm.trace.gate.count());
}

test "hash alias e2e: nbody-shaped multi-field RMW loop is byte-identical across all legs" {
    // The type specimen this classification unblocks: nbody's `advance` defers
    // `bj.vx`'s hstore, then immediately reads `bj.vy` — pre-classification that
    // read was a blanket abort, so the whole O(n²) inner loop never traced. The
    // expected text is pinned from tier-0; every GC×trace-mode leg must reproduce
    // it exactly.
    try expectProgram(
        \\local b1 = {x = 0.0, vx = 1.0, vy = 2.0}
        \\local b2 = {x = 5.0, vx = -1.0, vy = 0.5}
        \\for i = 1, 100 do
        \\  local d = b2.x - b1.x
        \\  b1.vx = b1.vx + d * 0.01
        \\  b1.vy = b1.vy + d * 0.02
        \\  b2.vx = b2.vx - d * 0.01
        \\  b2.vy = b2.vy - d * 0.02
        \\  b1.x = b1.x + b1.vx * 0.001
        \\  b2.x = b2.x + b2.vx * 0.001
        \\end
        \\print(b1.x)
        \\print(b2.x)
        \\print(b1.vy)
    ,
        "0.34497907760571167\n4.655020922394289\n11.475260731016911\n",
    );
}

test "hash alias e2e: type drift on a MUST-forwarded cell side-exits cleanly" {
    // `t.x` is int while the trace records; iteration 60 stores a float off-trace
    // (the `i == 60` branch side-exits first). On re-entry the load's guard_int
    // fails and deopts — the forwarded reads must not have weakened the type pin.
    try expectProgram(
        \\local t = {x = 0}
        \\local s = 0
        \\for i = 1, 100 do
        \\  t.x = t.x + 1
        \\  s = s + t.x
        \\  if i == 60 then t.x = 0.5 end
        \\end
        \\print(s)
        \\print(t.x)
    ,
        "2670\n40.5\n",
    );
}

test "hash alias e2e: a side exit after a NO-classified read flushes the deferred store exactly once" {
    // The astore is pending when `t.x`'s NO-classified read records; the `i % 30`
    // branch side-exits mid-iteration. Deopt must replay the deferred store exactly
    // once — a double flush or a lost store diverges `q[1]` or `s` in some mode.
    try expectProgram(
        \\local q = {0}
        \\local t = {x = 1}
        \\local s = 0
        \\for i = 1, 100 do
        \\  q[1] = q[1] + 1
        \\  s = s + t.x
        \\  if i % 30 == 0 then s = s + 1000 end
        \\end
        \\print(s)
        \\print(q[1])
    ,
        "3100\n100\n",
    );
}

test "hash alias e2e: same-cell double store + forwarded read executes last-writer-wins in every leg" {
    // The executable counterpart of the structural last-writer-wins test: two
    // successive stores to `t.x` per iteration (the second RMW's read MUST-forwards
    // the first pending store; `s`'s read MUST-forwards the second), then both
    // pending hstores flush in source order at trace close. A wrong walk direction
    // (oldest→newest) or a wrong flush order diverges `s` and the final `t.x`.
    try expectProgram(
        \\local t = {x = 1}
        \\local s = 0
        \\for i = 1, 100 do
        \\  t.x = t.x + 1
        \\  t.x = t.x + i
        \\  s = s + t.x
        \\end
        \\print(s)
        \\print(t.x)
    ,
        "176850\n5151\n",
    );
}

test "hash alias e2e: store-VALUE type drift is caught before the forwarded read uses it" {
    // Complements the cell-drift test above: here `t.x` is still an int at loop
    // entry on the drift iteration — it is the freshly *stored* value (`t.x + inc`)
    // whose type flips when `inc` becomes float. The guards recorded up-stream of
    // the store (the operand type pins / the store-side `guardNum`) must side-exit
    // BEFORE the forwarded read (`s = s + t.x`) consumes a wrongly-typed pending
    // value; tier-0 then re-runs the whole iteration, keeping every leg identical.
    try expectProgram(
        \\local t = {x = 0}
        \\local s = 0
        \\local inc = 1
        \\for i = 1, 100 do
        \\  t.x = t.x + inc
        \\  s = s + t.x
        \\  if i == 60 then inc = 0.5 end
        \\end
        \\print(s)
        \\print(t.x)
    ,
        "4640\n80\n",
    );
}
