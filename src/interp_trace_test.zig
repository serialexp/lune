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
const trace_snapshot = @import("trace_snapshot.zig");
const trace_ir = @import("trace_ir.zig");
const trace_exec = @import("trace_exec.zig");
const traceser = @import("traceser.zig");
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
    try testing.expect(vm.trace.registry.cache.items.len >= 1);
    try testing.expect(vm.trace.exec_logs.items.len >= 1);
    try testing.expect(vm.trace.abort_log.items.len >= 1);
    try testing.expect(vm.trace.coverage.count() >= 1);

    vm.trace.clearCache();

    // Everything in the reset set is empty/null after the clear.
    try testing.expectEqual(@as(usize, 0), vm.trace.registry.cache.items.len);
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
    try testing.expectEqual(@as(usize, 0), vm.trace.region_policy.edge_cache.count());
    try testing.expectEqual(@as(usize, 0), vm.trace.region_policy.region_defs.count());
    try testing.expectEqual(@as(usize, 0), vm.trace.region_policy.region_intern.entries.items.len);
    try testing.expectEqual(@as(usize, 0), vm.trace.region_policy.source_exit_regions.count());
    try testing.expectEqual(@as(usize, 0), vm.trace.region_policy.dest_entry_regions.count());
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
    try testing.expect(vm.trace.registry.cache.items.len >= 1);
    _ = try vm.run(chunk.proto); // epoch 2 — beginTopLevelEpoch cleared the cache first
    // A fresh trace was recorded in epoch 2 (not left wedged by the reset).
    try testing.expect(vm.trace.registry.cache.items.len >= 1);
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
    for (vm.trace.registry.cache.items) |t| {
        if (t.code.alloc_bound == 0) continue;
        found = true;
        try testing.expectEqual(@as(u32, 1), t.code.alloc_bound);
        var n_guard_gc: usize = 0;
        for (t.code.instrs) |ins| {
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
    for (vm.trace.registry.cache.items) |t| {
        if (t.code.alloc_bound == 0) continue;
        found = true;
        try testing.expectEqual(@as(u32, 4), t.code.alloc_bound);
        var has = [_]bool{ false, false, false, false };
        var n_guard_gc: usize = 0;
        for (t.code.instrs) |ins| {
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
    // Tier-1a config, deliberately: this pins the TIER-1A guard_gc bounce
    // lane. (Historically also forced — pre-doc-25 the body's `%` had no
    // native lowering and `native_codegen`'s safety net would have declined
    // entry entirely; mod now lowers, but the tier-1a lane still deserves
    // its own pin, so the config stays.)
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
    vm.setRecordSafepointLines(true);
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
    for (vm.trace.registry.cache.items) |t| {
        if (t.code.alloc_bound > 0) committed_alloc = true;
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
    // natively where the platform supports it. NB: when this was authored a
    // `%` anywhere in the loop flipped `native_codegen`'s safety net to
    // "decline entirely" (mod then had no lowering) and silently turned this
    // into a tier-0-only comparison; doc 25 has since lowered mod/idiv, but
    // the mod-free body stays — the entries asserts are the real guard.
    try testing.expect(vm.trace.entries > 0);
    if (@import("nativegen.zig").is_x64_linux)
        try testing.expect(vm.trace.native_entries > 0);
}

test "doc 25: a % / // loop runs NATIVELY end-to-end — mod no longer poisons native entry" {
    // The inversion of the arc-B vacuity trap: before doc 25, ONE `%` in a
    // trace made the native safety net decline it entirely (no lowering →
    // never tier-1a either), which is exactly what held scalar at tier-0.
    // This loop carries int `%`, int `//`, AND a mixed int%float (the kernel
    // callout lane) in one body and must (a) match tier-0 output and (b)
    // actually ENTER natively on x64 — `native_entries > 0` is the payoff
    // assertion, not a formality.
    const gpa = testing.allocator;
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    const source =
        \\local u = 0
        \\local f = 0.0
        \\for i = 1, 2000 do
        \\  u = u + i % 10 + i // 7
        \\  f = f + i % 2.5
        \\end
        \\print(u)
        \\print(f)
    ;
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();

    var t0_out: [64]u8 = undefined;
    var t0_len: usize = 0;
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
    try testing.expect(vm.trace.entries > 0);
    if (@import("nativegen.zig").is_x64_linux)
        try testing.expect(vm.trace.native_entries > 0);
}

test "doc 26 D1a: an error unwinding mid-recording aborts the recording (.raised) — no Franken-path commit" {
    // The pre-existing c3-class hazard: `schar1` records under `guard_int`
    // (3000000000 IS an int), then tier-0's `string.char` RAISES `bad
    // argument` — while the recording is active, under an ENCLOSING pcall.
    // Pre-D1a `rec.active` survived the unwind: the recorder would splice the
    // pcall continuation's instructions onto the partial iteration, and a
    // later reach of the anchor could commit the Franken-path. `execWith`'s
    // errdefer now kills the recording at the innermost unwind (.raised).
    const gpa = testing.allocator;
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    const source =
        \\local char = string.char
        \\local function worker(raise)
        \\  -- acc must be a LOCAL: an upvalue write is a set_upval nyi abort,
        \\  -- which would kill the recording before the raise ever happens.
        \\  local acc = 0
        \\  for i = 1, 400 do
        \\    -- hotloop=4 arms after 3 back-edges: iteration 4 is the recorded
        \\    -- one (verified by bisection — thresholds 3 and 5 both put the
        \\    -- raise OUTSIDE the recording and the .raised assert below fails
        \\    -- loudly, so a future tiering shift cannot silently devacuate
        \\    -- this test). Every i >= 4 is out of range, so the recorded
        \\    -- iteration raises mid-recording under the enclosing pcall.
        \\    local cp = 65
        \\    if raise and i >= 4 then cp = 3000000000 end
        \\    local s = char(cp)
        \\    acc = acc + #s
        \\  end
        \\  return acc
        \\end
        \\local ok = pcall(worker, true)
        \\local n = worker(false)
        \\print(ok, n)
    ;
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    vm.trace.config.enabled = true;
    vm.trace.config.execute = false; // recording in isolation — commits stay inert
    vm.trace.config.optimize = false;
    vm.trace.config.hotloop = 4;
    vm.trace.config.record_aborts = true;
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;
    var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    _ = try vm.run(chunk.proto);
    // The raise was caught (ok=false) and the clean leg ran to completion.
    try testing.expectEqualStrings("false\t400\n", sink.buffered());
    // The poisoned recording died with the NEW reason, at the char call.
    var raised_rows: usize = 0;
    for (vm.trace.abort_log.items) |r| {
        if (r.reason == .raised) {
            raised_rows += 1;
            try testing.expectEqual(bytecode.OpCode.call, r.op);
        }
    }
    try testing.expectEqual(@as(usize, 1), raised_rows);
    // No recording is live at the end, and every committed trace is a clean
    // full-iteration recording from the clean leg (anchored at the loop
    // header, containing schar1 — never a partial/spliced body).
    try testing.expect(!vm.trace.isRecording());
    try testing.expect(vm.trace.registry.cache.items.len >= 1);
    for (vm.trace.registry.cache.items) |t| {
        var has_schar1 = false;
        for (t.code.instrs) |ins| {
            if (ins.op == .schar1) has_schar1 = true;
        }
        try testing.expect(has_schar1);
    }
}

test "doc 26: upper/lower/codepoint loop runs NATIVELY end-to-end — pin invariant, budget, one unicode_version effect, replay parity" {
    // The arc's flagship: the three doc-26 ops in one hot loop, executed
    // through the full pipeline (record → tropt → native), under effect
    // RECORDING — proving (a) byte parity with tier-0, (b) the D1 pin
    // invariant end-to-end (`unicode_version_pinned` true, the committed
    // trace stamped `requires_unicode_pin`, native really entered), (c) the
    // budget counts supper+slower but NOT scp (A = 2), and (d) the entire
    // traced run pins the Unicode version exactly ONCE — then a replay of
    // that one-entry log (re-recording from scratch, cache cleared by the
    // epoch) reproduces the output byte-identically.
    const gpa = testing.allocator;
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    const source =
        \\local upper = string.upper
        \\local lower = string.lower
        \\local cp = string.codepoint
        \\local base = "héLlo Αβγ"
        \\local acc = 0
        \\for i = 1, 200 do
        \\  local u = upper(base)
        \\  local l = lower(u)
        \\  acc = acc + #u + #l + cp(l, 3)
        \\end
        \\print(acc)
    ;
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();

    var t0_out: [64]u8 = undefined;
    var t0_len: usize = 0;
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
        try testing.expect(t0_len > 0);
    }

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    vm.trace.config.enabled = true;
    vm.trace.config.execute = true;
    vm.trace.config.optimize = true;
    vm.trace.config.native_codegen = @import("nativegen.zig").is_x64_linux;
    vm.trace.config.hotloop = 4;
    vm.effect_mode = .record;
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;
    var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    _ = try vm.run(chunk.proto);
    try testing.expectEqualStrings(t0_out[0..t0_len], sink.buffered());
    try testing.expect(vm.trace.entries > 0);
    if (@import("nativegen.zig").is_x64_linux)
        try testing.expect(vm.trace.native_entries > 0);

    // D1 end-to-end: the tier-0 upper that necessarily preceded any trace
    // commit pinned the version — ONCE, for 400 case calls + all trace
    // entries (recording shadows execution; executors never re-pin).
    try testing.expect(vm.unicode_version_pinned);
    try testing.expectEqual(@as(usize, 1), vm.effect_log.items.len);
    try testing.expectEqual(interp.EffectKind.unicode_version, vm.effect_log.items[0].kind);

    // The committed trace: all three ops present, `requires_unicode_pin`
    // stamped (M3), and the guard_gc bound counts EXACTLY the two case
    // producers — scp must not inflate A (D3).
    var found = false;
    for (vm.trace.registry.cache.items) |t| {
        var has_supper = false;
        var has_slower = false;
        var has_scp = false;
        var n_guard_gc: usize = 0;
        for (t.code.instrs) |ins| {
            switch (ins.op) {
                .supper => has_supper = true,
                .slower => has_slower = true,
                .scp => has_scp = true,
                .guard_gc => {
                    n_guard_gc += 1;
                    try testing.expectEqual(@as(i32, 2), ins.aux);
                },
                else => {},
            }
        }
        if (!(has_supper and has_slower and has_scp)) continue;
        found = true;
        try testing.expect(t.code.requires_unicode_pin);
        try testing.expectEqual(@as(u32, 2), t.code.alloc_bound);
        try testing.expectEqual(@as(usize, 1), n_guard_gc);
    }
    try testing.expect(found);

    // Replay the one-entry log: fresh epoch (cache cleared, pin reset by the
    // mode flip below), traces re-record DURING replay, the pin re-commits
    // from the log — output byte-identical, no new log entry.
    vm.effect_mode = .replay;
    vm.effect_cursor = 0;
    vm.unicode_version_pinned = false;
    var rep_buf: [64]u8 = undefined;
    var rep_sink = io.Writer.fixed(&rep_buf);
    vm.out = &rep_sink;
    _ = try vm.run(chunk.proto);
    try testing.expectEqualStrings(t0_out[0..t0_len], rep_sink.buffered());
    try testing.expectEqual(@as(usize, 1), vm.effect_log.items.len);
    try testing.expectEqual(@as(usize, 1), vm.effect_cursor);
    try testing.expect(vm.unicode_version_pinned);
}

test "doc 26: scp argument-shape matrix — 1/2/3-arg + negative wrap record with the right operand refs, tier parity" {
    // The recorder's three source arities in one loop: 1-arg (both indices
    // default to konst 1, b == aux), 2-arg with a RUNTIME index (j defaults
    // to i — recBSCodepoint shares the ref, b == aux, non-konst), 2-arg
    // negative konst (wrap is codepointCore's job, recorded as a plain ref),
    // and 3-arg with distinct konsts (b != aux). Byte parity proves the
    // recorded refs resolve to tier-0's exact semantics.
    const gpa = testing.allocator;
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    const source =
        \\local cp = string.codepoint
        \\local s = "héllo wörld"
        \\local acc = 0
        \\for i = 1, 100 do
        \\  acc = acc + cp(s)
        \\  acc = acc + cp(s, i % 8 + 1)
        \\  acc = acc + cp(s, -3)
        \\  acc = acc + cp(s, 2, 4)
        \\end
        \\print(acc)
    ;
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();

    var t0_out: [64]u8 = undefined;
    var t0_len: usize = 0;
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
    }

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
    try testing.expectEqualStrings(t0_out[0..t0_len], sink.buffered());
    try testing.expect(vm.trace.entries > 0);

    // Find the committed loop trace and pin the four operand shapes.
    var found = false;
    for (vm.trace.registry.cache.items) |t| {
        var n_scp: usize = 0;
        var shared_konst_one = false; // 1-arg: b == aux → konst 1
        var shared_runtime = false; // 2-arg runtime i: b == aux, NOT a konst
        var distinct = false; // 3-arg: b != aux
        for (t.code.instrs) |ins| {
            if (ins.op != .scp) continue;
            n_scp += 1;
            if (ins.b == @as(u16, @intCast(ins.aux))) {
                const opnd = t.code.instrs[ins.b];
                if (opnd.op == .konst) {
                    if (t.code.consts[@intCast(opnd.aux)].payload.bits == Value.int(1).payload.bits)
                        shared_konst_one = true;
                } else {
                    shared_runtime = true;
                }
            } else {
                distinct = true;
            }
        }
        if (n_scp == 0) continue;
        found = true;
        try testing.expectEqual(@as(usize, 4), n_scp);
        try testing.expect(shared_konst_one);
        try testing.expect(shared_runtime);
        try testing.expect(distinct);
        // A read-only op class: nothing here allocates, so no budget guard.
        try testing.expectEqual(@as(u32, 0), t.code.alloc_bound);
        try testing.expect(!t.code.requires_unicode_pin);
    }
    try testing.expect(found);
}

test "doc 26: empty-range scp side-exits with deopt-STATE parity — nil-consuming and raising continuations" {
    const gpa = testing.allocator;
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");

    // (a) Nil-consuming continuation, with an ALLOCATION earlier in the same
    // iteration (review M6): when i walks past #s the trace side-exits at the
    // scp; tier-0 replays the PARTIAL iteration — re-running the `sub` as an
    // intern hit — and takes the else branch. Output AND the final heap
    // schedule must match tier-0 exactly (the id-stream claim).
    {
        const source =
            \\local cp = string.codepoint
            \\local sub = string.sub
            \\local s = "héllo"
            \\local acc = 0
            \\for i = 1, 12 do
            \\  local t = sub(s, 1, 2)
            \\  local c = cp(s, i)
            \\  if c then acc = acc + c + #t else acc = acc + 1 end
            \\end
            \\print(acc)
        ;
        var diags = diag.Diagnostics.init(gpa);
        defer diags.deinit();
        var tree = try parser.parse(gpa, source, &diags);
        defer tree.deinit();

        var t0_out: [64]u8 = undefined;
        var t0_len: usize = 0;
        var t0_objs: usize = 0;
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
            t0_next_id = vm.heap.next_obj_id;
        }

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
        try testing.expectEqualStrings(t0_out[0..t0_len], sink.buffered());
        try testing.expectEqual(t0_objs, vm.heap.object_count);
        try testing.expectEqual(t0_next_id, vm.heap.next_obj_id);
        try testing.expect(vm.trace.entries > 0);
    }

    // (b) RAISING continuation: `acc + nil` after the nil-producing call. The
    // traced run must raise the SAME error tier-0 raises (side-exit → tier-0
    // replay → arith raise), with nothing printed in either mode.
    {
        const source =
            \\local cp = string.codepoint
            \\local s = "héllo"
            \\local acc = 0
            \\for i = 1, 12 do
            \\  acc = acc + cp(s, i)
            \\end
            \\print(acc)
        ;
        var diags = diag.Diagnostics.init(gpa);
        defer diags.deinit();
        var tree = try parser.parse(gpa, source, &diags);
        defer tree.deinit();

        var t0_err: ?anyerror = null;
        {
            var vm = try Vm.init(gpa);
            defer vm.deinit();
            var buf: [64]u8 = undefined;
            var sink = io.Writer.fixed(&buf);
            vm.out = &sink;
            var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
            defer chunk.deinit();
            try testing.expect(!diags.hasErrors());
            _ = vm.run(chunk.proto) catch |e| {
                t0_err = e;
            };
            try testing.expect(t0_err != null);
            try testing.expectEqual(@as(usize, 0), sink.buffered().len);
        }

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
        var traced_err: ?anyerror = null;
        _ = vm.run(chunk.proto) catch |e| {
            traced_err = e;
        };
        try testing.expectEqual(t0_err, traced_err);
        try testing.expectEqual(@as(usize, 0), sink.buffered().len);
        // The raise came through the traced path, not a tier-0-only run.
        try testing.expect(vm.trace.entries > 0);
    }
}

test "doc 26: `.pure3` contract — dead scp DCE'd, identical scps never CSE'd, compaction remaps scp.aux, budget untouched" {
    const gpa = testing.allocator;
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    var vm = try Vm.init(gpa);
    defer vm.deinit();

    // The ssub-test vehicle, retargeted at `.pure3`: the CSE'd second mul
    // SHIFTS the ref space (so the aux assertions below exercise a genuinely
    // remapped stream); the two identical LIVE scps must both survive (CSE is
    // deliberately fail-closed for `.pure3` in v1 even though the key covers
    // aux — review M4); the UNUSED third scp is dead and DCE (admitted) must
    // remove it.
    const source =
        \\local cp = string.codepoint
        \\local base = "abcdefgh"
        \\local acc = 0
        \\for i = 1, 50 do
        \\  acc = acc + i * 7 + i * 7
        \\  local x = cp(base, 2, 5)
        \\  local y = cp(base, 2, 5)
        \\  local dead = cp(base, 1, 1)
        \\  acc = acc + x + y
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
    // 14 x (1+..+50) + 50 x (98 + 98) = 17850 + 9800.
    try testing.expectEqualStrings("27650\n", sink.buffered());

    try testing.expectEqual(@as(usize, 1), vm.trace.registry.cache.items.len);
    const t = vm.trace.registry.cache.items[0];
    var n_scp: usize = 0;
    var n_guard_gc: usize = 0;
    var muls: usize = 0;
    for (t.code.instrs) |ins| {
        switch (ins.op) {
            .scp => {
                n_scp += 1;
                // Every surviving scp is a LIVE cp(base, 2, 5): its aux (the
                // end-index ref) must resolve to konst 5 through the
                // compacted ref space. The dead cp(base, 1, 1)'s konst-1 aux
                // never appears — if the dead scp survived DCE, this
                // expectation fails on its aux.
                const jref = t.code.instrs[@intCast(ins.aux)];
                try testing.expectEqual(trace.IrOp.konst, jref.op);
                try testing.expectEqual(Value.int(5).payload.bits, t.code.consts[@intCast(jref.aux)].payload.bits);
            },
            .guard_gc => n_guard_gc += 1,
            .mul => muls += 1,
            else => {},
        }
    }
    // Both identical live scps survive; the dead one is gone.
    try testing.expectEqual(@as(usize, 2), n_scp);
    // CSE really ran (the second `i * 7` merged) — the refs genuinely shifted.
    try testing.expectEqual(@as(usize, 1), muls);
    // scp never inflates the budget: a case-op-free scp trace has NO
    // allocation bound and NO guard_gc at all — and needs no pin.
    try testing.expectEqual(@as(u32, 0), t.code.alloc_bound);
    try testing.expectEqual(@as(usize, 0), n_guard_gc);
    try testing.expect(!t.code.requires_unicode_pin);
}

test "doc 26: recorder fail-closed matrix — float index, multi-result codepoint, non-string arg" {
    const gpa = testing.allocator;
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");

    // (a) A FLOAT index: tier-0's optIntArg coerces 2.0 → 2, but the recorder
    // is int-only (the coercion stays tier-0-owned) — the recording aborts
    // and NO trace with an scp is ever cached. Tier-0 semantics (the coerced
    // read) are preserved bit-for-bit.
    // (b) Multi-result: `local a, b = cp(s, 1, 2)` wants TWO results — that
    // routes to the multi native (a host barrier), never to recBSCodepoint's
    // single-result shape.
    const source =
        \\local cp = string.codepoint
        \\local s = "héllo"
        \\local acc = 0
        \\for i = 1, 60 do
        \\  acc = acc + cp(s, 2.0)
        \\end
        \\local m = 0
        \\for i = 1, 60 do
        \\  local a, b = cp(s, 1, 2)
        \\  m = m + a + b
        \\end
        \\print(acc, m)
    ;
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();

    var t0_out: [64]u8 = undefined;
    var t0_len: usize = 0;
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
    }

    {
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
        try testing.expectEqualStrings(t0_out[0..t0_len], sink.buffered());
        // Fail closed: whatever committed (or nothing did), no scp anywhere.
        for (vm.trace.registry.cache.items) |t| {
            for (t.code.instrs) |ins| try testing.expect(ins.op != .scp);
        }
        try testing.expect(!vm.trace.isRecording());
    }

    // (c) A NON-STRING argument raises in tier-0 (mahina never coerces case
    // ops); mid-loop that raise unwinds through an armed recording (D1a
    // territory) — the traced run must raise the identical error with the
    // identical partial output, and cache no supper.
    {
        const source_c =
            \\local upper = string.upper
            \\local acc = 0
            \\for i = 1, 60 do
            \\  local arg = "x"
            \\  if i >= 30 then arg = true end
            \\  acc = acc + #upper(arg)
            \\end
            \\print(acc)
        ;
        var diags_c = diag.Diagnostics.init(gpa);
        defer diags_c.deinit();
        var tree_c = try parser.parse(gpa, source_c, &diags_c);
        defer tree_c.deinit();

        var t0_err: ?anyerror = null;
        {
            var vm = try Vm.init(gpa);
            defer vm.deinit();
            var buf: [64]u8 = undefined;
            var sink = io.Writer.fixed(&buf);
            vm.out = &sink;
            var chunk = try compiler.compile(gpa, vm.heap, source_c, tree_c.root, &diags_c);
            defer chunk.deinit();
            try testing.expect(!diags_c.hasErrors());
            _ = vm.run(chunk.proto) catch |e| {
                t0_err = e;
            };
            try testing.expect(t0_err != null);
        }

        var vm = try Vm.init(gpa);
        defer vm.deinit();
        vm.trace.config.enabled = true;
        vm.trace.config.execute = true;
        vm.trace.config.optimize = true;
        vm.trace.config.hotloop = 4;
        var buf: [64]u8 = undefined;
        var sink = io.Writer.fixed(&buf);
        vm.out = &sink;
        var chunk = try compiler.compile(gpa, vm.heap, source_c, tree_c.root, &diags_c);
        defer chunk.deinit();
        try testing.expect(!diags_c.hasErrors());
        var traced_err: ?anyerror = null;
        _ = vm.run(chunk.proto) catch |e| {
            traced_err = e;
        };
        try testing.expectEqual(t0_err, traced_err);
        try testing.expect(!vm.trace.isRecording());
    }
}

// ---------------------------------------------------------------------------
// Doc 27 — MULTRET nested-call recording ("multinest"). The compiler encodes
// `f(g(x))` as an adjacent dynamic-multret pair (inner call `c=all_results`
// producer, outer call `b=all_results` consumer) and `return f(...)` as the
// `ret b=all_results` sibling; the recorder resolves both against its
// one-instruction multret shadow instead of aborting `.cross_frame`.
// ---------------------------------------------------------------------------

/// Doc 27 harness: full 10-leg parity via `expectProgram`, PLUS one dedicated
/// non-stress record+execute leg asserting the loop actually committed and
/// entered a trace. The arc's regression risk is a silent fallback to tier-0
/// (recording aborts, output stays right) — parity alone cannot see it, so
/// every shape that must RECORD pins `entries > 0` here.
fn expectRecordedProgram(source: [:0]const u8, expected: []const u8) !void {
    try expectProgram(source, expected);
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var buf: [256]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    var chunk = try util.runExecForTrace(&vm, gpa, source, &sink);
    defer chunk.deinit();
    try testing.expectEqualStrings(expected, sink.buffered());
    try testing.expect(vm.trace.entries > 0);
}

test "doc 27: nested lower(upper(s)) records, runs NATIVELY, chains provenance, and replays byte-identically" {
    // The arc's flagship: the exact shape that aborted `.cross_frame` before
    // doc 27 — a composed builtin call in last-arg position — through the full
    // pipeline (record → tropt → native) under effect RECORDING. Asserts
    // (a) byte parity with tier-0, (b) a real native entry, (c) the committed
    // trace contains `slower` consuming `supper`'s ref DIRECTLY with no
    // intervening `guard_string` (the doc-26 `isProvenStringRef` chain finally
    // firing on the nested form), (d) the D1 unicode pin invariant holds with
    // exactly ONE logged effect, and (e) a replay of that log reproduces the
    // output byte-identically.
    const gpa = testing.allocator;
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    const source =
        \\local upper = string.upper
        \\local lower = string.lower
        \\local base = "héLlo Αβγ"
        \\local acc = 0
        \\for i = 1, 200 do
        \\  acc = acc + #lower(upper(base)) + i
        \\end
        \\print(acc)
    ;
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();

    var t0_out: [64]u8 = undefined;
    var t0_len: usize = 0;
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
        try testing.expectEqualStrings("21900\n", t0_out[0..t0_len]);
    }

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    vm.trace.config.enabled = true;
    vm.trace.config.execute = true;
    vm.trace.config.optimize = true;
    vm.trace.config.native_codegen = @import("nativegen.zig").is_x64_linux;
    vm.trace.config.hotloop = 4;
    vm.effect_mode = .record;
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;
    var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    _ = try vm.run(chunk.proto);
    try testing.expectEqualStrings(t0_out[0..t0_len], sink.buffered());
    try testing.expect(vm.trace.entries > 0);
    if (@import("nativegen.zig").is_x64_linux)
        try testing.expect(vm.trace.native_entries > 0);
    try testing.expect(vm.unicode_version_pinned);
    try testing.expectEqual(@as(usize, 1), vm.effect_log.items.len);
    try testing.expectEqual(interp.EffectKind.unicode_version, vm.effect_log.items[0].kind);

    // Committed-trace shape: `slower` consumes `supper`'s ref directly, and no
    // `guard_string` re-checks the proven producer result in between.
    var found = false;
    for (vm.trace.registry.cache.items) |t| {
        var supper_ref: ?i64 = null;
        var chained = false;
        for (t.code.instrs, 0..) |ins, idx| {
            switch (ins.op) {
                .supper => supper_ref = @intCast(idx),
                .slower => if (supper_ref != null and ins.a == supper_ref.?) {
                    chained = true;
                },
                .guard_string => if (supper_ref != null) {
                    try testing.expect(ins.a != supper_ref.?);
                },
                else => {},
            }
        }
        if (supper_ref != null) {
            found = true;
            try testing.expect(chained);
        }
    }
    try testing.expect(found);

    // Replay the one-entry log: fresh epoch, traces re-record during replay,
    // output byte-identical, exactly the one logged effect consumed.
    vm.effect_mode = .replay;
    vm.effect_cursor = 0;
    vm.unicode_version_pinned = false;
    var rep_buf: [64]u8 = undefined;
    var rep_sink = io.Writer.fixed(&rep_buf);
    vm.out = &rep_sink;
    _ = try vm.run(chunk.proto);
    try testing.expectEqualStrings(t0_out[0..t0_len], rep_sink.buffered());
    try testing.expectEqual(@as(usize, 1), vm.effect_cursor);
}

test "doc 27: depth-3 builtin chain u(l(u(s))) records — no depth anywhere in the mechanism" {
    // The middle call is consumer AND producer at once (§3b: both sentinel
    // flags must be captured before the effective-instr rewrite).
    try expectRecordedProgram(
        \\local u = string.upper
        \\local l = string.lower
        \\local base = "héLlo Αβγ"
        \\local acc = 0
        \\for i = 1, 100 do acc = acc + #u(l(u(base))) + i end
        \\print(acc)
    ,
        "5950\n",
    );
}

test "doc 27: mixed args — trailing producer after a fixed prefix resolves the full arity" {
    // `sub(base, 2, len(up(base)))`: the inner producer sits at `a_outer+3`,
    // so the consumer must resolve nargs = 3, not the depth-1 single-arg case.
    // A wrong resolution either aborts (entries == 0, caught by the harness)
    // or mis-slices (output diverges).
    try expectRecordedProgram(
        \\local sub = string.sub
        \\local len = string.len
        \\local up = string.upper
        \\local base = "héLlo Αβγ"
        \\local acc = 0
        \\for i = 1, 100 do
        \\  local piece = sub(base, 2, len(up(base)))
        \\  acc = acc + #piece + i
        \\end
        \\print(acc)
    ,
        "5850\n",
    );
}

test "doc 27: closure consumer — an inlined Lua callee takes a builtin producer's dynamic window (D3)" {
    try expectRecordedProgram(
        \\local up = string.upper
        \\local function count(s) return #s + 1 end
        \\local base = "héLlo Αβγ"
        \\local acc = 0
        \\for i = 1, 100 do acc = acc + count(up(base)) + i end
        \\print(acc)
    ,
        "6050\n",
    );
}

test "doc 27: closure producer — an inlined callee's fixed ret feeds a builtin's dynamic window (D4)" {
    try expectRecordedProgram(
        \\local up = string.upper
        \\local function id(x) return x end
        \\local base = "héLlo Αβγ"
        \\local acc = 0
        \\for i = 1, 100 do acc = acc + #up(id(base)) + i end
        \\print(acc)
    ,
        "5950\n",
    );
}

test "doc 27: D1+D2+D4+D5 composed — up(ap(low, base)) chains the shadow across a frame boundary" {
    // Inside `ap`, `return f(x)` is a builtin producer (D1) into a `ret
    // b=all_results` consumer (D5); the caller wanted a dynamic window, so
    // `recReturn` re-exports the shadow in caller frame-space (D4) for the
    // outer `up` consumer (D2). The builtin callee arrives as a PARAM (an
    // upvalue read inside an inlined callee would hit the pre-existing U0
    // barrier and mask the multret path).
    try expectRecordedProgram(
        \\local up = string.upper
        \\local low = string.lower
        \\local function ap(f, x) return f(x) end
        \\local base = "héLlo Αβγ"
        \\local acc = 0
        \\for i = 1, 100 do acc = acc + #up(ap(low, base)) + i end
        \\print(acc)
    ,
        "5950\n",
    );
}

test "doc 27: return prefixes — `return prefix, g()` counts prefix + produced (zero/one/multi legs)" {
    // codex #7: exactly where an off-by-prefix or D4 frame-space error changes
    // VALUES silently. `two` = prefix + builtin producer (produced 2 into
    // want 2); `pz` = prefix + zero-returning closure (produced 1, want 2 →
    // nil-fill pinned by the `d == nil` branch); `pm` = prefix + two-value
    // closure (produced 3 into want 3). All callees are param-clean (no
    // upvalue reads inside inlined callees — U0 would mask the shapes).
    try expectRecordedProgram(
        \\local up = string.upper
        \\local base = "héLlo Αβγ"
        \\local function two(f, x) return #x, f(x) end
        \\local function zero() end
        \\local function pz(z, x) return #x, z() end
        \\local function multi() return 10, 20 end
        \\local function pm(m, x) return #x, m() end
        \\local acc = 0
        \\for i = 1, 100 do
        \\  local a, b = two(up, base)
        \\  acc = acc + a + #b
        \\  local c, d = pz(zero, base)
        \\  acc = acc + c + (d == nil and 5 or 0)
        \\  local e, f, g = pm(multi, base)
        \\  acc = acc + e + f + g
        \\end
        \\print(acc)
    ,
        "7100\n",
    );
}

test "doc 27: method-call consumer — obj:m(prefix, g()) stays byte-identical in every leg" {
    // codex #8: `compileMethodArgs` puts the implicit `self` before the dynamic
    // tail. The method lookup itself is not yet recordable (`get_index` NYI
    // aborts the recording), so this is a parity pin on the compiled multret
    // shape, not a recording assertion — when method calls become recordable,
    // wrap this in `expectRecordedProgram` to inherit the stronger check.
    try expectProgram(
        \\local len = string.len
        \\local obj = {}
        \\function obj.m(self, p, q) return p + q end
        \\local base = "héLlo Αβγ"
        \\local acc = 0
        \\for i = 1, 100 do acc = acc + obj:m(2, len(base)) end
        \\print(acc)
    ,
        "1100\n",
    );
}

test "doc 27: select('#', g()) — the resolved arity IS the folded result (off-by-one is a wrong value)" {
    // codex #9: the effective `b` is semantically load-bearing. `select('#',
    // up(base))` resolves b = 2 and folds konst 1; any resolution error
    // changes the printed sum, not just trace shape.
    try expectRecordedProgram(
        \\local up = string.upper
        \\local base = "héLlo Αβγ"
        \\local acc = 0
        \\for i = 1, 100 do acc = acc + select('#', up(base)) + i end
        \\print(acc)
    ,
        "5150\n",
    );
}

test "doc 27: rawset as producer — effective c=1 defines the result slot before the shadow publishes" {
    // codex #10: rawset's arm result write is conditional on `c == 1`; under
    // producer `c = all_results` the rewrite must still define slot `a` (the
    // consumer reads it as its argument). `rawget(t, 1)` pins the store
    // actually landed each iteration.
    try expectRecordedProgram(
        \\local t = {0}
        \\local acc = 0
        \\for i = 1, 100 do
        \\  acc = acc + select('#', rawset(t, 1, i)) + rawget(t, 1)
        \\end
        \\print(acc)
    ,
        "5150\n",
    );
}

test "doc 27: zero-produced — f(g()) with a void closure resolves nargs = 0 and keeps recording" {
    try expectRecordedProgram(
        \\local function seven() return 7 end
        \\local function zero() end
        \\local acc = 0
        \\for i = 1, 100 do acc = acc + seven(zero()) + i end
        \\print(acc)
    ,
        "5750\n",
    );
}

test "doc 27: fail-closed — multi-result codepoint producer and vararg spread abort with parity" {
    // (a) `cp(s, 1, 3)` can produce ≠1 values: excluded from the D1 whitelist,
    // recording aborts `.cross_frame` (verified via --dump-aborts), output
    // identical in every leg.
    try expectProgram(
        \\local cp = string.codepoint
        \\local base = "héLlo Αβγ"
        \\local acc = 0
        \\for i = 1, 100 do acc = acc + (type(cp(base, 1, 3)) == "number" and 1 or 0) + i end
        \\print(acc)
    ,
        "5150\n",
    );
    // (b) `f(...)` — a vararg spread producer never sets the shadow (the
    // vararg callee aborts recording first); parity across all legs.
    try expectProgram(
        \\local function fix(a, b, c) return (a or 0) + (b or 0) + (c or 0) end
        \\local function sp(...) return fix(...) end
        \\local acc = 0
        \\for i = 1, 100 do acc = acc + sp(1, 2, i) end
        \\print(acc)
    ,
        "5350\n",
    );
}

test "doc 27 §3a: the multret shadow never survives reset or an abort" {
    // Lifetime regression (codex MUST-FIX): a `maxrecord` abort fires in
    // `recordInstr` BEFORE `recordOne`'s stash-and-clear, so without explicit
    // clearing a stale shadow could leak into the NEXT recording and bake a
    // garbage count. Two legs:
    //
    // (1) reset is the soundness boundary: a planted shadow is gone after
    //     `Recorder.reset`.
    // (2) a real recording killed by `maxrecord` (which repeatedly aborts
    //     mid-body across the run, wherever the budget lands — including
    //     between a producer and its consumer) leaves no shadow behind, and
    //     the program's output is unperturbed.
    const gpa = testing.allocator;
    {
        const parser = @import("parser.zig");
        const diag = @import("diag.zig");
        var diags = diag.Diagnostics.init(gpa);
        defer diags.deinit();
        const source = "print(1)";
        var tree = try parser.parse(gpa, source, &diags);
        defer tree.deinit();
        var vm = try Vm.init(gpa);
        defer vm.deinit();
        var buf: [64]u8 = undefined;
        var sink = io.Writer.fixed(&buf);
        vm.out = &sink;
        var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
        defer chunk.deinit();
        try testing.expect(!diags.hasErrors());
        _ = try vm.run(chunk.proto);
        vm.trace.rec.multret_top = 7; // plant a stale shadow
        try vm.trace.startRecordingForTest(gpa, .{ .proto = chunk.proto, .pc = 0, .proto_id = chunk.proto.id }, 4);
        try testing.expectEqual(@as(?u32, null), vm.trace.rec.multret_top);
    }
    {
        var vm = try Vm.init(gpa);
        defer vm.deinit();
        vm.trace.config.enabled = true;
        vm.trace.config.execute = true;
        vm.trace.config.hotloop = 4;
        vm.trace.config.maxrecord = 8; // kill every recording almost immediately
        var buf: [64]u8 = undefined;
        var sink = io.Writer.fixed(&buf);
        vm.out = &sink;
        try util.compileRun(gpa, &vm,
            \\local up = string.upper
            \\local low = string.lower
            \\local base = "héLlo Αβγ"
            \\local acc = 0
            \\for i = 1, 100 do acc = acc + #low(up(base)) + i end
            \\print(acc)
        );
        try testing.expectEqualStrings("5950\n", sink.buffered());
        try testing.expectEqual(@as(?u32, null), vm.trace.rec.multret_top);
    }
}

test "doc 27: deopt through the pair — side exits replay the whole iteration, reg_top set by tier-0 itself" {
    // §5: no exit ever resumes tier-0 between producer and consumer — the
    // deopt iteration re-runs from the loop header, re-executing the producer
    // in tier-0 (which sets `reg_top`) before the consumer needs it. The
    // `i % 30` branch guard fails three times mid-run; every leg must print
    // the same bytes.
    try expectRecordedProgram(
        \\local up = string.upper
        \\local low = string.lower
        \\local s = "héLlo Αβγ"
        \\local acc = 0
        \\for i = 1, 100 do
        \\  acc = acc + #low(up(s))
        \\  if i % 30 == 0 then acc = acc + 1000 end
        \\end
        \\print(acc)
    ,
        "3900\n",
    );
}

// ---------------------------------------------------------------------------
// MAX_TRACE_INPUTS (trace.zig) — the synthetic-entry-input budget for
// upvalue/global/hash_cell snapshots. Measured free through N=64 (flat jit
// cost, upvalue-vs-anchor-local control identical within noise; see
// CURRENT_TASK LATEST-94), so the constant is 64: a pure-policy backstop, not
// a tuning knob. These two tests pin both sides of the boundary.
// ---------------------------------------------------------------------------

test "input cap: 12 distinct upvalue inputs record — the old cap of 8 silently killed this shape" {
    // Before the 8→64 raise, the 9th `get_upval` at the anchor aborted
    // `.input_cap` (then still tagged `.too_deep`) and this loop fell back to
    // tier-0 forever with byte-perfect
    // output — exactly the silent regression `expectRecordedProgram` exists to
    // catch. 12 * (50*51/2) + (1+..+12) * 50 = 19200.
    try expectRecordedProgram(
        \\local f1 = function(x) return x + 1 end
        \\local f2 = function(x) return x + 2 end
        \\local f3 = function(x) return x + 3 end
        \\local f4 = function(x) return x + 4 end
        \\local f5 = function(x) return x + 5 end
        \\local f6 = function(x) return x + 6 end
        \\local f7 = function(x) return x + 7 end
        \\local f8 = function(x) return x + 8 end
        \\local f9 = function(x) return x + 9 end
        \\local f10 = function(x) return x + 10 end
        \\local f11 = function(x) return x + 11 end
        \\local f12 = function(x) return x + 12 end
        \\local function run()
        \\  local acc = 0
        \\  for i = 1, 50 do
        \\    acc = acc + f1(i) + f2(i) + f3(i) + f4(i) + f5(i) + f6(i)
        \\    acc = acc + f7(i) + f8(i) + f9(i) + f10(i) + f11(i) + f12(i)
        \\  end
        \\  return acc
        \\end
        \\print(run())
    ,
        "19200\n",
    );
}

test "input cap: 70 distinct upvalue inputs exceed the cap of 64 — fail-closed with parity, zero entries" {
    // The over-budget side: input #65 must abort `.input_cap` cleanly (never a
    // partial trace or wrong values), so the loop runs tier-0 with identical
    // output and NOTHING commits. 70 callees are comptime-generated.
    // 70 * (60*61/2) + (1+..+70) * 60 = 277200.
    const source: [:0]const u8 = comptime blk: {
        var s: [:0]const u8 = "";
        for (1..71) |k| {
            s = s ++ std.fmt.comptimePrint("local f{d} = function(x) return x + {d} end\n", .{ k, k });
        }
        s = s ++ "local function run()\n  local acc = 0\n  for i = 1, 60 do\n    acc = acc";
        for (1..71) |k| {
            s = s ++ std.fmt.comptimePrint(" + f{d}(i)", .{k});
        }
        s = s ++ "\n  end\n  return acc\nend\nprint(run())";
        break :blk s;
    };
    try expectProgram(source, "277200\n");
    // Dedicated record-attempt leg: recording runs (hotloop=4), every attempt
    // aborts at the 65th input, and no trace is ever entered. The abort table
    // must NAME the limit — `.input_cap`, not the once-overloaded `.too_deep`
    // that forced the LATEST-94 guesswork.
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    vm.trace.config.record_aborts = true;
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    var chunk = try util.runExecForTrace(&vm, gpa, source, &sink);
    defer chunk.deinit();
    try testing.expectEqualStrings("277200\n", sink.buffered());
    try testing.expect(vm.trace.entries == 0);
    var saw_input_cap = false;
    for (vm.trace.abort_log.items) |r| {
        try testing.expect(r.reason != .too_deep); // nothing here nests deeply
        if (r.reason == .input_cap) saw_input_cap = true;
    }
    try testing.expect(saw_input_cap);
}

test "input cap: writeTrace header reports the synthetic-input count against the budget" {
    // `--dump-traces` renders `inputs=N/cap` on every trace header so a dump
    // answers "how close to the input budget?" directly — the LATEST-94
    // misdiagnosis (str_manip read as cap-blocked while its main trace used
    // 7 of 8) happened because nothing printed this number. Two upvalues read
    // at the anchor (`up`, `base`) must show as exactly 2.
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var chunk = try runForTrace(&vm, gpa,
        \\local up = string.upper
        \\local base = "abc"
        \\local function run()
        \\  local acc = 0
        \\  for i = 1, 50 do acc = acc + #up(base) end
        \\  return acc
        \\end
        \\print(run())
    , true);
    defer chunk.deinit();
    var buf: [16384]u8 = undefined;
    const text = try dumpTrace(&buf, &vm);
    try testing.expect(std.mem.indexOf(u8, text, "  inputs=2/") != null);
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

test "chunk rooting: appendLoadedChunk pins constants (survive GC without per-cycle rooting)" {
    // `loaded_chunks` constants are immortal via the pin set in
    // `appendLoadedChunk` — NOT via the `.gc` root walk, which skips the
    // loaded list entirely (re-walking every loaded tree each cycle made GC
    // O(all chunks ever loaded)). Three assertions: the pin bit is set, the
    // literal survives a stress GC even though the chunk never ran and nothing
    // else references it, and the `.gc` walk really does not enumerate it
    // (while the `.snapshot` walk still does — restore needs the ids).
    const gpa = testing.allocator;
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();

    const src_b: [:0]const u8 = "print(\"pinnedlit\")\n"; // never run
    const src_c: [:0]const u8 = "for i = 1, 100 do local j = {} end\n"; // GC driver

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    vm.heap.gc_stress = true;
    var sink: [16]u8 = undefined;
    var w = io.Writer.fixed(&sink);
    vm.out = &w;

    var tb = try parser.parse(gpa, src_b, &diags);
    defer tb.deinit();
    const chunk_b = try compiler.compile(gpa, vm.heap, src_b, tb.root, &diags);
    var tc = try parser.parse(gpa, src_c, &diags);
    defer tc.deinit();
    var cc = try compiler.compile(gpa, vm.heap, src_c, tc.root, &diags);
    defer cc.deinit();
    try testing.expect(!diags.hasErrors());

    // Hand B to the VM the way load()/the C API do (VM owns chunk + source now).
    const owned: [:0]u8 = try gpa.dupeSentinel(u8, src_b, 0);
    try vm.appendLoadedChunk(.{ .chunk = chunk_b, .source = owned });

    const lit = vm.heap.internedLookup("pinnedlit") orelse return error.TestUnexpectedResult;
    try testing.expect(lit.header.flags.pinned);

    _ = try vm.run(cc.proto); // stress GC — survives via the pin alone
    try testing.expect(vm.heap.internedLookup("pinnedlit") != null);

    // The root walk must NOT enumerate the pinned constant: the pin alone keeps
    // it. (A keyframe carries it because it carries every unswept object.)
    const Counter = struct {
        target: *object.GcHeader,
        hits: usize = 0,
        fn cb(self: *@This(), h: *object.GcHeader) void {
            if (h == self.target) self.hits += 1;
        }
    };
    var gc_count: Counter = .{ .target = &lit.header };
    vm.forEachRootHeader(&gc_count, Counter.cb);
    try testing.expectEqual(@as(usize, 0), gc_count.hits);
}

test "chunk rooting: releaseChunk preserves survivor order (orderedRemove, not swapRemove)" {
    // Root-discovery order = retain order (docs/design/03), so releasing a NON-last
    // borrow must keep the survivors' relative order: releasing X from [X,Y,Z] leaves
    // [Y,Z]. A `swapRemove` would leave [Z,Y]. (Keyframes no longer depend on root
    // order — they serialize the whole heap by id, doc 61 Phase K — but the
    // retain list stays ordered so mark order stays a function of host actions.)
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
        try testing.expectEqual(@as(usize, 1), vm.trace.registry.cache.items.len);
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
        try testing.expectEqual(@as(usize, 1), vm.trace.registry.cache.items.len);
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
        try testing.expectEqual(@as(usize, 1), vm.trace.registry.cache.items.len);
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
    // 300 calls would also trip the doc-44 function-head anchor (hotcall=112)
    // and add a head trace of `g`'s body — this test pins the LOOP anchor's
    // cache shape, so park hot-call counting out of reach.
    vm.trace.config.hotcall = std.math.maxInt(u32);
    vm.trace.config.record_aborts = true; // populate abort_log so we can read the reason
    var buf: [256]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;
    var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    _ = try vm.run(chunk.proto);
    // The static anchor records and commits, inlining the loaded callee.
    try testing.expectEqual(@as(usize, 1), vm.trace.registry.cache.items.len);
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

    // One cached trace → one exec log keyed by its stable Trace.id.
    try testing.expectEqual(@as(usize, 1), vm.trace.registry.cache.items.len);
    try testing.expectEqual(@as(usize, 1), vm.trace.exec_logs.items.len);
    const log = vm.trace.exec_logs.items[0];
    try testing.expectEqual(vm.trace.registry.cache.items[0].id, log.trace_id);
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
    try testing.expect(last.ref < vm.trace.registry.cache.items[0].code.instrs.len);
    try testing.expectEqual(execlog.ExitKind.guard, entry.exit_kind);
    try testing.expectEqual(@as(u32, last.ref), entry.exit_ref);
}

test "exec-log string values are owned bytes: a sweep of the strings leaves the log serializable (doc 61 §7.1 item 7)" {
    // The traced loop loads a runtime-built heap string from a slot and guards
    // it (`value` + `guard_pass` events carrying the string). The string then
    // becomes garbage and a collection sweeps it — the trace pool no longer
    // roots it, and neither may the log. The log must still encode and
    // round-trip with the original bytes.
    const gpa = testing.allocator;
    const source =
        \\local function f(s) local n = 0 for i = 1, 40 do n = n + #s end return n end
        \\local t = 0
        \\for k = 1, 3 do t = t + f(string.format("word-%d", k)) end
        \\print(t)
    ;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    var chunk = try runForExecLog(&vm, gpa, source, &sink, true);
    defer chunk.deinit();
    try testing.expectEqualStrings("720\n", sink.buffered());
    try testing.expect(vm.trace.exec_logs.items.len >= 1);

    // "word-1" was overwritten in its register by the later calls (the last
    // one, "word-3", still sits in main's scanned window), so it is garbage.
    vm.collect();
    try testing.expect(vm.heap.internedLookup("word-1") == null); // really swept

    const execlogser = @import("execlogser.zig");
    const bytes = try execlogser.encodeFile(gpa, vm.trace.exec_logs.items);
    defer gpa.free(bytes);
    const back = try execlogser.decodeFile(gpa, bytes);
    defer execlogser.freeLogs(gpa, back);

    var strings: usize = 0;
    var swept_seen = false;
    for (back) |log| {
        // Every surviving log joins to a live trace by id.
        try testing.expect(vm.trace.traceById(log.trace_id) != null);
        for (log.entries.items) |e| for (e.events) |ev| switch (ev.value) {
            .string => |s| {
                try testing.expect(std.mem.startsWith(u8, s, "word-"));
                swept_seen = swept_seen or std.mem.eql(u8, s, "word-1");
                strings += 1;
            },
            else => {},
        };
    }
    try testing.expect(strings > 0);
    try testing.expect(swept_seen); // the swept string's bytes survived in the log
}

test "exec logs after a retire and re-record: the retired trace's log is dropped, the new one joins by id (doc 61 §7.1 item 7)" {
    // `f`'s loop is traced over the pattern "%d+", which only the trace's
    // pool names once the call returns. `collect()` sweeps it, retiring the
    // trace and its log; the second call re-records the loop under a new
    // id over "%a+". The serialized logs must name only live traces, carry
    // no event from the retired trace, and carry the re-recorded one's.
    const gpa = testing.allocator;
    const source =
        \\local find = string.find
        \\local function f(p) local n = 0 for i = 1, 40 do if find("ab12", p) then n = n + 1 end end return n end
        \\local function g(class) return f(class .. "+") end
        \\print(g("%d"))
        \\collect()
        \\print(g("%a"))
    ;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    try util.installCollect(&vm);
    vm.trace.config.optimize = true; // the pattern pin makes "%d+" a pool constant
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    var chunk = try runForExecLog(&vm, gpa, source, &sink, true);
    defer chunk.deinit();
    try testing.expectEqualStrings("40\n40\n", sink.buffered());
    try testing.expect(vm.trace.retired_traces >= 1);
    try testing.expect(vm.trace.registry.cache.items.len >= 1); // the re-record
    try testing.expect(vm.heap.internedLookup("%d+") == null);

    const execlogser = @import("execlogser.zig");
    const bytes = try execlogser.encodeFile(gpa, vm.trace.exec_logs.items);
    defer gpa.free(bytes);
    const back = try execlogser.decodeFile(gpa, bytes);
    defer execlogser.freeLogs(gpa, back);

    var new_pattern_seen = false;
    for (back) |log| {
        try testing.expect(vm.trace.traceById(log.trace_id) != null);
        for (log.entries.items) |e| for (e.events) |ev| switch (ev.value) {
            .string => |s| {
                try testing.expect(!std.mem.eql(u8, s, "%d+"));
                new_pattern_seen = new_pattern_seen or std.mem.eql(u8, s, "%a+");
            },
            else => {},
        };
    }
    try testing.expect(new_pattern_seen);
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
    try testing.expectEqual(@as(usize, 1), vm.trace.registry.cache.items.len);
    const t = vm.trace.registry.cache.items[0];
    const ei = vm.trace.last_exit_instr;
    try testing.expect(ei < t.code.instrs.len);

    // The failing instruction must be a guard.
    const failed = t.code.instrs[ei];
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
    try testing.expect(vm.trace.registry.cache.items.len >= 2);
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
        try testing.expectEqual(@as(usize, 1), vm.trace.registry.cache.items.len);
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
        try testing.expect(vm.trace.registry.cache.items.len >= 2);
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
    try testing.expectEqual(@as(usize, 1), vm.trace.registry.cache.items.len);
    var w = io.Writer.fixed(buf);
    try trace.writeTrace(&w, vm.trace.registry.cache.items[0]);
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

    const t = vm.trace.registry.cache.items[0];
    // acc and the loop index are loop-carried, so they surface as slot-bound φs.
    var n_phi: usize = 0;
    for (t.code.instrs) |ins| {
        if (ins.op == .phi and ins.aux >= 0) n_phi += 1;
    }
    try testing.expect(n_phi >= 1);
    try testing.expect(t.code.entry_slots.len >= 1);
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
    // the dead-φ filter (doc 61 §5) gives them no φ.
    var chunk = try runForTrace(&vm, gpa,
        \\local acc = 0
        \\for i = 1, 50 do acc = acc + (i + 7) * (i + 7) end
        \\print(acc)
    , true);
    defer chunk.deinit(); // keep the proto alive: the trace's anchor points into it

    try testing.expectEqual(@as(usize, 1), vm.trace.registry.cache.items.len);
    const t = vm.trace.registry.cache.items[0];

    // Recover the numeric-for base from the bytecode so the assertion does not
    // hard-code the compiler's register allocation. Control regs are base..base+3;
    // base+4 is the first temporary slot.
    var base: ?u16 = null;
    for (chunk.proto.code) |ins| {
        if (ins.op == .for_loop) {
            base = ins.a;
            break;
        }
    }
    const first_temp: usize = @as(usize, base.?) + 4;

    // Every surviving slot-bound φ is either a real local / loop control or a
    // slot the trace actually read — never a dead temporary.
    var saw_acc = false;
    for (t.code.instrs) |ins| {
        if (ins.op != .phi or ins.aux < 0) continue;
        const slot: u16 = @intCast(ins.aux);
        const was_read = std.mem.indexOfScalar(u16, t.code.entry_slots, slot) != null;
        try testing.expect(@as(usize, slot) < first_temp or was_read);
        if (slot == 0) saw_acc = true; // `acc` is the first local → slot 0
    }
    // The loop-carried accumulator is still committed.
    try testing.expect(saw_acc);
}

/// The write-only φ slots of the first cached trace: written back at the
/// close but never read by the trace at entry.
fn writeOnlyPhiSlots(t: *const trace.Trace, out: *std.ArrayList(u16), gpa: std.mem.Allocator) !void {
    for (t.code.instrs) |ins| {
        if (ins.op != .phi or ins.aux == trace_ir.PHI_INTERNAL) continue;
        const slot: u16 = @intCast(ins.aux);
        if (std.mem.indexOfScalar(u16, t.code.entry_slots, slot) == null) try out.append(gpa, slot);
    }
}

test "recorder: a while loop writes back no temporary dead at its header" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    // The `i <= 50` condition computes into a write-only temporary that is
    // dead at the loop header (the only pc tier-0 resumes at after a
    // back-edge commit), so liveness drops its φ: nothing stores it every
    // iteration. (The numeric-for watermark this replaced never filtered a
    // while loop.)
    var chunk = try runForTrace(&vm, gpa,
        \\local i = 1
        \\local acc = 0
        \\while i <= 50 do acc = acc + i; i = i + 1 end
        \\print(acc)
    , true);
    defer chunk.deinit(); // keep the proto alive: the trace's anchor points into it

    var slots: std.ArrayList(u16) = .empty;
    defer slots.deinit(gpa);
    try writeOnlyPhiSlots(vm.trace.registry.cache.items[0], &slots, gpa);
    try testing.expectEqual(@as(usize, 0), slots.items.len);
}

test "recorder: an allocating loop writes back no string temporary dead at its header (doc 61 §9b)" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    // `s` holds a fresh string every iteration (`tostring` allocates on
    // trace; `..` is not recorded) and is dead at the header, as are the
    // call's temporaries. Doc 24 D3 used to write back every slot an
    // allocating body wrote, because the collector rooted every register;
    // under masking they get no φ, as in a non-allocating loop.
    var chunk = try runForTrace(&vm, gpa,
        \\local i, n = 1, 0
        \\while i <= 50 do
        \\  local s = tostring(i)
        \\  n = n + #s
        \\  i = i + 1
        \\end
        \\print(n)
    , true);
    defer chunk.deinit();

    try testing.expectEqual(@as(usize, 1), vm.trace.registry.cache.items.len);
    const t = vm.trace.registry.cache.items[0];
    // An ordinary allocating trace, not a precise one (which keeps every φ
    // because it loads every slot at entry).
    try testing.expect(t.code.alloc_bound > 0);
    try testing.expectEqual(trace_snapshot.DeoptMode.entry_replay, t.code.deopt_mode);
    var slots: std.ArrayList(u16) = .empty;
    defer slots.deinit(gpa);
    try writeOnlyPhiSlots(t, &slots, gpa);
    try testing.expectEqual(@as(usize, 0), slots.items.len);
}

const live_on_untaken_branch =
    \\local i, last, s = 1, 0, 0
    \\while i <= 50 do
    \\  if i == 40 then s = s + last end
    \\  last = i * 2
    \\  i = i + 1
    \\end
    \\print(s, last)
;

test "recorder: a write-only slot live at the anchor keeps its φ" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    // The trace takes the `i ~= 40` direction, so it never reads `last`
    // (slot 1, locals allocate in order) and only writes it. But the other
    // direction reads it before the write, so it is live at the anchor and
    // its writeback stays.
    var chunk = try runForTrace(&vm, gpa, live_on_untaken_branch, true);
    defer chunk.deinit();

    var slots: std.ArrayList(u16) = .empty;
    defer slots.deinit(gpa);
    try writeOnlyPhiSlots(vm.trace.registry.cache.items[0], &slots, gpa);
    try testing.expect(std.mem.indexOfScalar(u16, slots.items, 1) != null);
}

test "recorder: a deopt onto a branch that reads a write-only slot sees its last write" {
    // At i == 40 the branch guard deopts to the anchor with the committed
    // registers; tier-0 then reads `last`, which must be i == 39's write.
    try expectProgram(live_on_untaken_branch, "78\t100\n");
}

test "recorder: φ liveness covers a loop-done exit's post-loop pc" {
    // `k` is dead at the inner loop's body start (`k = i` writes it first),
    // which is both the inner root's anchor and the continuation's `.link`
    // target. It is live after the inner loop, where a loop-done exit resumes
    // with the φ-written registers: the final `for_loop` test for the root,
    // and the `for_prep` first-trip test for the continuation (`n == 0`
    // skips the loop and must read the `k = 0` the continuation wrote).
    try expectProgram(
        \\local total = 0
        \\for j = 1, 400 do
        \\  local k = 0
        \\  local n = j % 7
        \\  for i = 1, n do k = i end
        \\  total = total + k * 10 + n
        \\end
        \\print(total)
    , "13178\n");
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

    try testing.expectEqual(@as(usize, 1), vm.trace.registry.cache.items.len);
    const t = vm.trace.registry.cache.items[0];
    var sevens: usize = 0;
    for (t.code.consts) |c| {
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

    try testing.expectEqual(@as(usize, 1), vm.trace.registry.cache.items.len);
    const t = vm.trace.registry.cache.items[0];
    // The two `i * 7` subexpressions are now identical (same slot_load ref + same
    // interned konst ref), so CSE collapses them to a single `mul`. Before konst
    // interning, CSE could not fire here and both muls survived.
    var muls: usize = 0;
    for (t.code.instrs) |ins| {
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

    try testing.expectEqual(@as(usize, 1), vm.trace.registry.cache.items.len);
    const t = vm.trace.registry.cache.items[0];
    // The `.alloc` class is codex #8: a repeat is a FALLIBLE op tier-0
    // performs (host scratch precedes the intern), so identical ssubs must
    // BOTH survive — CSE'ing one away would drop an allocation the id-stream
    // bound accounts for. And each aux must still resolve to the konst 5 end
    // bound after DCE shifted the ref space.
    var n_ssub: usize = 0;
    for (t.code.instrs) |ins| {
        if (ins.op != .ssub) continue;
        n_ssub += 1;
        const jref = t.code.instrs[@intCast(ins.aux)];
        try testing.expectEqual(trace.IrOp.konst, jref.op);
        try testing.expectEqual(Value.int(5).payload.bits, t.code.consts[@intCast(jref.aux)].payload.bits);
    }
    try testing.expectEqual(@as(usize, 2), n_ssub);
    try testing.expectEqual(@as(u32, 2), t.code.alloc_bound);
    // The second `i * 7` was CSE'd — proof that compaction actually ran and
    // the aux checks above exercised a genuinely REMAPPED ref space.
    var muls: usize = 0;
    for (t.code.instrs) |ins| {
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
    // blacklisted (an aborted anchor would have been record-gated — doc 31:
    // aborts land in `record_gate`, so both maps must stay empty here).
    try testing.expectEqual(@as(usize, 1), vm.trace.registry.cache.items.len);
    try testing.expectEqual(@as(usize, 0), vm.trace.gate.count());
    try testing.expectEqual(@as(usize, 0), vm.trace.record_gate.count());
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
    try testing.expectEqual(@as(usize, 0), vm.trace.registry.cache.items.len);
    try testing.expect(vm.trace.record_gate.count() >= 1); // doc 31: aborts gate RECORDING
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

    try testing.expectEqual(@as(usize, 1), vm.trace.registry.cache.items.len);
    const t = vm.trace.registry.cache.items[0];

    // Exactly one synthetic input, resolved from an upvalue, slotted above the anchor.
    try testing.expectEqual(@as(usize, 1), t.code.inputs.len);
    try testing.expectEqual(trace.InputKind.upvalue, t.code.inputs[0].kind);
    try testing.expect(t.code.inputs[0].slot >= vm.trace.rec.anchor_num_registers);

    // The snapshot is read by a `slot_load` on exactly that synthetic slot, and a
    // `guard_func` pins the callee proto.
    var saw_input_load = false;
    var saw_guard_func = false;
    for (t.code.instrs) |ins| {
        if (ins.op == .slot_load and ins.aux == @as(i32, t.code.inputs[0].slot)) saw_input_load = true;
        if (ins.op == .guard_func) saw_guard_func = true;
    }
    try testing.expect(saw_input_load);
    try testing.expect(saw_guard_func);
}

test "recorder(doc53): an open upvalue over the anchor window canonicalizes to the slot — validation seed, no snapshot" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    // `m` is a local of the ANCHOR frame (the chunk), captured by `f` as an
    // OPEN upvalue. Recording the chunk's loop inlines `f`; the `get_upval m`
    // resolves to a cell aliasing the trace-writable window — pre-doc-53 this
    // was a hard `.aliased_input` abort (no trace at all). Now the read
    // canonicalizes to the aliased slot's SSA value: NO `.upvalue` snapshot
    // seed, ONE validation-only `.upvalue_slot_alias` seed, and the read is a
    // plain anchor-window `slot_load`.
    var chunk = try runForTrace(&vm, gpa,
        \\local m = 7
        \\local function f(j) return m + j end
        \\local s = 0
        \\for j = 1, 80 do s = s + f(j) end
        \\print(s)
    , true);
    defer chunk.deinit();

    try testing.expectEqual(@as(usize, 1), vm.trace.registry.cache.items.len);
    const t = vm.trace.registry.cache.items[0];

    try testing.expectEqual(@as(usize, 1), t.code.inputs.len);
    const seed = t.code.inputs[0];
    try testing.expectEqual(trace.InputKind.upvalue_slot_alias, seed.kind);
    // `slot` is the ALIASED anchor-window slot (`m`), not a synthetic one —
    // the inversion of the snapshot tests' `>= anchor_num_registers`.
    try testing.expect(seed.slot < vm.trace.rec.anchor_num_registers);
    // The callee (`f`) is re-resolved from a real anchor slab slot at entry.
    try testing.expect(seed.callee_slot < vm.trace.rec.anchor_num_registers);
    // `source` is f's upvalue index for `m` (its only upvalue).
    try testing.expectEqual(@as(u32, 0), seed.source);

    // The canonicalized read appears as a slot_load of the aliased slot.
    var saw_alias_load = false;
    for (t.code.instrs) |ins| {
        if (ins.op == .slot_load and ins.aux == @as(i32, seed.slot)) saw_alias_load = true;
    }
    try testing.expect(saw_alias_load);
}

test "doc53: canonicalized upvalue read sees the anchor's per-iteration store, not a per-entry snapshot" {
    // The anchor rebinds the captured local EVERY iteration; the inlined
    // callee reads it through the open cell. The cell IS the slot, so the
    // read must see the current iteration's value — a per-entry snapshot
    // (the pre-doc-53 mechanism, had it not aborted) would replay the
    // entry value and diverge. sum(j=1..80 of j) = 3240.
    try expectProgram(
        \\local m = 0
        \\local function f() return m end
        \\local s = 0
        \\for j = 1, 80 do
        \\  m = j
        \\  s = s + f()
        \\end
        \\print(s)
    , "3240\n");
}

test "doc53: a same-proto closure from another live activation declines entry (slot-alias validation)" {
    // Activation 1 of `outer` records the loop trace with `h = inner1`
    // canonicalized against ITS OWN frame (`s` slot). Activation 2 (still
    // holding activation 1 live below it) runs the same loop with h = inner1
    // — a closure that passes `guard_func` (same proto) but whose cell
    // aliases activation 1's frame, NOT the executing anchor frame. The
    // `.upvalue_slot_alias` entry validation must refuse the trace so h()
    // keeps reading activation 1's s (=107): correct total is
    // 80*107 + 80*107 = 17120. An unsound entry instead reads activation 2's
    // own s (=207) in the second loop: 80*107 + 80*207 = 25120.
    try expectProgram(
        \\local function outer(g, depth)
        \\  local s = depth * 100 + 7
        \\  local function inner() return s end
        \\  local h = g or inner
        \\  local acc = 0
        \\  for j = 1, 80 do acc = acc + h() end
        \\  if depth == 1 then
        \\    return acc + outer(inner, 2)
        \\  end
        \\  return acc
        \\end
        \\print(outer(nil, 1))
    , "17120\n");
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

    try testing.expectEqual(@as(usize, 1), vm.trace.registry.cache.items.len);
    const t = vm.trace.registry.cache.items[0];
    try testing.expectEqual(@as(usize, 1), t.code.inputs.len);
    try testing.expectEqual(trace.InputKind.global, t.code.inputs[0].kind);
    try testing.expect(t.code.inputs[0].slot >= vm.trace.rec.anchor_num_registers);

    var saw_guard_func = false;
    for (t.code.instrs) |ins| {
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

    try testing.expectEqual(@as(usize, 0), vm.trace.registry.cache.items.len);
    try testing.expect(vm.trace.record_gate.count() >= 1); // doc 31: aborts gate RECORDING
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

    try testing.expectEqual(@as(usize, 0), vm.trace.registry.cache.items.len);
    try testing.expect(vm.trace.record_gate.count() >= 1); // doc 31: aborts gate RECORDING
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

    try testing.expectEqual(@as(usize, 1), vm.trace.registry.cache.items.len);
    const t = vm.trace.registry.cache.items[0];
    const anchor_window: i32 = @intCast(chunk.proto.num_registers);

    // The inlining actually happened: a guard_func pins the runtime callee identity.
    var saw_guard_func = false;
    for (t.code.instrs) |ins| {
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

    try testing.expectEqual(@as(usize, 1), vm.trace.registry.cache.items.len);
    const t = vm.trace.registry.cache.items[0];
    const anchor_window: i32 = @intCast(chunk.proto.num_registers);
    for (t.code.instrs) |ins| {
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

    try testing.expectEqual(@as(usize, 1), vm.trace.registry.cache.items.len);
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

    try testing.expectEqual(@as(usize, 0), vm.trace.registry.cache.items.len);
    try testing.expect(vm.trace.record_gate.count() >= 1); // doc 31: aborts gate RECORDING
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
    try testing.expectEqual(@as(usize, 1), vm.trace.registry.cache.items.len);
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
    try testing.expectEqual(@as(usize, 1), vm.trace.registry.cache.items.len);
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
    try testing.expectEqual(@as(usize, 1), vm.trace.registry.cache.items.len);
}

test "recorder (hash field, P1): a bool field read records hload ty=.boolean with NO consumer guard" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var chunk = try runForTrace(&vm, gpa,
        \\local t = {b = true}
        \\local n = 0
        \\for i = 1, 50 do if t.b then n = n + 1 end end
        \\print(n)
    , true);
    defer chunk.deinit();

    // Doc 43 P1: the bool field's strict type pin IS the `hload ty=.boolean`
    // fused tag exit — both tiers side-exit at the load on a tag flip — so the
    // recorder must emit NO guard_int/guard_float on the hload ref (there is no
    // numeric guard to give a bool), and the branch's guard_true consumes the
    // bool-proven ref directly.
    try testing.expectEqual(@as(usize, 1), vm.trace.registry.cache.items.len);
    const t = vm.trace.registry.cache.items[0];
    var hload_ref: ?usize = null;
    for (t.code.instrs, 0..) |ins, i| {
        if (ins.op == .hload) {
            try testing.expectEqual(trace.ObsType.boolean, ins.ty);
            hload_ref = i;
        }
    }
    try testing.expect(hload_ref != null);
    var saw_guard_true = false;
    for (t.code.instrs) |ins| {
        if ((ins.op == .guard_int or ins.op == .guard_float or ins.op == .guard_number) and
            ins.a == @as(trace.Ref, @intCast(hload_ref.?))) return error.TestUnexpectedResult;
        if (ins.op == .guard_true and ins.a == @as(trace.Ref, @intCast(hload_ref.?))) saw_guard_true = true;
    }
    try testing.expect(saw_guard_true);
}

test "recorder (hash field, P1): a konst-bool field store records an hstore (no value guard)" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var chunk = try runForTrace(&vm, gpa,
        \\local t = {b = false}
        \\for i = 1, 50 do t.b = true end
        \\print(t.b)
    , true);
    defer chunk.deinit();

    // A konst bool is statically bool-proven, so the store is admitted with no
    // runtime value guard (`guardNum` has no bool arm; the pin is the konst).
    // A pure write (no prior heap load) emits the hstore inline, as for scalars.
    var buf: [8192]u8 = undefined;
    const text = try dumpTrace(&buf, &vm);
    try testing.expect(std.mem.indexOf(u8, text, "hstore") != null);
    try testing.expectEqual(@as(usize, 1), vm.trace.registry.cache.items.len);
}

test "recorder (hash field, P1): a bool-proven copy (dst.f = src.g) records; hload feeds hstore" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var chunk = try runForTrace(&vm, gpa,
        \\local src = {g = true}
        \\local dst = {f = false}
        \\for i = 1, 50 do dst.f = src.g end
        \\print(dst.f)
    , true);
    defer chunk.deinit();

    // The store value ref is the `hload ty=.boolean` of `src.g` — statically
    // bool-proven (a tag flip on src.g side-exits at ITS load, upstream of the
    // store), so the store is admitted. The store follows a heap load, so C1
    // sinks it: hload strictly before hstore in the stream.
    var buf: [8192]u8 = undefined;
    const text = try dumpTrace(&buf, &vm);
    const i_load = std.mem.indexOf(u8, text, "hload");
    const i_store = std.mem.indexOf(u8, text, "hstore");
    try testing.expect(i_load != null);
    try testing.expect(i_store != null);
    try testing.expect(i_load.? < i_store.?);
    try testing.expectEqual(@as(usize, 1), vm.trace.registry.cache.items.len);
}

test "recorder (hash field, P1 + doc 57): a plain-local bool store is pinned, then stored as a konst" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    // `x` reaches the store as a `slot_load` ref. Before doc 57 nothing proved it
    // stayed a bool, so the recorder aborted fail-closed (a later iteration could
    // deliver a heap value into the cell). Doc 57 pins it: a `guard_is_true` on
    // the input, and the store writes the konst `true`. A later non-`true` value
    // fails the pin and exits, so the drifting-store hole stays shut.
    var chunk = try runForTrace(&vm, gpa,
        \\local t = {b = false}
        \\local x = true
        \\for i = 1, 50 do t.b = x end
        \\print(t.b)
    , true);
    defer chunk.deinit();

    var buf: [8192]u8 = undefined;
    const text = try dumpTrace(&buf, &vm);
    try testing.expect(std.mem.indexOf(u8, text, "guard_is_true") != null);
    try testing.expect(std.mem.indexOf(u8, text, "hstore") != null);
    try testing.expectEqual(@as(usize, 1), vm.trace.registry.cache.items.len);
    try testing.expect(!vm.trace.isRecording());
}

test "recorder (hash field, P1): a comparison-result store (t.b = i < k) records (ty=.boolean producer)" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var chunk = try runForTrace(&vm, gpa,
        \\local t = {b = false}
        \\for i = 1, 50 do t.b = i < 25 end
        \\print(t.b)
    , true);
    defer chunk.deinit();

    // A comparison always produces a bool (`lt` carries `.ty = .boolean`), so the
    // ref is statically bool-proven and the store is admitted.
    var buf: [8192]u8 = undefined;
    const text = try dumpTrace(&buf, &vm);
    try testing.expect(std.mem.indexOf(u8, text, "hstore") != null);
    try testing.expectEqual(@as(usize, 1), vm.trace.registry.cache.items.len);
}

test "recorder (hash field, P2): a function field records hload ty=.heap + guard_func on the load" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var chunk = try runForTrace(&vm, gpa,
        \\local function getx(p) return p.x end
        \\local obj = { x = 3, getx = getx }
        \\local s = 0
        \\for i = 1, 50 do s = s + obj.getx(obj) end
        \\print(s)
    , true);
    defer chunk.deinit();

    // Doc 43 P2: the function field loads as `hload ty=.heap` and is pinned by
    // `guard_func(rload, aux=Proto.id)` right at the load; `recCall` re-emits
    // the same guard at the call site. This harness records UNOPTIMIZED IR, so
    // both appear here (identical (op, a, aux) — tropt's aux-keyed CSE folds
    // them to one on the optimized/native path, verified by the e2e legs). The
    // callee body then inlines (its `p.x` hload appears in the same trace).
    try testing.expectEqual(@as(usize, 1), vm.trace.registry.cache.items.len);
    const t = vm.trace.registry.cache.items[0];
    var heap_hload_ref: ?usize = null;
    var n_hload: usize = 0;
    for (t.code.instrs, 0..) |ins, i| {
        if (ins.op == .hload) {
            n_hload += 1;
            if (ins.ty == .heap) heap_hload_ref = i;
        }
    }
    try testing.expect(heap_hload_ref != null);
    try testing.expect(n_hload >= 2); // the function field AND the inlined body's p.x
    var n_guard_func_on_load: usize = 0;
    for (t.code.instrs) |ins| {
        if (ins.op == .guard_func and ins.a == @as(trace.Ref, @intCast(heap_hload_ref.?)))
            n_guard_func_on_load += 1;
    }
    try testing.expectEqual(@as(usize, 2), n_guard_func_on_load);
}

test "recorder (hash field, P2): an hload-loaded callee reading its OWN UPVALUE aborts (hard invariant)" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    // Doc 43 §5 HARD INVARIANT: guard_func pins the PROTO id, not closure
    // identity — sound ONLY because an inlined callee's upvalue read requires a
    // `slot_load` callee ref (`recCalleeUpval`) and an `hload` ref is not one.
    // Two closures over one proto with different cells would otherwise alias
    // under the instance-blind guard (a P0-class miscompile). This test pins
    // the abort; if it ever starts tracing, guard_func must FIRST tighten to
    // closure `GcHeader.id`.
    var chunk = try runForTrace(&vm, gpa,
        \\local function mk(n)
        \\  return function() return n end
        \\end
        \\local obj = { g = mk(10) }
        \\local s = 0
        \\for i = 1, 50 do s = s + obj.g() end
        \\print(s)
    , true);
    defer chunk.deinit();

    try testing.expectEqual(@as(usize, 0), vm.trace.registry.cache.items.len);
    try testing.expect(vm.trace.record_gate.count() >= 1);
    try testing.expect(!vm.trace.isRecording());
}

test "hash field P2 end-to-end: function-field call inlines; all ten legs" {
    try expectProgram(
        \\local function getx(p) return p.x end
        \\local obj = { x = 3, getx = getx }
        \\local s = 0
        \\for i = 1, 200 do s = s + obj.getx(obj) end
        \\print(s)
    , "600\n");
}

test "hash field P2 end-to-end: colon method with float self-field RMW; all ten legs" {
    // The real OOP shape (nbody-like): `o:advance(dt)` loads the method field,
    // inlines the body, and the body does a float hash-field RMW through self.
    // Float accumulation must stay byte-identical on every leg.
    try expectProgram(
        \\local obj = { x = 0.0, vx = 1.5 }
        \\function obj.advance(self, dt) self.x = self.x + dt * self.vx end
        \\local o = obj
        \\for i = 1, 200 do o:advance(0.01) end
        \\print(o.x)
    , "3.0000000000000027\n");
}

test "hash field P2 end-to-end: mid-loop method swap (different proto) side-exits exactly" {
    try expectProgram(
        \\local function m1(p) return 1 end
        \\local function m2(p) return 1000 end
        \\local obj = { m = m1 }
        \\local s = 0
        \\for i = 1, 200 do
        \\  if i == 100 then obj.m = m2 end
        \\  s = s + obj.m(obj)
        \\end
        \\print(s)
    , "101099\n");
}

test "hash field P2 end-to-end: closure swap SAME proto different cells stays exact (invariant shape)" {
    // The alias shape the hard invariant defends: obj.g flips between two
    // closures of ONE proto with different upvalue cells. Recording aborts
    // (`.cross_frame` at the callee's get_upval), so every tier runs tier-0
    // semantics — and must agree.
    try expectProgram(
        \\local function mk(n)
        \\  return function() return n end
        \\end
        \\local f10 = mk(10)
        \\local f99 = mk(99)
        \\local obj = { g = f10 }
        \\local s = 0
        \\for i = 1, 200 do
        \\  if i == 100 then obj.g = f99 end
        \\  s = s + obj.g()
        \\end
        \\print(s)
    , "10989\n");
}

test "recorder (hash field, P3): a table field records hload ty=.heap + guard_table on the load; aref roots at it" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var chunk = try runForTrace(&vm, gpa,
        \\local obj = { image = {} }
        \\for i = 1, 8 do obj.image[i] = 0 end
        \\local s = 0
        \\for i = 1, 50 do
        \\  local image = obj.image
        \\  image[3] = image[3] + 1
        \\  s = s + image[3]
        \\end
        \\print(s)
    , true);
    defer chunk.deinit();

    // Doc 43 P3: the table field loads as `hload ty=.heap`; its pin is
    // `guard_table(rload)` (type + metatable-free, per-iteration in native) —
    // the `.value`-lane element-table precedent — plus the `guard_lane` the
    // array access adds. The subsequent array ops root their aref AT THE HLOAD
    // REF (a dynamic root), not at a slot_load. (Since P4 narrowed the append
    // C1 bar to array reads, the INIT fill loop also records — search every
    // committed trace for the shape rather than pinning a count of one.)
    try testing.expect(vm.trace.registry.cache.items.len >= 1);
    var saw_shape = false;
    for (vm.trace.registry.cache.items) |t| {
        var heap_hload_ref: ?usize = null;
        for (t.code.instrs, 0..) |ins, i| {
            if (ins.op == .hload and ins.ty == .heap) heap_hload_ref = i;
        }
        if (heap_hload_ref == null) continue;
        const hr: trace.Ref = @intCast(heap_hload_ref.?);
        var saw_guard_table = false;
        var saw_dyn_aref = false;
        for (t.code.instrs) |ins| {
            if (ins.op == .guard_table and ins.a == hr) saw_guard_table = true;
            if (ins.op == .aref and ins.a == hr) saw_dyn_aref = true;
        }
        if (saw_guard_table and saw_dyn_aref) saw_shape = true;
    }
    try testing.expect(saw_shape);
}

test "recorder (hash field, P3): a table field WITH a metatable aborts fail-closed" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    // The record-time gate mirrors arrayGetShape's element-table rule: a
    // metatable on the field table means index misses dispatch to __index,
    // which the traced fast path cannot replay — refuse at the load.
    var chunk = try runForTrace(&vm, gpa,
        \\local obj = { image = setmetatable({}, {}) }
        \\for i = 1, 8 do obj.image[i] = 0 end
        \\local s = 0
        \\for i = 1, 50 do
        \\  local image = obj.image
        \\  s = s + image[3]
        \\end
        \\print(s)
    , true);
    defer chunk.deinit();

    try testing.expectEqual(@as(usize, 0), vm.trace.registry.cache.items.len);
    try testing.expect(vm.trace.record_gate.count() >= 1); // doc 31: aborts gate RECORDING
    try testing.expect(!vm.trace.isRecording());
}

test "hash field P3 end-to-end: table field loaded INSIDE the loop, array RMW through it; all ten legs" {
    // The array3d shape: `local image = obj.image` inside the loop body makes
    // every array op root at the hload (a dynamic `.heap` root). Native lowers
    // per-iteration guard_table/guard_lane checks and reaches data/present/asize
    // through the root each iteration (arrayFieldReg's fallback) — and the
    // liveness extension keeps the root register alive through the LAST
    // reach-through consumer (the segfault this arc fixed).
    try expectProgram(
        \\local obj = { image = {} }
        \\local img = obj.image
        \\for i = 1, 8 do img[i] = 0 end
        \\local total = 0
        \\for round = 1, 50 do
        \\  for i = 1, 8 do
        \\    local image = obj.image
        \\    image[i] = image[i] + 1
        \\  end
        \\  total = total + obj.image[4]
        \\end
        \\print(total, obj.image[1], obj.image[8])
    , "1275\t50\t50\n");
}

test "hash field P3 end-to-end: mid-loop field table SWAP redirects writes exactly" {
    // guard_hash/hload re-resolve the CURRENT field value each iteration, so
    // swapping obj.image mid-run must redirect every subsequent write to the
    // new table with no leakage into the old one — on every leg.
    try expectProgram(
        \\local a, b = {}, {}
        \\for i = 1, 8 do a[i] = 0; b[i] = 100 end
        \\local obj = { image = a }
        \\for round = 1, 60 do
        \\  if round == 31 then obj.image = b end
        \\  for i = 1, 8 do
        \\    local image = obj.image
        \\    image[i] = image[i] + 1
        \\  end
        \\end
        \\print(a[1], b[1], a[8], b[8])
    , "30\t130\t30\t130\n");
}

test "hash field P3 end-to-end: metatable ADDED to the field table mid-run side-exits (dynamic guard_table)" {
    // The per-iteration guard_table checks type AND metatable == null against
    // the CURRENT table; setmetatable mid-run must side-exit, and the __index
    // miss after the loop must dispatch through the metatable on every leg.
    try expectProgram(
        \\local obj = { image = {} }
        \\for i = 1, 8 do obj.image[i] = 0 end
        \\for round = 1, 60 do
        \\  if round == 41 then setmetatable(obj.image, { __index = function() return -1 end }) end
        \\  for i = 1, 8 do
        \\    local image = obj.image
        \\    image[i] = image[i] + 1
        \\  end
        \\end
        \\print(obj.image[1], obj.image[8], obj.image[99])
    , "60\t60\t-1\n");
}

test "hash field P3 end-to-end: lane drift on the field table side-exits (dynamic guard_lane)" {
    // A float landing in the int-lane array rewrites the lane; the dynamic
    // guard_lane compares the lane byte per iteration and must catch it.
    try expectProgram(
        \\local obj = { image = {} }
        \\for i = 1, 8 do obj.image[i] = 0 end
        \\for round = 1, 60 do
        \\  if round == 31 then obj.image[1] = 0.5 end
        \\  for i = 2, 8 do
        \\    local image = obj.image
        \\    image[i] = image[i] + 1
        \\  end
        \\end
        \\print(obj.image[1], obj.image[2], obj.image[8])
    , "0.5\t60\t60\n");
}

test "hash field P3 end-to-end: cross-root aliasing — dynamic-root store visible to .ptr-root load, same iteration" {
    // The SAME table reached through an invariant `.ptr` slot root (t) AND the
    // dynamic hload root (obj.image) in one body: a store through one must be
    // visible to a load through the other with no stale hoisted state.
    try expectProgram(
        \\local t = {}
        \\for i = 1, 8 do t[i] = 0 end
        \\local obj = { image = t }
        \\local total = 0
        \\for round = 1, 50 do
        \\  for i = 1, 8 do
        \\    local image = obj.image
        \\    image[i] = image[i] + 1
        \\    total = total + t[i]
        \\  end
        \\end
        \\print(total, t[1], t[8])
    , "10200\t50\t50\n");
}

test "recorder (assert, P4): statement-form assert records guard_builtin + guard_true, copies nothing" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var chunk = try runForTrace(&vm, gpa,
        \\local s = 0
        \\for i = 1, 50 do
        \\  assert(i < 100, "range")
        \\  s = s + 1
        \\end
        \\print(s)
    , true);
    defer chunk.deinit();

    // Doc 43 P4: assert dispatches through recBuiltin — the callee pins with
    // guard_builtin[assert]; the truthiness pin for the observed-bool argument
    // (a comparison result, ty=.boolean) is one guard_true on its ref. The
    // statement form (c == 0) copies no results. The message konst is
    // evaluated but never guarded.
    try testing.expectEqual(@as(usize, 1), vm.trace.registry.cache.items.len);
    const t = vm.trace.registry.cache.items[0];
    var saw_builtin = false;
    var lt_ref: ?usize = null;
    for (t.code.instrs, 0..) |ins, i| {
        if (ins.op == .guard_builtin and ins.aux == @intFromEnum(function.RecordedBuiltin.assert)) saw_builtin = true;
        if (ins.op == .lt) lt_ref = i;
    }
    try testing.expect(saw_builtin);
    try testing.expect(lt_ref != null);
    var saw_guard_true = false;
    for (t.code.instrs) |ins| {
        if (ins.op == .guard_true and ins.a == @as(trace.Ref, @intCast(lt_ref.?))) saw_guard_true = true;
    }
    try testing.expect(saw_guard_true);
}

test "recorder (assert, P4): assert inside an INLINED callee records via the callee_global seed" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var chunk = try runForTrace(&vm, gpa,
        \\local function chk(self, i)
        \\  assert(i >= 1, "low")
        \\  return i + self.k
        \\end
        \\local obj = { k = 2, chk = chk }
        \\local s = 0
        \\for i = 1, 50 do s = s + obj.chk(obj, i) end
        \\print(s)
    , true);
    defer chunk.deinit();

    // The global `assert` is read INSIDE the inlined callee — its bytecode
    // const-pool index refers to the callee's proto, so the seed carries the
    // key VALUE in the trace's own const pool: kind `.callee_global` with
    // `ct.consts[source]` == the interned "assert" string (proto-free entry
    // resolution, the hash_cell precedent).
    try testing.expectEqual(@as(usize, 1), vm.trace.registry.cache.items.len);
    const t = vm.trace.registry.cache.items[0];
    var saw_cg = false;
    for (t.code.inputs) |seed| {
        if (seed.kind != .callee_global) continue;
        const key = t.code.consts[seed.source];
        try testing.expect(key.isHeap() and key.heapType() == .string);
        saw_cg = true;
    }
    try testing.expect(saw_cg);
}

test "assert P4 end-to-end: statement + result + number-pin forms; all ten legs" {
    try expectProgram(
        \\local s = 0
        \\for i = 1, 60 do
        \\  assert(i >= 1 and i <= 60, "range")
        \\  s = s + i
        \\end
        \\local a, b = assert(41, "msg")
        \\local t = { v = 3 }
        \\local u = { w = 0.5 }
        \\local n = 0
        \\for i = 1, 60 do
        \\  n = n + assert(t.v)
        \\  n = n + assert(u.w)
        \\end
        \\print(s, a, b, n)
    , "1830\t41\tmsg\t210\n");
}

test "assert P4 end-to-end: assert inside an inlined method (the array3d shape); all ten legs" {
    try expectProgram(
        \\local function set(self, i, p)
        \\  assert(i >= 1 and i <= 8, "out of range")
        \\  local image = self.image
        \\  image[i] = p
        \\  self.changed = true
        \\end
        \\local obj = { image = {}, changed = false, set = set }
        \\for i = 1, 8 do obj.image[i] = 0 end
        \\for round = 1, 60 do
        \\  for i = 1, 8 do
        \\    obj.set(obj, i, i + round)
        \\  end
        \\end
        \\print(obj.image[1], obj.image[8], obj.changed)
    , "61\t68\ttrue\n");
}

test "assert P4 end-to-end: mid-loop falsy drift side-exits and raises identically (pcall)" {
    // The bool-field argument flips false mid-loop: the guard_true (or the
    // hload's fused tag path) must side-exit, and tier-0 must raise the
    // recorded-but-unguarded message on every leg.
    try expectProgram(
        \\local flag = { ok = true }
        \\local s = 0
        \\local function body()
        \\  for i = 1, 60 do
        \\    if i == 50 then flag.ok = false end
        \\    assert(flag.ok, "flipped")
        \\    s = s + 1
        \\  end
        \\end
        \\local ok, err = pcall(body)
        \\print(ok, err, s)
    , "false\tflipped\t49\n");
}

test "doc 43 end-to-end: mini-array3d — iterator closure + method with assert + fields + append fill; all ten legs" {
    // The full cascade in one loop: generic-for over a closure iterator
    // (callee-upvalue reads incl. the pure PASS-THROUGH `y` the typed-SLOAD
    // pin exists for), an hload'd method callee, asserts via callee_global
    // seeds, a bool field branch, a table-field dynamic-root APPEND fill
    // (hloads preceding an append — the narrowed C1 bar), and sunk bool
    // hstores. The real array3d tiers up through exactly this shape.
    try expectProgram(
        \\local function aset(self, x, y, p)
        \\  assert(x >= 0 and x < self.nx, "x out")
        \\  assert(y >= 0 and y < self.ny, "y out")
        \\  local pos = y * self.nx + x
        \\  local image = self.image
        \\  if self.packed then
        \\    image[pos] = p * 2
        \\  else
        \\    image[pos] = p
        \\  end
        \\  self.changed = true
        \\end
        \\local function points(self)
        \\  local y = 0
        \\  return function(s2, x)
        \\    x = x + 1
        \\    if x >= s2.nx then
        \\      x = 0
        \\      y = y + 1
        \\      if y >= s2.ny then return nil, nil end
        \\    end
        \\    return x, y
        \\  end, self, -1
        \\end
        \\local arr = { nx = 12, ny = 12, packed = false, changed = false, image = {}, set = aset, points = points }
        \\for x, y in arr:points() do
        \\  arr:set(x, y, x * x)
        \\end
        \\local sum = 0
        \\for i = 0, arr.nx * arr.ny - 1 do sum = sum + arr.image[i] end
        \\print(sum, arr.changed)
    , "6072\ttrue\n");
}

test "hash field P1 end-to-end: bool field branch + konst store + proven copy, all ten legs" {
    // The full P1 shape from one loop: hload ty=.boolean feeding guard_true,
    // a comparison-result store, and a bool-proven cross-table copy. Byte-
    // identical across the ten-leg matrix (incl. native, where the hload tag
    // check and TAG_BOOL hstore arms carry the type discipline).
    try expectProgram(
        \\local obj = { packed = true, on = false }
        \\local src = { flag = true }
        \\local s = 0
        \\for i = 1, 200 do
        \\  if obj.packed then s = s + 2 else s = s + 1 end
        \\  obj.on = src.flag
        \\  obj.packed = (i < 150)
        \\end
        \\print(s, obj.packed, obj.on)
    , "350\tfalse\ttrue\n");
}

test "hash field P1 end-to-end: bool field type drift (bool->int->bool) side-exits and stays exact" {
    // Mid-loop the field turns int (the hload's fused tag exit must fire — it is
    // the bool field's ONLY pin) and later back to bool. Every tier must agree.
    try expectProgram(
        \\local obj = { flag = true }
        \\local s = 0
        \\for i = 1, 200 do
        \\  if obj.flag then s = s + 1 else s = s + 100 end
        \\  if i == 100 then obj.flag = 7 end
        \\  if i == 110 then obj.flag = false end
        \\end
        \\print(s, obj.flag)
    , "9110\tfalse\n");
}

test "hash field P1 end-to-end: C1 forwards a pending bool hstore to a same-iteration load" {
    // `o.f = v` sinks (a heap load precedes it); the immediately following
    // `if o.f` must forward the pending BOOL value ref (`forwardPendingHashLoad`
    // is type-agnostic — doc 43 P1 pins that with this test).
    try expectProgram(
        \\local o = { f = true, g = true }
        \\local s = 0
        \\for i = 1, 200 do
        \\  local v = o.g
        \\  o.f = v
        \\  if o.f then s = s + 1 end
        \\end
        \\print(s)
    , "200\n");
}

test "recorder (hash field): an absent constant-key access records a guarded nil" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    // Metatable-free absence is a guarded load, not an unconditional nil.
    var chunk = try runForTrace(&vm, gpa,
        \\local t = {x = 1}
        \\local c = 0
        \\for i = 1, 50 do if t.y then c = c + 1 end end
        \\print(c)
    , true);
    defer chunk.deinit();

    try testing.expect(vm.trace.registry.cache.items.len > 0);
    var witnessed = false;
    for (vm.trace.registry.cache.items) |ct| {
        for (ct.code.instrs) |ins| if (ins.op == .guard_absent) {
            witnessed = true;
        };
    }
    try testing.expect(witnessed);
    try testing.expect(!vm.trace.isRecording());
}

test "hash field (doc 45): a store after an absent read defers below the guard" {
    // C1 discipline for the absence slice: `guard_absent` counts as a heap
    // read, so the same-iteration present-cell store `t.x = i` must sink
    // BELOW it — an entry replay after a guard failure must re-run the read
    // against the unmutated heap and take the same branch (doc 45 D7: "a
    // following write cannot change which branch entry replay would take").
    // (A store to the absent key itself is unrecordable today — hash
    // insertion aborts — so the different-key deferral is the recordable
    // interplay; general tset ordering arrives with table construction.)
    try expectProgram(
        \\local t = { x = 1 }
        \\local c = 0
        \\for i = 1, 200 do
        \\  if t.y == nil then c = c + 1 end
        \\  t.x = i
        \\end
        \\print(c .. " " .. t.x)
    , "200 200\n");
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

    try testing.expectEqual(@as(usize, 0), vm.trace.registry.cache.items.len);
    try testing.expect(vm.trace.record_gate.count() >= 1); // doc 31: aborts gate RECORDING
    try testing.expect(!vm.trace.isRecording());
}

test "recorder (hash field): a heap-valued (string) field aborts (no string-field pin yet)" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    // The field value is a string (heap). int/float/bool fields trace (doc 43
    // P1), function fields pin via guard_func (P2), table fields via
    // guard_table (P3) — STRING fields have no pin yet and abort to tier-0.
    var chunk = try runForTrace(&vm, gpa,
        \\local t = {x = "hi"}
        \\local n = 0
        \\for i = 1, 50 do if t.x then n = n + 1 end end
        \\print(n)
    , true);
    defer chunk.deinit();

    try testing.expectEqual(@as(usize, 0), vm.trace.registry.cache.items.len);
    try testing.expect(vm.trace.record_gate.count() >= 1); // doc 31: aborts gate RECORDING
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

    try testing.expectEqual(@as(usize, 0), vm.trace.registry.cache.items.len);
    try testing.expect(vm.trace.record_gate.count() >= 1); // doc 31: aborts gate RECORDING
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
    try testing.expectEqual(@as(usize, 1), vm.trace.registry.cache.items.len);
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
    try testing.expectEqual(@as(usize, 1), vm.trace.registry.cache.items.len);
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

    try testing.expectEqual(@as(usize, 1), vm.trace.registry.cache.items.len);
    const t = vm.trace.registry.cache.items[0];
    var n_hstore: usize = 0;
    for (t.code.instrs, 0..) |ins, i| {
        if (ins.op != .hstore) continue;
        n_hstore += 1;
        var pinned = false;
        for (t.code.instrs[0..i]) |prior| {
            if ((prior.op == .guard_int or prior.op == .guard_float) and prior.a == ins.b) {
                pinned = true;
                break;
            }
        }
        try testing.expect(pinned);
    }
    try testing.expect(n_hstore >= 1); // the loop above must have checked something
}

test "recorder (hash alias): same key through two table refs emits runtime ne guard (table identity)" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    // `t` and `u` hold the SAME table at runtime, but they are different slots, so
    // the recorder materializes two distinct slot_load refs — it cannot prove they
    // alias (MUST) or don't (NO). The forwarding pass emits a runtime `ne` guard
    // on the table pointer identity: if they collide at runtime, side-exit.
    // Since `t` and `u` ARE the same table, the ne guard side-exits every iteration,
    // making the trace effectively dead (always side-exits), but it still records.
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

    // The trace now commits (with ne guard on table identity) instead of aborting.
    // Verify correctness: at runtime the ne guard side-exits every iteration
    // (t == u), so tier-0 handles the actual computation — but the recording
    // succeeds. Verify correct output across all tiers.
    try expectProgram(
        \\local t = {x = 0}
        \\local u = t
        \\local s = 0
        \\for i = 1, 50 do
        \\  t.x = t.x + 1
        \\  s = s + u.x
        \\end
        \\print(s)
    , "1275\n");
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
    try testing.expectEqual(@as(usize, 1), vm.trace.registry.cache.items.len);
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

test "doc 30 c5: the pattern/str2num loop runs NATIVELY end-to-end — find/match x2/tonumber + gmatch for-in, record/replay parity" {
    // The arc's flagship: the four recorded shapes in bench form (hoisted
    // builtins, TWO match calls in one body — interleaved projections against
    // different subjects — and tonumber over a match projection), plus the
    // composite gmatch for-in, through the full pipeline (record → tropt →
    // native) under effect RECORDING. Proves (a) byte parity with tier-0,
    // (b) native really entered, (c) the committed traces carry the doc 30
    // ops (sfindp, two smatch in ONE trace, str2num_i, and the sgmatch/
    // sgm_setpos composite with its guard_table state pin), (d) pattern
    // callouts log NO effects (pure by construction), and (e) a replay-mode
    // rerun re-records from scratch and reproduces the output byte-identically.
    const gpa = testing.allocator;
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    const source =
        \\local find, match, gmatch = string.find, string.match, string.gmatch
        \\local text = "key=value; name=mahina; year=2026; lang=zig"
        \\local acc = 0
        \\for i = 1, 100 do
        \\  local s, e = find(text, "year", 1, true)
        \\  acc = acc + s + e
        \\  local k, v = match(text, "(%w+)=(%w+)")
        \\  acc = acc + #k + #v
        \\  local d = match("item-00420-x", "%d+")
        \\  acc = acc + tonumber(d)
        \\end
        \\for w in gmatch(text, "%a+") do
        \\  acc = acc + #w
        \\end
        \\print(acc)
    ;
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();

    var t0_out: [64]u8 = undefined;
    var t0_len: usize = 0;
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
        try testing.expect(t0_len > 0);
    }

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    vm.trace.config.enabled = true;
    vm.trace.config.execute = true;
    vm.trace.config.optimize = true;
    vm.trace.config.native_codegen = @import("nativegen.zig").is_x64_linux;
    vm.trace.config.hotloop = 4;
    vm.effect_mode = .record;
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;
    var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    _ = try vm.run(chunk.proto);
    try testing.expectEqualStrings(t0_out[0..t0_len], sink.buffered());
    try testing.expect(vm.trace.entries > 0);
    if (@import("nativegen.zig").is_x64_linux)
        try testing.expect(vm.trace.native_entries > 0);
    // Pattern callouts are PURE: nothing may enter the effect log.
    try testing.expectEqual(@as(usize, 0), vm.effect_log.items.len);

    // Structural: one committed trace carries the numeric-for body's ops —
    // sfindp (plain find, konst-folded end index), TWO smatch (interleaved
    // projections, different subjects), scap_str captures, and str2num_i
    // (tonumber over the %d+ projection). A separate trace carries the
    // gmatch composite: sgmatch + deferred sgm_setpos + scap_str.
    var found_body = false;
    var found_gm = false;
    for (vm.trace.registry.cache.items) |t| {
        var n_smatch: usize = 0;
        var has_sfindp = false;
        var has_str2num = false;
        var has_scap_str = false;
        var has_sgmatch = false;
        var has_setpos = false;
        for (t.code.instrs) |ins| switch (ins.op) {
            .smatch => n_smatch += 1,
            .sfindp => has_sfindp = true,
            .str2num_i => has_str2num = true,
            .scap_str => has_scap_str = true,
            .sgmatch => has_sgmatch = true,
            .sgm_setpos => has_setpos = true,
            else => {},
        };
        if (has_sfindp and n_smatch == 2 and has_str2num and has_scap_str) found_body = true;
        if (has_sgmatch and has_setpos and has_scap_str) found_gm = true;
    }
    try testing.expect(found_body);
    try testing.expect(found_gm);

    // Replay leg: mode flip, cursor reset — traces re-record during replay,
    // output byte-identical, the log stays empty (nothing to consume: the
    // whole program is deterministic pure compute).
    vm.effect_mode = .replay;
    vm.effect_cursor = 0;
    var rep_buf: [64]u8 = undefined;
    var rep_sink = io.Writer.fixed(&rep_buf);
    vm.out = &rep_sink;
    _ = try vm.run(chunk.proto);
    try testing.expectEqualStrings(t0_out[0..t0_len], rep_sink.buffered());
    try testing.expectEqual(@as(usize, 0), vm.effect_log.items.len);
}

test "doc 30 c5: guard_sid identity pin — a pattern rebound between loop runs side-exits and re-records with the new census" {
    // §9 identity-guard shape: the pattern reaches the loop as a non-konst
    // local (a function parameter), so the arm pins it by IDENTITY
    // (guard_string + guard_sid vs the konst pool). A second run of the same
    // loop with a DIFFERENT pattern must fail the pin — never reuse the old
    // census — and produce tier-0-identical output; the machinery then
    // re-records against the new pattern.
    const gpa = testing.allocator;
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    const source =
        \\local match = string.match
        \\local text = "abc 12345 def"
        \\local function scan(pat)
        \\  local acc = 0
        \\  for i = 1, 50 do
        \\    local m = match(text, pat)
        \\    acc = acc + #m
        \\  end
        \\  return acc
        \\end
        \\print(scan("%a+") + scan("%d+") + scan("%a+ %d+"))
    ;
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();

    var t0_out: [64]u8 = undefined;
    var t0_len: usize = 0;
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
        try testing.expect(t0_len > 0);
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
    try testing.expect(vm.trace.entries > 0);

    // The identity pin must be present in a committed trace, and its aux is
    // a konst-pool id whose const IS the pinned pattern string.
    var found_sid = false;
    for (vm.trace.registry.cache.items) |t| {
        for (t.code.instrs) |ins| {
            if (ins.op != .guard_sid) continue;
            found_sid = true;
            try testing.expect(ins.aux >= 0 and ins.aux < t.code.consts.len);
            const kv = t.code.consts[@intCast(ins.aux)];
            try testing.expect(kv.isHeap() and kv.heapType() == .string);
        }
    }
    try testing.expect(found_sid);
}

// ---------------------------------------------------------------------------
// Doc 43 P5: closed-cell upvalue stores (uref / uload / ustore, scalar v1).
// ---------------------------------------------------------------------------

test "recorder (upvalue cell, P5): a write-only closed-cell store records uref+ustore on the FIRST attempt" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    // `last = i` never READS the cell inside the loop, so no snapshot seed
    // exists for it and the store is admitted on the very first recording —
    // no `.upvalue_mutable` memo round-trip. The factory shape matters: the
    // cell must be CLOSED (make() returned) or recSetUpval declines.
    var chunk = try runForTrace(&vm, gpa,
        \\local function make()
        \\  local last = 0
        \\  return function(n)
        \\    for i = 1, n do last = i end
        \\    return last
        \\  end
        \\end
        \\local f = make()
        \\print(f(50))
    , true);
    defer chunk.deinit();

    try testing.expectEqual(@as(usize, 1), vm.trace.registry.cache.items.len);
    try testing.expectEqual(@as(u32, 0), vm.trace.record_gate.count());
    const t = vm.trace.registry.cache.items[0];
    var n_uref: usize = 0;
    var saw_ustore = false;
    for (t.code.instrs) |ins| {
        if (ins.op == .uref) n_uref += 1;
        if (ins.op == .ustore) saw_ustore = true;
        try testing.expect(ins.op != .uload); // pure write: no routed read
    }
    try testing.expectEqual(@as(usize, 1), n_uref); // one alias class → one uref
    try testing.expect(saw_ustore);
    // Exactly one upvalue_cell seed, and it is the WRITER (not a verifier).
    var n_cell_seeds: usize = 0;
    for (t.code.inputs) |seed| {
        if (seed.kind == .upvalue_cell) {
            n_cell_seeds += 1;
            try testing.expect(!seed.verify);
        }
    }
    try testing.expectEqual(@as(usize, 1), n_cell_seeds);
}

test "recorder (upvalue cell, P5): an RMW (c = c + 1) aborts once with the memo, then the retry records uref+uload+ustore" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    // First attempt: the read routes to a snapshot seed (registering the cell in
    // `snapshot_read_cells`), so the store aborts `.upvalue_mutable` and memos the
    // anchor. The record gate's first window is backoff_base (128 ticks), so 400
    // iterations guarantee a retry — which routes the read through uload from the
    // start and commits.
    var chunk = try runForTrace(&vm, gpa,
        \\local function make()
        \\  local count = 0
        \\  return function(n)
        \\    for i = 1, n do count = count + 1 end
        \\    return count
        \\  end
        \\end
        \\local f = make()
        \\print(f(400))
    , true);
    defer chunk.deinit();

    try testing.expectEqual(@as(usize, 1), vm.trace.registry.cache.items.len);
    try testing.expect(vm.trace.record_gate.count() >= 1); // the memoized first abort struck the gate
    const t = vm.trace.registry.cache.items[0];
    var n_uref: usize = 0;
    var saw_uload = false;
    var saw_ustore = false;
    for (t.code.instrs) |ins| {
        if (ins.op == .uref) n_uref += 1;
        if (ins.op == .uload) saw_uload = true;
        if (ins.op == .ustore) saw_ustore = true;
    }
    try testing.expectEqual(@as(usize, 1), n_uref);
    try testing.expect(saw_uload);
    try testing.expect(saw_ustore);
}

test "recorder (upvalue cell, P5): two access paths to ONE cell share the uref and add a VERIFIER seed" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    // `setter` (inlined callee) and the anchor closure both close over the same
    // `x`. The retry records the first path as the class WRITER; the second path
    // resolves the same cell → same uref, plus a verify=true seed that re-proves
    // the record-time aliasing at every future entry (the s1-into-f2 trap).
    // 400 `setter` calls would also head-trace its body (doc 44); park hot-call
    // counting — this test pins the LOOP anchor's cache shape.
    vm.trace.config.hotcall = std.math.maxInt(u32);
    var chunk = try runForTrace(&vm, gpa,
        \\local function make()
        \\  local x = 0
        \\  local setter = function(d) x = x + d end
        \\  local f = function(n)
        \\    for i = 1, n do setter(2); x = x + 1 end
        \\    return x
        \\  end
        \\  return f
        \\end
        \\local f = make()
        \\print(f(400))
    , true);
    defer chunk.deinit();

    try testing.expectEqual(@as(usize, 1), vm.trace.registry.cache.items.len);
    const t = vm.trace.registry.cache.items[0];
    var n_uref: usize = 0;
    var saw_ustore = false;
    for (t.code.instrs) |ins| {
        if (ins.op == .uref) n_uref += 1;
        if (ins.op == .ustore) saw_ustore = true;
    }
    try testing.expectEqual(@as(usize, 1), n_uref); // ONE cell → ONE class → ONE uref
    try testing.expect(saw_ustore);
    var n_writer: usize = 0;
    var n_verifier: usize = 0;
    for (t.code.inputs) |seed| {
        if (seed.kind != .upvalue_cell) continue;
        if (seed.verify) n_verifier += 1 else n_writer += 1;
    }
    try testing.expectEqual(@as(usize, 1), n_writer);
    try testing.expectEqual(@as(usize, 1), n_verifier);
}

test "recorder (upvalue cell, P5): a store to an OPEN cell aborts (no trace)" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    // `n` still lives on outer's active frame, so the cell is OPEN: the pointer
    // `&cell.loc.closed` doesn't exist yet and open-cell stores write through the
    // stack — v1 declines the shape entirely (fail closed, doc 43 §8).
    var chunk = try runForTrace(&vm, gpa,
        \\local function outer()
        \\  local n = 0
        \\  local function bump() n = n + 1 end
        \\  for i = 1, 50 do bump() end
        \\  return n
        \\end
        \\print(outer())
    , true);
    defer chunk.deinit();

    try testing.expectEqual(@as(usize, 0), vm.trace.registry.cache.items.len);
    try testing.expect(vm.trace.record_gate.count() >= 1);
    try testing.expect(!vm.trace.isRecording());
}

test "recorder (upvalue cell, P5): a HEAP-valued store aborts fail-closed (scalar v1)" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    // The stored value is a string konst — not int/float/bool. The scalar bar
    // sits BEFORE the mutable-read bar in recSetUpval, so this unfixable shape
    // aborts .bad_type without memoizing a pointless retry.
    var chunk = try runForTrace(&vm, gpa,
        \\local function make()
        \\  local s = "a"
        \\  return function(n)
        \\    for i = 1, n do s = "b" end
        \\    return s
        \\  end
        \\end
        \\local f = make()
        \\print(f(50))
    , true);
    defer chunk.deinit();

    try testing.expectEqual(@as(usize, 0), vm.trace.registry.cache.items.len);
    try testing.expect(vm.trace.record_gate.count() >= 1);
    try testing.expect(!vm.trace.isRecording());
}

test "recorder (upvalue cell, P5): an hload-backed (computed) callee's upvalue access aborts — the P2×P5 invariant" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    // `t.inc` is an hload'd function field (P2 inlines it fine), but its body
    // touches an upvalue: the access path needs a slot_load-backed callee to be
    // re-resolvable at entry, and an hload result is not one — abort, no trace.
    // 400 `t.inc()` calls would also head-trace its body (doc 44, a closed-cell
    // RMW that records fine as a head); park hot-call counting — this test pins
    // the LOOP anchor's abort.
    vm.trace.config.hotcall = std.math.maxInt(u32);
    var chunk = try runForTrace(&vm, gpa,
        \\local function make()
        \\  local c = 0
        \\  return { inc = function() c = c + 1 end }
        \\end
        \\local t = make()
        \\for i = 1, 400 do t.inc() end
        \\print("done")
    , true);
    defer chunk.deinit();

    try testing.expectEqual(@as(usize, 0), vm.trace.registry.cache.items.len);
    try testing.expect(vm.trace.record_gate.count() >= 1);
    try testing.expect(!vm.trace.isRecording());
}

test "upvalue cell P5 end-to-end: steady-state counter closure (RMW via memo retry), all ten legs" {
    // The doc 43 §8 headline shape: a closed-over accumulator mutated every
    // iteration. First attempt memos, the retry commits uref/uload/ustore, and
    // the remaining iterations run on the trace; the second call re-seeds the
    // same cell and continues. Byte-identical across the ten-leg matrix.
    try expectProgram(
        \\local function make()
        \\  local count = 0
        \\  return function(n)
        \\    for i = 1, n do count = count + i end
        \\    return count
        \\  end
        \\end
        \\local f = make()
        \\print(f(500), f(3))
    , "125250\t125256\n");
}

test "upvalue cell P5 end-to-end: same-proto closure swap REBINDS the cell seed (g must not mutate f's cell)" {
    // The trace is recorded against f's cell; g enters the same anchor with its
    // OWN cell. The seed re-resolves per entry (the .upvalue snapshot-seed
    // discipline), so native writes must land in g's cell — a baked record-time
    // pointer would corrupt f. f(1) then proves f's cell was untouched by g.
    try expectProgram(
        \\local function make()
        \\  local c = 0
        \\  return function(n)
        \\    for i = 1, n do c = c + 1 end
        \\    return c
        \\  end
        \\end
        \\local f, g = make(), make()
        \\print(f(400), g(400), f(1))
    , "400\t400\t401\n");
}

test "upvalue cell P5 end-to-end: a verify-seed mismatch DECLINES the entry (record-time aliasing broken), stays exact" {
    // Recorded from f1, where `inc` IS f1's own setter: the verifier seed proves
    // inc's cell == the anchor's x cell. f2 borrows f1's setter (same proto — the
    // guard_func pin passes!), so only the verifier stands between the trace and
    // silently collapsing f2's two distinct cells into one. Every leg must agree:
    //   f1(400): 400·(2+1)            → 1200
    //   f2(400): f2.x gets +1/iter    → 400   (inc adds +2/iter to f1.x → 2000)
    //   f1(2):   2000 + 2·(2+1)       → 2006
    try expectProgram(
        \\local function make(inc)
        \\  local x = 0
        \\  local setter = function(d) x = x + d end
        \\  if inc == nil then inc = setter end
        \\  local f = function(n)
        \\    for i = 1, n do inc(2); x = x + 1 end
        \\    return x
        \\  end
        \\  return f, setter
        \\end
        \\local f1, s1 = make(nil)
        \\local f2, s2 = make(s1)
        \\print(f1(400), f2(400), f1(2))
    , "1200\t400\t2006\n");
}

test "upvalue cell P5 end-to-end: mixed ustore + hstore in one loop (C1 sinking + loop-done flush), all ten legs" {
    // `total` is a closed-cell RMW (uload → ustore) and `t.sum` a hash-field
    // store; the uload makes the trace heap-loading, so BOTH stores defer
    // through pending_stores and flush in order — including at the numeric
    // loop-done boundary (tier-1a flushNumericForLoopDone + the native linked
    // snapshot twin, whose whitelist now admits ustore).
    try expectProgram(
        \\local function make()
        \\  local total = 0
        \\  return function(t, n)
        \\    for i = 1, n do
        \\      total = total + i
        \\      t.sum = total
        \\    end
        \\    return total
        \\  end
        \\end
        \\local f = make()
        \\local acc = { sum = 0 }
        \\print(f(acc, 500), acc.sum)
    , "125250\t125250\n");
}

// ---------------------------------------------------------------------------
// Doc 44 P0: function-head anchors — hot-call counting → `.head` recording →
// `.terminal` close. Recording shape only: head *entry* (the `jfunc_head`
// patch) is P0 layer 4 and gets its own end-to-end tests when it lands.
// ---------------------------------------------------------------------------

/// `runForTrace` with a small `hotcall`, so a handful of straight-line calls
/// arms a function-head anchor. The default (112) would need an outer loop,
/// and that loop's own back-edge anchor would go hot first and muddy the
/// cache-shape assertions below.
fn runForHeadTrace(vm: *Vm, gpa: std.mem.Allocator, source: [:0]const u8) !compiler.Chunk {
    vm.trace.config.hotcall = 4;
    return runForTrace(vm, gpa, source, true);
}

test "recorder (head, doc 44 P0): a hot non-recursive call records a head trace closed by terminal/return_interp" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    // Straight-line calls only — no loops, so the ONLY possible anchor is the
    // function head. Entry #4 trips `hotcall`, the pending anchor is consumed
    // at `add`'s pc 0, and the depth-0 `ret` closes the trace with a terminal.
    var chunk = try runForHeadTrace(&vm, gpa,
        \\local function add(a, b) return a + b end
        \\local r = 0
        \\r = add(r, 1)
        \\r = add(r, 2)
        \\r = add(r, 3)
        \\r = add(r, 4)
        \\r = add(r, 5)
        \\print(r)
    );
    defer chunk.deinit();

    try testing.expectEqual(@as(usize, 1), vm.trace.registry.cache.items.len);
    try testing.expectEqual(@as(u32, 0), vm.trace.record_gate.count());
    const t = vm.trace.registry.cache.items[0];
    // Head identity: the sentinel pc, never bytecode pc 0.
    try testing.expectEqual(trace.FUNC_HEAD_PC, t.code.anchor.pc);
    // The terminator is the terminal, not a back-edge `loop`.
    const last = t.code.instrs[t.code.instrs.len - 1];
    try testing.expectEqual(trace.trace_ir.IrOp.terminal, last.op);
    try testing.expectEqual(
        @intFromEnum(trace.trace_ir.TerminalKind.return_interp),
        last.a,
    );
    // The end state publishes through φ writeback rows: `a + b` defines at
    // least one depth-0 slot the resumed `ret` will read.
    var saw_phi = false;
    for (t.code.instrs) |ins| {
        if (ins.op == .phi) saw_phi = true;
    }
    try testing.expect(saw_phi);
}

test "recorder (head, doc 44 P0): fib-shaped recursion records a head trace closed by terminal/self_call_interp" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    // fib(12) → fib(11) → fib(10) → fib(9): the 4th entry (n = 9) arms the
    // head, takes the recursive branch, and the depth-0 self-call closes the
    // trace with `self_call_interp` — tier-0 re-executes the call generically.
    var chunk = try runForHeadTrace(&vm, gpa,
        \\local function fib(n)
        \\  if n < 2 then return n end
        \\  return fib(n - 1) + fib(n - 2)
        \\end
        \\print(fib(12))
    );
    defer chunk.deinit();

    // Doc 44 D12b: the same warmup now also forms CONTINUATION traces at
    // fib's two post-call resume pcs (returns count at `hotcall` too) — one
    // closing self_call_interp (after fib(n-1), the `+ fib(n-2)` call), one
    // return_interp (after fib(n-2), the add + ret). Count by kind.
    try testing.expectEqual(@as(u32, 0), vm.trace.record_gate.count());
    var heads: usize = 0;
    var conts: usize = 0;
    var saw_cont_self_call = false;
    var saw_cont_return = false;
    for (vm.trace.registry.cache.items) |t| {
        const last = t.code.instrs[t.code.instrs.len - 1];
        switch (trace.anchorKind(t.code.anchor.pc)) {
            .head => {
                heads += 1;
                try testing.expectEqual(trace.trace_ir.IrOp.terminal, last.op);
                try testing.expectEqual(
                    @intFromEnum(trace.trace_ir.TerminalKind.self_call_interp),
                    last.a,
                );
            },
            .cont => {
                conts += 1;
                try testing.expectEqual(trace.trace_ir.IrOp.terminal, last.op);
                switch (@as(trace.trace_ir.TerminalKind, @enumFromInt(@as(u16, @intCast(last.a))))) {
                    .self_call_interp => saw_cont_self_call = true,
                    .return_interp => saw_cont_return = true,
                }
            },
            .loop => return error.TestUnexpectedResult, // no loops in this program
        }
    }
    try testing.expectEqual(@as(usize, 1), heads);
    try testing.expectEqual(@as(usize, 2), conts);
    try testing.expect(saw_cont_self_call and saw_cont_return);
}

test "head exclusion (doc 44 D1): a head trace's guards never classify as bridge or loop-done, and contribute no successor edges" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    // The real recorded fib head trace: its base-case branch guard carries
    // `.branch_cond` provenance with slot-bound φs below it — exactly the
    // shape `classifyBridgeCandidate`'s structural checks alone would admit
    // (the `exit_pc >= anchor.pc` cut is vacuous against the sentinel). The
    // D1 kind checks must refuse every classifier at every index.
    var chunk = try runForHeadTrace(&vm, gpa,
        \\local function fib(n)
        \\  if n < 2 then return n end
        \\  return fib(n - 1) + fib(n - 2)
        \\end
        \\print(fib(12))
    );
    defer chunk.deinit();

    // Doc 44 D12b: the warmup now commits ONE head trace plus fib's two cont
    // traces — and the D1 exclusions must hold for EVERY one-shot trace
    // (head and cont alike), so run the classifier sweep over all of them.
    try testing.expectEqual(@as(usize, 3), vm.trace.registry.cache.items.len);
    var heads: usize = 0;
    for (vm.trace.registry.cache.items) |t| {
        try testing.expect(trace.anchorKind(t.code.anchor.pc) != .loop);
        if (trace.anchorKind(t.code.anchor.pc) == .head) heads += 1;

        for (0..t.code.instrs.len) |i| {
            // Site 1 (trace_code.zig): loop-region bridging.
            try testing.expect(!t.code.classifyBridgeCandidate(i));
            try testing.expect(!t.code.isBridgeCandidate(i));
            // Site 2 (trace_code.zig): the loop-done guard classifier twin.
            try testing.expect(!t.code.isNumericForLoopDoneGuard(i));
            // Site 3 (trace.zig): the arming-side loop-done classifier.
            try testing.expect(!trace.isLoopDoneGuardIndex(t, i));
        }
        // Site 4 (trace_link.zig): the structural successor graph — no edge
        // from any one-shot trace's keyed exits.
        for (t.code.exit_prov) |ep| {
            try testing.expectEqual(
                @as(?trace.TraceState.SuccAnchor, null),
                vm.trace.resolveSuccessorAnchor(t, ep),
            );
        }
    }
    try testing.expectEqual(@as(usize, 1), heads);
}

test "recorder (cont, doc 44 D12b): a hot NON-recursive call site forms a continuation trace closed by return_interp" {
    // The generality pin: cont anchors are any hot call site's continuation,
    // not a recursion feature. `f` returns into `g` 40 times; at hotcall=4
    // the resume pc in `g` arms a `.cont` recording whose straight-line
    // continuation (`+ 1`, depth-0 ret) closes return_interp. The driver
    // loop is kept cold (hotloop huge) so the only committed traces are the
    // one-shot family's; the resume pc AFTER `g(i)` sits inside the loop
    // body, so its cont recording aborts `.cont_backedge` into the record
    // gate (asserted cont-kind, the designed loop-yielding refusal).
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    const source =
        \\local function f(x) return x * 2 end
        \\local function g(x) return f(x) + 1 end
        \\local total = 0
        \\for i = 1, 40 do total = total + g(i) end
        \\print(total)
    ;
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();
    vm.trace.config.enabled = true;
    vm.trace.config.execute = false;
    vm.trace.config.optimize = false;
    vm.trace.config.hotloop = 1 << 24; // driver loop never arms
    vm.trace.config.hotcall = 4;
    var buf: [256]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;
    var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    _ = try vm.run(chunk.proto);
    try testing.expectEqualStrings("1680\n", sink.buffered());

    var cont_return = false;
    for (vm.trace.registry.cache.items) |t| {
        try testing.expect(trace.anchorKind(t.code.anchor.pc) != .loop);
        if (trace.anchorKind(t.code.anchor.pc) != .cont) continue;
        const last = t.code.instrs[t.code.instrs.len - 1];
        try testing.expectEqual(trace.trace_ir.IrOp.terminal, last.op);
        if (last.a == @intFromEnum(trace.trace_ir.TerminalKind.return_interp))
            cont_return = true;
    }
    try testing.expect(cont_return);
    // The in-loop resume pc's recording died on the back-edge, cont-gated.
    var saw_cont_gate = false;
    var it = vm.trace.record_gate.iterator();
    while (it.next()) |e| {
        if (trace.anchorKind(e.key_ptr.pc) == .cont) saw_cont_gate = true;
    }
    try testing.expect(saw_cont_gate);
}

test "cont collision refusal (doc 44 D12b): a resume pc holding a patchable-op site forms no cont anchor" {
    // `for i = 1, 8 do f(i) end` with the call as the body's last statement:
    // f's resume pc holds the loop's own `for_loop` back-edge — the exact pc
    // a `jfor_loop` patch would claim if the loop got hot. The physical-pc
    // collision rule (round 6 change 3) refuses cont formation at any such
    // site outright — no counter entry, no recording, no patch —
    // conservatively by OP via `patchedEntryOp` (fail-closed is the v1
    // contract; a multiplexed entry opcode is the recorded durable
    // follow-up).
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    const source =
        \\local function f(i) return i < 40 end
        \\for i = 1, 8 do f(i) end
        \\print("done")
    ;
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();
    vm.trace.config.enabled = true;
    vm.trace.config.execute = false;
    vm.trace.config.optimize = false;
    vm.trace.config.hotloop = 1 << 24; // isolate: the repeat loop never arms
    vm.trace.config.hotcall = 4;
    var buf: [256]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;
    var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    _ = try vm.run(chunk.proto);
    try testing.expectEqualStrings("done\n", sink.buffered());

    // The shape premise, pinned so a compiler change can't silently turn
    // this into a plain formation test: f's resume pc holds a patchable op
    // (the numeric for's own back-edge).
    var call_pc: ?usize = null;
    for (chunk.proto.code, 0..) |ins, ii| {
        if (ins.op == .call and call_pc == null) call_pc = ii;
    }
    try testing.expect(chunk.proto.code[call_pc.? + 1].op == .for_loop);
    // Stronger than "no cont trace": the collision rule bars COUNTING, so no
    // cont-kind key may exist in the warming counters or gates at all.
    var cit = vm.trace.counters.iterator();
    while (cit.next()) |e|
        try testing.expect(trace.anchorKind(e.key_ptr.pc) != .cont);
    var git = vm.trace.record_gate.iterator();
    while (git.next()) |e|
        try testing.expect(trace.anchorKind(e.key_ptr.pc) != .cont);
    for (vm.trace.registry.cache.items) |t|
        try testing.expect(trace.anchorKind(t.code.anchor.pc) != .cont);
}

test "recorder (head, doc 44 P0): a vararg callee never counts and never arms" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    // `onCallEntry` refuses vararg protos outright (doc 44 D2): no counter,
    // no pending anchor, no gate strike — six entries leave the cache empty.
    var chunk = try runForHeadTrace(&vm, gpa,
        \\local function f(...) return 1 end
        \\f() f() f() f() f() f()
        \\print("done")
    );
    defer chunk.deinit();

    try testing.expectEqual(@as(usize, 0), vm.trace.registry.cache.items.len);
    try testing.expectEqual(@as(u32, 0), vm.trace.record_gate.count());
    try testing.expect(!vm.trace.isRecording());
}

test "head e2e (doc 44 P0): recursive fib steady state — head trace enters via jfunc_head, all ten legs" {
    // The arc's headline shape: fib records a `.head` trace closed by
    // `terminal/self_call_interp` (committed mid-run at the default
    // hotcall=112), the commit installs the pc-0 `jfunc_head` patch, and
    // every later fib entry runs the traced prefix on tier-1a, resuming
    // tier-0 at the unexecuted self-call. Base-case entries (n < 2) fail
    // the branch guard and deopt to pc 0 with regs untouched. Byte-identical
    // across the ten-leg matrix.
    try expectProgram(
        \\local function fib(n)
        \\  if n < 2 then return n end
        \\  return fib(n - 1) + fib(n - 2)
        \\end
        \\print(fib(18))
    , "2584\n");
}

test "head e2e (doc 44 P0): hot non-recursive call — terminal/return_interp resumes at the ret, all ten legs" {
    // A straight-line callee crossing hotcall inside a hot LOOP: the loop
    // trace goes hot first (inlining the call), the head anchor arms off the
    // still-interpreted warmup calls, and both coexist — the head's terminal
    // publishes the summed temp the resumed `ret` returns.
    try expectProgram(
        \\local function mix(a, b)
        \\  local s = a + b
        \\  return s * 2 - a
        \\end
        \\local acc = 0
        \\for i = 1, 300 do acc = acc + mix(acc % 7, i) end
        \\print(acc)
    , "91191\n");
}

test "head e2e (doc 44 P0): head trace with an upvalue read seed — same-proto closure swap re-resolves, all ten legs" {
    // The callee reads a closed-over scalar: the head trace carries an
    // `.upvalue` snapshot seed that must re-resolve per entry through the
    // ENTERING closure (g's cell, not record-time f's). f then proves its
    // own cell was never touched by g's entries.
    try expectProgram(
        \\local function make(k)
        \\  return function(x) return x + k end
        \\end
        \\local f, g = make(10), make(1000)
        \\local a = 0
        \\for i = 1, 200 do a = a + f(i) end
        \\local b = 0
        \\for i = 1, 200 do b = b + g(i) end
        \\print(a, b)
    , "22100\t220100\n");
}

test "head e2e (doc 44 D8): non-recursive two-path head — alternating calls grow a path sibling, all ten legs" {
    // Z-6 pin: head path siblings are general path-polymorphic
    // specialization, not a recursion feature. `pick` splits at its head on
    // the sign of `n`; strictly alternating calls guarantee whichever path
    // the incumbent records, every other call zero-exits it — the hot-exit
    // want, current-activation transfer, and sibling walk must all fire with
    // zero recursion anywhere. Byte-identical across the ten-leg matrix.
    try expectProgram(
        \\local function pick(n)
        \\  if n < 0 then return -n end
        \\  return n + 1
        \\end
        \\local acc = 0
        \\for i = 1, 300 do
        \\  if i % 2 == 0 then acc = acc + pick(-i) else acc = acc + pick(i) end
        \\end
        \\print(acc)
    , "45300\n");
}

test "recorder (head, doc 44 D8): the sibling lifecycle — want, transfer, second head trace, want retired" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    // The sibling lifecycle needs EXECUTION (zero exits only happen when the
    // incumbent actually runs), so `runForTrace`'s recording-only harness
    // (execute=false) can't drive it — inline the executing variant.
    const source =
        \\local function pick(n)
        \\  if n < 0 then return -n end
        \\  return n + 1
        \\end
        \\local acc = 0
        \\for i = 1, 60 do
        \\  if i % 2 == 0 then acc = acc + pick(-i) else acc = acc + pick(i) end
        \\end
        \\print(acc)
    ;
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();
    vm.trace.config.enabled = true;
    vm.trace.config.execute = true;
    vm.trace.config.hotloop = 4;
    vm.trace.config.hotcall = 4;
    vm.trace.config.hotexit = 3; // few zero exits → want (default 10)
    // Doc 56 Phase 3: this pins the head-sibling lifecycle, which needs the
    // alternating `pick` calls to keep arriving from tier-0. With exit-side
    // routing the outer `for` trace's branch exit grows a child at its
    // resume pc that inlines the other path, so those calls stop reaching
    // the head anchor at all. Keep the loop on today's routes here.
    vm.trace.config.exit_side = false;
    var buf: [256]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;
    var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    _ = try vm.run(chunk.proto);
    // Alternating two-path calls: the incumbent records one path, the other
    // path's calls zero-exit it hot, the want transfers on the current
    // activation, and the sibling records the other path. Both then complete
    // their own calls — the anchor ends with TWO head traces, the want
    // retired (cleared + DONE-latched by the sibling completion), and no
    // record gate.

    // The outer `for` records its own loop trace (hotloop=56 < 60 iters); the
    // head-anchored population is what this test pins.
    var heads: usize = 0;
    for (vm.trace.registry.cache.items) |t| {
        if (!trace.isHeadAnchorPc(t.code.anchor.pc)) continue;
        heads += 1;
        const last = t.code.instrs[t.code.instrs.len - 1];
        try testing.expectEqual(trace.trace_ir.IrOp.terminal, last.op);
    }
    try testing.expectEqual(@as(usize, 2), heads);
    // Doc 44 D12b: the post-call resume pcs sit INSIDE the outer `for` body,
    // so their cont recordings meet the loop back-edge and abort
    // `.cont_backedge` into the record gate — the designed v1 loop-yielding
    // refusal. The HEAD lifecycle pin stands: no gate entry at a head anchor.
    var it = vm.trace.record_gate.iterator();
    while (it.next()) |e| {
        try testing.expectEqual(trace.AnchorPcKind.cont, trace.anchorKind(e.key_ptr.pc));
    }
    // The want must not linger once the sibling covers the failing path
    // (review round 2 blocker 3 — a stuck want would re-record duplicates).
    try testing.expect(vm.trace.wants_head_sibling == null);
    try testing.expect(vm.trace.head_want_src == null);
}

test "head e2e (doc 44 D10): alternating two-path head under a low hotguard stays byte-identical, all ten legs" {
    // Output pin for the D10 machinery across the ten-leg matrix: with
    // `hotguard = 5`, the native legs can arm `.sibling_handoff` on the head
    // incumbent's branch-guard exit and fuse A→B bursts, while the tier-1a
    // legs keep walking unfused — the outputs must still agree byte-for-byte
    // (arms are native-physical only; guard re-verification preserves
    // committed state).
    try util.expectProgramTuned(
        \\local function pick(n)
        \\  if n < 0 then return -n end
        \\  return n + 1
        \\end
        \\local acc = 0
        \\for i = 1, 600 do
        \\  if i % 2 == 0 then acc = acc + pick(-i) else acc = acc + pick(i) end
        \\end
        \\print(acc)
    , "180600\n", .{ .hotguard = 5 });
}

test "head arm formation (doc 44 D10): the walk evidence channel arms a .sibling_handoff exit patch with a head parent" {
    // The D10 formation proof: the incumbent's branch-guard deopt plus the
    // sibling's terminal completion within ONE `enterPatchedTrace` walk
    // charge the Part-S watch (`head_walk_fail` → `noteSiblingTerminal`);
    // at `hotguard` the exit arms `.sibling_handoff` at the dispatcher's
    // next same-anchor selection. Without this assertion the ten-leg pin
    // above would silently pass on a regression that never arms (the scalar
    // walk is output-equivalent, just slower). Native-only: evidence and
    // arms are both native-physical.
    //
    // Native exit adapters OFF: with them on (the default since doc 58 B2)
    // the incumbent's branch exit is attachable, so doc 56's exit-side route
    // claims it first and binds a side trace at its resume pc — the Part-S
    // walk channel then never charges. Part S still serves every exit
    // exit-side refuses (peeled, precise, non-attachable); this pins that
    // channel, not the default route.
    if (!@import("nativegen.zig").is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    const source =
        \\local function pick(n)
        \\  if n < 0 then return -n end
        \\  return n + 1
        \\end
        \\local acc = 0
        \\for i = 1, 600 do
        \\  if i % 2 == 0 then acc = acc + pick(-i) else acc = acc + pick(i) end
        \\end
        \\print(acc)
    ;
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();
    vm.trace.config.enabled = true;
    vm.trace.config.execute = true;
    vm.trace.config.optimize = true;
    vm.trace.config.native_codegen = true;
    vm.trace.config.hotloop = 4;
    vm.trace.config.hotcall = 4;
    vm.trace.config.hotexit = 3;
    vm.trace.config.hotguard = 5;
    vm.trace.config.exit_side_native = false;
    var buf: [256]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;
    var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    _ = try vm.run(chunk.proto);
    try testing.expectEqualStrings("180600\n", sink.buffered());
    // At least one armed handoff whose PARENT is a head trace; every head
    // arm's child must share the head anchor (the validator's same-anchor
    // rule — a cross-anchor head arm would be a validator regression).
    var head_arms: usize = 0;
    for (vm.trace.registry.native_physical.armedLinks()) |l| {
        if (l.kind != .sibling_handoff) continue;
        if (!trace.isHeadAnchorPc(l.parent.code.anchor.pc)) continue;
        try testing.expect(trace.isHeadAnchorPc(l.child.code.anchor.pc));
        try testing.expect(l.parent.code.anchor.proto == l.child.code.anchor.proto);
        head_arms += 1;
    }
    try testing.expect(head_arms >= 1);
}

test "head e2e (doc 44 D11): deep linear self-recursion stays byte-identical, all ten legs" {
    // Output pin for the native frame-push descent: on the native legs a
    // committed `.terminal(self_call_interp)` page pushes real VM frames down
    // to the base case (which deopts at the branch guard and hands the leaf
    // to tier-0); the tier-1a legs keep the P0 interp terminal. Byte-identical
    // output across the matrix is the transparency claim.
    try util.expectProgram(
        \\local function sum(n)
        \\  if n == 0 then return 0 end
        \\  return n + sum(n - 1)
        \\end
        \\local s = 0
        \\for i = 1, 5 do s = s + sum(150) end
        \\print(s)
    , "56625\n");
}

test "head e2e (doc 44 D11): StackOverflow through a native descent — message and pcall catch identical, all ten legs" {
    // The depth wall: the second `pcall` descends natively (the head patched
    // after the first run's warmup) until the inline push sequence declines
    // at `max_call_depth`; the plain terminal resumes the leaf AT its self-call
    // and tier-0 re-executes it generically, raising `StackOverflow` with
    // intact frames — so the located message (`describeFault`) and the pcall
    // catch must be byte-identical to the pure tier-0 legs.
    try util.expectProgram(
        \\local function down(n)
        \\  if n > 300 then return n end
        \\  return 1 + down(n + 1)
        \\end
        \\local ok1, err1 = pcall(down, 1)
        \\local ok2, err2 = pcall(down, 1)
        \\print(ok1, err1)
        \\print(ok2, err2)
    , "false\tdown:3: stack overflow\nfalse\tdown:3: stack overflow\n");
}

test "head e2e (doc 44 D11): argument type change at depth deopts mid-descent, all ten legs" {
    // At d == 60 the step read flips int → float: the guard fails at that
    // depth, the deopt flushes into the CURRENT (descended) window, and the
    // pushed leaf frame resumes at pc 0 on tier-0 — the Piece-3 coherence
    // claim. The float then propagates through the remaining recursion on
    // tier-0/leaf-walk paths; output must not depend on where the descent cut.
    try util.expectProgram(
        \\local steps = {}
        \\for i = 1, 100 do steps[i] = 1 end
        \\steps[60] = 1.5
        \\local function g(n, d)
        \\  if n < 2 then return 1 end
        \\  return 1 + g(n - steps[d], d + 1)
        \\end
        \\local s = 0
        \\for i = 1, 8 do s = s + g(90, 1) end
        \\print(s)
    , "712\n");
}

test "head e2e (doc 44 D11): mid-run callee rebind through the recursion upvalue, all ten legs" {
    // The recursion upvalue is rebound to a DIFFERENT proto while old-proto
    // activations are still live. A function-valued `ustore` aborts recording
    // (doc 43 P5 scalar-only), so no committed trace can contain the rebind
    // itself — the helper's proto check is the fail-closed wall (unit matrix
    // below); this pin proves the surrounding machinery (deopt at the trigger
    // guard, generic tier-0 calls of the new callee from old bodies) stays
    // transparent.
    try util.expectProgram(
        \\local f
        \\local trigger = false
        \\f = function(n)
        \\  if trigger and n == 10 then f = function(m) return 1000 + m end end
        \\  if n < 2 then return n end
        \\  return f(n - 2) + f(n - 1)
        \\end
        \\local a = f(18)
        \\trigger = true
        \\local b = f(18)
        \\print(a, b)
    , "2584\t6073\n");
}

test "head descent formation (doc 44 D11): the self-call terminal actually pushes native frames" {
    // The formation proof: output equality alone cannot distinguish a live
    // descent from the (slower, output-equivalent) per-call episode
    // turnstile. Run a recursion under explicit low warmup and assert the
    // `self_call_pushes` witness advanced. Native-only: the push epilogue is
    // a nativegen lowering.
    if (!@import("nativegen.zig").is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    const source =
        \\local function sum(n)
        \\  if n == 0 then return 0 end
        \\  return n + sum(n - 1)
        \\end
        \\local s = 0
        \\for i = 1, 5 do s = s + sum(150) end
        \\print(s)
    ;
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();
    vm.trace.config.enabled = true;
    vm.trace.config.execute = true;
    vm.trace.config.optimize = true;
    vm.trace.config.native_codegen = true;
    vm.trace.config.hotloop = 4;
    vm.trace.config.hotcall = 4;
    var buf: [256]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;
    var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    _ = try vm.run(chunk.proto);
    try testing.expectEqualStrings("56625\n", sink.buffered());
    // Committed descents: each sum(150) after commit pushes ~149 frames.
    try testing.expect(vm.trace.self_call_pushes >= 100);
}

test "head handoff evidence symmetry (doc 44 D12a): the base-case-incumbent shape arms BOTH directions" {
    // Which sibling records FIRST is a deterministic function of hot-call
    // timing, and pre-D12a the base-case-incumbent shape (fib(27) in the
    // field) could arm NEITHER handoff direction: the entry walk's
    // "completion" is a productive descent (no terminal → no
    // `noteSiblingTerminal` pairing), and the descent-bottom deopt died with
    // the walk-start `head_walk_fail` reset. Steady state was one penalty
    // strike + two extra episodes per call, forever. This test pins the bad
    // shape ON PURPOSE — with `hotcall = 4`, warming with `fib(4)` makes the
    // 4th fib call `fib(1)` (a base case: calls go 4, 2, 0, 1 under the
    // n-2-first body), so the FIRST recorded trace is the base-case sibling
    // and it takes the entry patch — then asserts the two D12a evidence
    // flows arm BOTH directions (the lucky shape arms exactly one; ≥ 2 is
    // unreachable without the fix) while descents stay live and the output
    // stays exact. Native-only: descents are a nativegen lowering.
    if (!@import("nativegen.zig").is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    const source =
        \\local function fib(n)
        \\  if n < 2 then return 1 end
        \\  return fib(n-2) + fib(n-1)
        \\end
        \\local warm = fib(4)
        \\local big = fib(20)
        \\print(warm, big)
    ;
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();
    vm.trace.config.enabled = true;
    vm.trace.config.execute = true;
    vm.trace.config.optimize = true;
    vm.trace.config.native_codegen = true;
    vm.trace.config.hotloop = 4;
    vm.trace.config.hotcall = 4;
    var buf: [256]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;
    var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    _ = try vm.run(chunk.proto);
    try testing.expectEqualStrings("5\t10946\n", sink.buffered());
    // Both evidence flows fired: A1 (walk failer + productive descent) arms
    // base@guard → descender; A2 (descent-bottom carry + leaf completion)
    // arms descender@guard → base. The lucky shape produces exactly one arm.
    try testing.expect(vm.trace.sibling_handoff_arms >= 2);
    // And the descents themselves are live (not a scalar-turnstile pass).
    try testing.expect(vm.trace.self_call_pushes >= 100);
}

// (The doc 44 D11 "push helper refusal matrix" test lived here. Doc 54 P2
// deleted `nativeSelfCallPush` — cont pages now run the same inline push
// sequence as head pages — so the matrix's walls now live as: emit-time
// statics (aux bounds / non-call / all_results / vararg anchor are the
// commit-time `push_static` eligibility — an ineligible page emits no push
// epilogue at all, pinned by the fail-closed test below), the per-episode
// descent byte (`descent_ok` folds `reg_top_pending` — its own unit matrix
// below), the inline step-2 callee guard (tag / object type / proto pin
// covers the non-function and foreign-proto rows), the inline step-3 walls
// (depth, register capacity, call_seq space), and the doc 54 P2 step-0
// descent poll budget. The positive control's frame shape (depth, base,
// one-past-call cursor, tick, witness) is pinned by the formation witness
// above plus byte-identical ten-legs output on every recursion e2e.)

// (The doc 54 P0 "inline push formation with the cont helper removed" test
// lived here. Its discriminator — nulling `self_call_push_fn` so only the
// inline head-page sequence could push — became vacuous when doc 54 P2
// deleted the helper field outright: EVERY push is the inline sequence by
// construction now, and the formation-witness test above pins exactly the
// same claim on the same program.)

test "fail-closed compilation (doc 54 P0): absent frame_abi emits no push epilogue" {
    // Sabotage the emission gate: with `frame_abi` null (a hand-built-ctx
    // world), NO page may carry a push epilogue — the inline sequence is
    // the only push path since doc 54 P2 deleted the cont helper, and its
    // emission gates on the descriptor. The compiled traces run their
    // plain terminal exits and tier-0 executes every call generically.
    // Output stays exact and the witness stays at zero. This is the
    // fail-closed half of the P0 contract (an absent descriptor can never
    // miscompile, only decline).
    if (!@import("nativegen.zig").is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    vm.trace.registry.native_seed_ctx.?.frame_abi = null;
    const source =
        \\local function sum(n)
        \\  if n == 0 then return 0 end
        \\  return n + sum(n - 1)
        \\end
        \\local s = 0
        \\for i = 1, 5 do s = s + sum(150) end
        \\print(s)
    ;
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();
    vm.trace.config.enabled = true;
    vm.trace.config.execute = true;
    vm.trace.config.optimize = true;
    vm.trace.config.native_codegen = true;
    vm.trace.config.hotloop = 4;
    vm.trace.config.hotcall = 4;
    var buf: [256]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;
    var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    _ = try vm.run(chunk.proto);
    try testing.expectEqualStrings("56625\n", sink.buffered());
    try testing.expectEqual(@as(u64, 0), vm.trace.self_call_pushes);
    // Doc 54 P1: the pop epilogue is gated on the same descriptor — no
    // frame_abi, no inline pop (and with zero pushes the net floor would
    // refuse anyway; the zero witness pins that no pop sequence ran).
    try testing.expectEqual(@as(u64, 0), vm.trace.self_ret_pops);
}

test "descent gate publication (doc 54 P0): prepareNativeEpisode computes descent_ok from all three conjuncts" {
    // The descent-gate half of the sabotage protocol. The inline sequence
    // replaced the helper's per-push `receiptsInert()`/`reg_top_pending`/
    // `final_cut` re-derivation with the per-episode `descent_ok` byte, so
    // break each replaced conjunct and prove the publication bites. This
    // is deliberately a UNIT matrix over `prepareNativeEpisode`: at
    // integration level a healthy single run can never see `descent_ok=0`
    // (that is exactly the episode-invariance the design leans on — the
    // top-level epoch resets region receipts before any episode, verified
    // the hard way: a planted receipt before `run()` was wiped and 743
    // pushes happened anyway). The emitted `cmp byte` CONSUMING the gate
    // is pinned by the inline-push formation test (pushes require the
    // published 1) plus the comptime `@offsetOf` the emission bakes.
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var proto = Proto{
        .code = &.{Instr{ .op = .ret }},
        .num_registers = 2,
        .name = "d54gate",
    };
    const cl = try vm.heap.newClosure(&proto, 0);
    try vm.pushFrame(cl, 0, 0, 0);
    const ctx = vm.trace.registry.native_seed_ctx.?;

    // Clean state: all three conjuncts hold → gate open.
    vm.prepareNativeEpisode(cl, &proto, 0);
    try testing.expectEqual(@as(u8, 1), ctx.descent_ok);

    // Live region receipts → closed; drained again → open.
    try vm.trace.region_policy.region_profit.put(gpa, .{ .region_id = @enumFromInt(999), .activation = 1 }, .{
        .root_frame_depth = 1,
        .root_call_seq = 1,
    });
    vm.prepareNativeEpisode(cl, &proto, 0);
    try testing.expectEqual(@as(u8, 0), ctx.descent_ok);
    _ = vm.trace.region_policy.region_profit.remove(.{ .region_id = @enumFromInt(999), .activation = 1 });
    vm.prepareNativeEpisode(cl, &proto, 0);
    try testing.expectEqual(@as(u8, 1), ctx.descent_ok);

    // Pending multret reg-top → closed; cleared → open.
    vm.reg_top_pending = true;
    vm.prepareNativeEpisode(cl, &proto, 0);
    try testing.expectEqual(@as(u8, 0), ctx.descent_ok);
    vm.reg_top_pending = false;
    vm.prepareNativeEpisode(cl, &proto, 0);
    try testing.expectEqual(@as(u8, 1), ctx.descent_ok);

    // Published final cut → closed; nulled → open.
    vm.setFinalCut(.{ .result_base = 0, .result_count = 0, .stack_top = 0 });
    vm.prepareNativeEpisode(cl, &proto, 0);
    try testing.expectEqual(@as(u8, 0), ctx.descent_ok);
    vm.setFinalCut(null);
    vm.prepareNativeEpisode(cl, &proto, 0);
    try testing.expectEqual(@as(u8, 1), ctx.descent_ok);
}

test "open-upvalue ceiling (doc 54 P1): centralized maintenance keeps the watermark exact-or-high" {
    // The inline native pop replaces the helper's full open-list scan with
    // one `ceiling <= popped base` compare, so the ceiling must never go
    // stale-LOW (unsound: a pop would free a window with a live open cell
    // above it). Pin every maintenance site: append raises via @max,
    // closeUpvaluesFrom recomputes exactly (0 on empty), clear resets.
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    try testing.expectEqual(@as(usize, 0), vm.open_upvalue_ceiling);
    // closeWith snapshots the live slot — give the slots defined values.
    vm.regSet(1, Value.int(11));
    vm.regSet(3, Value.int(13));
    vm.regSet(5, Value.int(15));
    vm.regSet(7, Value.int(17));
    vm.stack_top = 8;
    try vm.appendOpenUpvalue(3, try vm.heap.newUpvalue(3));
    try testing.expectEqual(@as(usize, 4), vm.open_upvalue_ceiling);
    try vm.appendOpenUpvalue(7, try vm.heap.newUpvalue(7));
    try testing.expectEqual(@as(usize, 8), vm.open_upvalue_ceiling);
    // A lower open never lowers the watermark.
    try vm.appendOpenUpvalue(1, try vm.heap.newUpvalue(1));
    try testing.expectEqual(@as(usize, 8), vm.open_upvalue_ceiling);
    // Partial close: the exact recompute drops to the surviving max.
    vm.closeUpvaluesFrom(4);
    try testing.expectEqual(@as(usize, 4), vm.open_upvalue_ceiling);
    // Close-all: empty list ⇒ zero.
    vm.closeUpvaluesFrom(0);
    try testing.expectEqual(@as(usize, 0), vm.open_upvalue_ceiling);
    // The wholesale clear resets with the list.
    try vm.appendOpenUpvalue(5, try vm.heap.newUpvalue(5));
    try testing.expectEqual(@as(usize, 6), vm.open_upvalue_ceiling);
    vm.clearOpenUpvalues();
    try testing.expectEqual(@as(usize, 0), vm.open_upvalue_ceiling);
}

test "ret pop formation (doc 44 D12c): fused descents unwind through the native pop" {
    // The pop's formation proof, symmetric to the D11 push witness: output
    // equality cannot distinguish a native pop from the (slower) plain
    // terminal + tier-0 opRet, so assert the `self_ret_pops` witness
    // advanced. fib's fused descents (push chain + armed sibling handoff
    // into the base-case page, whose terminal is `return_interp`) are what
    // commit a pop: net > 0 with a same-proto episode-pushed top frame.
    // Native-only: the pop epilogue is a nativegen lowering.
    if (!@import("nativegen.zig").is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    const source =
        \\local function fib(n)
        \\  if n < 2 then return 1 end
        \\  return fib(n-2) + fib(n-1)
        \\end
        \\print(fib(20))
    ;
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();
    vm.trace.config.enabled = true;
    vm.trace.config.execute = true;
    vm.trace.config.optimize = true;
    vm.trace.config.native_codegen = true;
    vm.trace.config.hotloop = 4;
    vm.trace.config.hotcall = 4;
    var buf: [256]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;
    var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    _ = try vm.run(chunk.proto);
    try testing.expectEqualStrings("10946\n", sink.buffered());
    // Descents live AND their unwinds pop natively. More importantly, pin the
    // whole four-page fib cycle: head + base sibling + both continuation pages
    // must all compile, both dynamic return PCs must arm and hit, and the first
    // continuation's second recursive call must form and use its call-head
    // link. This catches the circular bug where push was gated on an already
    // armed call-head slot (so no committed miss could ever request the arm).
    vm.trace.dbg("D12c witnesses: pushes={d} pops={d} ret hits={d} call hits={d}", .{ vm.trace.self_call_pushes, vm.trace.self_ret_pops, vm.trace.ret_cont_link_hits, vm.trace.call_head_link_hits });
    try testing.expect(vm.trace.self_call_pushes >= 100);
    try testing.expect(vm.trace.self_ret_pops >= 100);
    var native_traces: usize = 0;
    var native_conts: usize = 0;
    for (vm.trace.registry.cache.items) |t| switch (t.native) {
        .compiled => {
            native_traces += 1;
            if (trace.anchorKind(t.code.anchor.pc) == .cont) native_conts += 1;
        },
        else => {},
    };
    try testing.expectEqual(@as(usize, 4), vm.trace.registry.cache.items.len);
    try testing.expectEqual(@as(usize, 4), native_traces);
    try testing.expectEqual(@as(usize, 2), native_conts);
    vm.trace.dbg("D12c formation: native={d} cont={d} ret arms/hits={d}/{d} call arms/hits={d}/{d}", .{ native_traces, native_conts, vm.trace.ret_cont_link_arms, vm.trace.ret_cont_link_hits, vm.trace.call_head_link_arms, vm.trace.call_head_link_hits });
    try testing.expect(vm.trace.ret_cont_link_arms >= 2);
    try testing.expect(vm.trace.ret_cont_link_hits >= 2);
    try testing.expect(vm.trace.call_head_link_arms >= 1);
    try testing.expect(vm.trace.call_head_link_hits >= 1);
    // Doc 54 P2 (as amended): frame-motion chains run ROW-FREE, so the old
    // mixed-chain capacity-cut witness (`frame_link_cap_yields > 0`) is
    // structurally unreachable on this workload — a positional frame ledger
    // never forms. Pin its absence, and pin the amendment's replacement
    // witness instead: the base-case sibling handoff must FOLLOW its arm
    // rowlessly post-motion (`sibling_link_hits`), the exact seam whose
    // refusal degenerated fib before the amendment (pops 32 vs 3.6M).
    try testing.expectEqual(@as(u64, 0), vm.trace.frame_link_cap_yields);
    try testing.expect(vm.trace.sibling_link_hits > 0);
}

test "D12c fused calls survive changed return types and protected overflow across ten legs" {
    try util.expectProgramTuned(
        \\local leaf = 1
        \\local function fib(n)
        \\  if n < 2 then return leaf end
        \\  return fib(n-2) + fib(n-1)
        \\end
        \\print(fib(16))
        \\leaf = 1.5
        \\print(fib(10))
        \\leaf = 1
        \\-- The FIRST n-2 descent must exceed the 200-frame wall before a leaf.
        \\-- 300 reaches a leaf first and starts exponential work, not a quick overflow.
        \\local ok, err = pcall(fib, 1000)
        \\print(ok, type(err))
        \\print(fib(10))
    , "1597\n133.5\nfalse\tstring\n89\n", .{
        .hotguard = 2,
        .inspect = &struct {
            fn inspect(vm: *Vm, mode: util.TraceMode) !void {
                if (mode != .record_execute_native or vm.heap.gc_stress or
                    !@import("nativegen.zig").is_x64_linux) return;
                try testing.expect(vm.trace.ret_cont_link_hits > 0);
                try testing.expect(vm.trace.call_head_link_hits > 0);
                // Doc 54 P2 (as amended): row-free chains never build the
                // positional frame ledger, so the capacity-cut witness is
                // structurally dead; the rowless sibling hop replaces it.
                try testing.expect(vm.trace.sibling_link_hits > 0);
            }
        }.inspect,
    });
}

// (The doc 44 D12c "pop helper refusal matrix" test lived here. Doc 54 P1
// deleted `nativeSelfRetPop`, so the matrix's walls now live as: emit-time
// statics (an ineligible page emits no pop epilogue — pinned by the
// fail-closed test above), the per-episode descent byte (its own unit
// matrix above), the inline net floor / ceiling / wiring walls (pinned by
// the formation witness plus the escaping-closure test below), and the
// frame-identity walls, which became jit-debug assert-callout invariants
// (`nativeFrameMotionAssert`, exercised on every pop of every jit-debug
// gate run).)

test "P2 amendment: two-sibling post-motion hop cycle stays bounded and byte-identical" {
    // The amendment's adversarial shape: a recursive body with a 2-way value
    // branch grows sibling pages whose armed handoffs point at each other
    // (D12a arms both directions). Post-motion, a deopt at either branch
    // guard now FOLLOWS its sibling arm rowlessly — and when the hopped-to
    // sibling immediately deopts back, `sibling_hop_taken` (already 1, no
    // committed motion between) forces the second hop into the refusal
    // bounce: at most ONE hidden hop between committed frame motions, so a
    // zero-progress ping-pong degenerates to the pre-amendment refusal
    // price instead of burning the 65,536 descent budget invisibly. The
    // pinned property is the semantic one — byte-identical output across
    // the whole mode matrix with alternating-parity inputs keeping both
    // siblings hot (a budget-burn bug shows up as the jit legs disagreeing
    // or the runtime-safety panics firing).
    try util.expectProgramTuned(
        \\local function f(n)
        \\  if n < 1 then return 0 end
        \\  if n % 2 == 0 then return f(n-1) + 1 end
        \\  return f(n-2) + 2
        \\end
        \\local acc = 0
        \\for i = 1, 40 do acc = acc + f(i) end
        \\print(acc)
    , "860\n", .{ .hotguard = 2 });
}

test "P2 amendment: three-sibling divergence chain pays one boundary and stays byte-identical" {
    // The legitimate divergence shape from the amendment: three recursion
    // paths (n%3) grow up to three sibling pages at the same anchor. A
    // post-motion chain A→B→C pays a dispatcher boundary at the refused
    // B→C hop (the one-hop window is consumed by A→B); whether C is
    // entered next is the ordinary exact-anchor walk's decision in a fresh
    // episode — an accepted trade-off of the conservative v1 bound, never
    // a semantic cost. Cycling i through all three residues keeps every
    // sibling live; the mode matrix pins byte-identical output.
    try util.expectProgramTuned(
        \\local function f(n)
        \\  if n < 1 then return 0 end
        \\  local m = n % 3
        \\  if m == 0 then return f(n-1) + 1 end
        \\  if m == 1 then return f(n-2) + 2 end
        \\  return f(n-3) + 3
        \\end
        \\local acc = 0
        \\for i = 1, 60 do acc = acc + f(i) end
        \\print(acc)
    , "1890\n", .{ .hotguard = 2 });
}

test "P2 amendment: episode gen saturation fails closed (descent dead, no publication)" {
    // Codex round-2 blocker pin: `episode_gen` SATURATES at maxInt(u64) —
    // skip-0-on-wrap was rejected because every nonzero generation is
    // eventually reused, and an ancient record stamped `gen = k` would
    // falsely match a reused `episode_gen = k`, silently skipping the
    // counter reset/touched publication. At saturation the descent gate
    // must be permanently dead: `descent_ok == 0` means no frame-motion
    // sequence commits, `frame_motion_taken` never sets, and therefore no
    // rowless follow and no counter publication can ever occur again for
    // this VM. The emitted paths already consult the descent byte, so the
    // Zig-level contract under test here (advance-first, saturate, fold
    // into `descent_ok`, reset `touched_len`) is the whole mechanism.
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    // Vm.init installed the real per-VM ctx; drive IT (registry owns it).
    const ctx = vm.trace.registry.native_seed_ctx.?;
    // prepareNativeEpisode reads frames[depth-1].call_seq; give it a live
    // anchor frame. The closure/proto pointers are stored, never followed.
    vm.depth = 1;
    vm.frames[0].call_seq = 1;
    var dummy_closure: function.Closure = undefined;
    var dummy_proto: bytecode.Proto = undefined;
    const max = std.math.maxInt(u64);
    // Two steps below saturation: a normal episode — gen advances, the
    // gate opens (fresh VM: receipts inert, no pending reg-top, no final
    // cut), touched list empty.
    ctx.episode_gen = max - 2;
    ctx.touched_len = 7; // stale garbage the prepare must clear
    vm.prepareNativeEpisode(&dummy_closure, &dummy_proto, 0);
    try testing.expectEqual(max - 1, ctx.episode_gen);
    try testing.expectEqual(@as(u8, 1), ctx.descent_ok);
    try testing.expectEqual(@as(usize, 0), ctx.touched_len);
    // The step INTO saturation: advance-first (round-3 pin), so this very
    // episode already sees the dead gate — never a one-episode window
    // where gen == maxInt with an open gate.
    vm.prepareNativeEpisode(&dummy_closure, &dummy_proto, 0);
    try testing.expectEqual(max, ctx.episode_gen);
    try testing.expectEqual(@as(u8, 0), ctx.descent_ok);
    try testing.expectEqual(@as(usize, 0), ctx.touched_len);
    // Saturated forever: the gen stops moving (no wrap to the cold
    // sentinel 0, no reuse of live generations) and the gate stays dead.
    vm.prepareNativeEpisode(&dummy_closure, &dummy_proto, 0);
    try testing.expectEqual(max, ctx.episode_gen);
    try testing.expectEqual(@as(u8, 0), ctx.descent_ok);
    try testing.expectEqual(@as(usize, 0), ctx.touched_len);
}

test "inline pop ceiling (doc 54 P1): escaping closures over recursion frames stay correct across legs" {
    // A leaf that mints a closure over its own `n` leaves an OPEN upvalue
    // above the popping window. The ceiling wall must decline the inline
    // pop there (tier-0's opRet closes the cell properly); a stale-LOW
    // ceiling — the one unsound direction — would pop natively WITHOUT
    // closing, and every stored closure would read a dead slot: the second
    // printed sum is the sabotage-sensitive witness. f(14) = 610 leaves,
    // 377 of them with n == 1 (fib partition), so the sums are 610 / 377.
    try util.expectProgramTuned(
        \\local cells = {}
        \\local ncells = 0
        \\local function f(n)
        \\  if n < 2 then
        \\    ncells = ncells + 1
        \\    cells[ncells] = function() return n end
        \\    return 1
        \\  end
        \\  return f(n-2) + f(n-1)
        \\end
        \\print(f(14))
        \\local s = 0
        \\for i = 1, ncells do s = s + cells[i]() end
        \\print(s)
    , "610\n377\n", .{
        .hotguard = 2,
        .inspect = &struct {
            fn inspect(vm: *Vm, mode: util.TraceMode) !void {
                // Program end: every leaf cell was closed on its frame's
                // exit, so the exact recompute has returned the watermark
                // to zero — the maintenance stays coherent end to end.
                try testing.expectEqual(@as(usize, 0), vm.open_upvalue_ceiling);
                if (mode != .record_execute_native or vm.heap.gc_stress or
                    !@import("nativegen.zig").is_x64_linux) return;
                // The hot recursive branch still descends natively (the
                // closure mint sits on the leaf side exit, not the head
                // page's hot path).
                try testing.expect(vm.trace.self_call_pushes > 0);
            }
        }.inspect,
    });
}

test "recorder (head, doc 44 P0): a depth-0 multret-forwarding return aborts — no head trace" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    // `return g()` forwards ALL results: `multret_top` is dynamic VM state the
    // trace never maintains, so the head close refuses it (abort, gate strike).
    // Only four `f` entries, so `g`'s own counter (3 counted entries — the one
    // during recording is skipped) never goes hot and can't pollute the cache.
    var chunk = try runForHeadTrace(&vm, gpa,
        \\local function g() return 1, 2 end
        \\local function f() return g() end
        \\f() f() f() f()
        \\print("done")
    );
    defer chunk.deinit();

    try testing.expectEqual(@as(usize, 0), vm.trace.registry.cache.items.len);
    try testing.expect(vm.trace.record_gate.count() >= 1);
    try testing.expect(!vm.trace.isRecording());
}

// ---------------------------------------------------------------------------
// Doc 45 D2: deterministic re-recording — the `.needs_precise` cancel/retry.
// ---------------------------------------------------------------------------

test "recorder (precise deopt, doc 45 D2): new_table cancels needs_precise ONCE, then the precise retry re-arms at the SAME loop anchor (not blacklisted)" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    vm.trace.config.record_aborts = true; // read the cancel/retry sequence below
    // A hot loop whose body constructs a table. First recording is non-precise
    // → `new_table` cancels `.needs_precise` (no gate strike, anchor memoized,
    // counter rewound to hotloop-1 so the retry arms on the very next
    // back-edge). The retry arms with `rec.precise` and — since increment 5 —
    // records the construction itself as `tnew`, then dies one bytecode LATER
    // at `t.x = i` (an absent-key hash insert, `.bad_type` — inserts stay out
    // of scope), striking the gate normally. Net: exactly one non-penalized
    // retry that provably got PAST the construction, then today's behaviour.
    var chunk = try runForTrace(&vm, gpa,
        \\local s = 0
        \\for i = 1, 400 do
        \\  local t = {}
        \\  t.x = i
        \\  s = s + t.x
        \\end
        \\print(s)
    , true);
    defer chunk.deinit();

    // Nothing commits (the insert aborts every precise retry).
    try testing.expectEqual(@as(usize, 0), vm.trace.registry.cache.items.len);

    // The abort log carries the transition: one `.needs_precise` row on
    // `new_table`, and at least one retry row at the SAME anchor that aborted
    // PAST the construction (`set_field`, `.bad_type`) — the retry
    // re-recorded from the real loop anchor (not blacklisted) and `tnew`
    // recording carried it through the `new_table` bytecode.
    var cancel_row: ?trace.AbortRecord = null;
    var retry_row: ?trace.AbortRecord = null;
    for (vm.trace.abort_log.items) |r| {
        if (r.op == .new_table and r.reason == .needs_precise) {
            try testing.expect(cancel_row == null); // deduped: one row
            cancel_row = r;
        }
        if (r.op == .set_field and r.reason == .bad_type) retry_row = r;
        // The old pre-increment-5 outcome must be gone: no precise retry
        // ever aborts ON the construction bytecode again.
        try testing.expect(!(r.op == .new_table and r.reason == .nyi_opcode));
    }
    try testing.expect(cancel_row != null);
    try testing.expect(retry_row != null);
    try testing.expectEqual(@as(u64, 1), cancel_row.?.count); // memo held: cancelled exactly once
    try testing.expectEqual(cancel_row.?.anchor_pc, retry_row.?.anchor_pc);
    // The retry died STRICTLY PAST the construction bytecode...
    try testing.expect(retry_row.?.abort_pc > cancel_row.?.abort_pc);
    // ...and its partial trace is strictly longer: the precise entry-load +
    // eager-`guard_gc` prologue plus the recorded `tnew` itself — the
    // observable signature of the precise re-arm reaching further.
    try testing.expect(retry_row.?.ir_len > cancel_row.?.ir_len);

    // Policy state: the anchor is memoized for precise mode, and the nyi
    // retry struck the record gate normally (ordinary strikes resumed — the
    // cancel is non-penalizing, not ungated-forever).
    const anchor = trace.AnchorKey{ .proto = cancel_row.?.proto, .pc = cancel_row.?.anchor_pc, .proto_id = cancel_row.?.proto.id };
    try testing.expect(vm.trace.precise_anchor_memo.contains(anchor));
    try testing.expect(vm.trace.record_gate.count() >= 1);
    try testing.expect(!vm.trace.isRecording());
}

test "recorder (precise deopt, doc 45 D2): a pre-seeded precise loop commits a full-window snapshot per body bytecode" {
    const gpa = testing.allocator;
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    var vm = try Vm.init(gpa);
    defer vm.deinit();

    // Pure int arithmetic — records cleanly, no new_table/store to abort in
    // precise mode — so pre-seeding its anchor into `precise_anchor_memo`
    // makes the FIRST recording arm precise and COMMIT a precise trace we can
    // dissect. (Execution is declined for precise traces this increment; the
    // commit + snapshot metadata is the substrate under test.)
    const source: [:0]const u8 =
        \\local s = 0
        \\for i = 1, 400 do s = s + i * 2 end
        \\print(s)
    ;
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();
    vm.trace.config.enabled = true;
    vm.trace.config.execute = false; // inspect recording in isolation
    vm.trace.config.optimize = false;
    vm.trace.config.hotloop = 4;
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;
    var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());

    // Seed every pc into the precise memo: only the real loop anchor's
    // counter ever crosses, so `arm()` consults exactly one and records this
    // loop precise. (Robust against the exact back-edge-target pc encoding.)
    var pc: u32 = 0;
    while (pc < chunk.proto.code.len) : (pc += 1)
        try vm.trace.precise_anchor_memo.put(gpa, .{ .proto = chunk.proto, .pc = pc, .proto_id = chunk.proto.id }, .{});

    _ = try vm.run(chunk.proto);

    // A precise trace committed at the anchor.
    try testing.expectEqual(@as(usize, 1), vm.trace.registry.cache.items.len);
    const t = vm.trace.registry.cache.items[0];
    try testing.expectEqual(trace_snapshot.DeoptMode.precise, t.code.deopt_mode);
    try testing.expect(t.code.snapshots.len > 0);

    // Structural validity + full-window shape (register_count == num_registers,
    // every slot present ascending, resume_pc in range) — the same predicate
    // finalization enforced.
    try testing.expect(trace_snapshot.validate(t.code.snapshots, t.code.snapshot_slots, @intCast(chunk.proto.code.len)));
    const nregs = chunk.proto.num_registers;
    for (t.code.snapshots) |snap| {
        try testing.expectEqual(nregs, snap.register_count);
        try testing.expectEqual(@as(u32, nregs), snap.slots_len);
        try testing.expect(snap.resume_pc < chunk.proto.code.len);
    }

    // Every potentially-failing BODY op carries a nonzero snap; the entry
    // prologue (slot_loads + the eager guard_gc) carries snap == 0. Locate the
    // guard_gc: everything at/before it is prologue, everything after is body.
    var gc_idx: ?usize = null;
    for (t.code.instrs, 0..) |ins, i| {
        if (ins.op == .guard_gc) gc_idx = i;
    }
    try testing.expect(gc_idx != null);
    try testing.expectEqual(@as(i32, 0), t.code.instrs[gc_idx.?].aux); // nonallocating body: aux==0 legal
    for (t.code.instrs[0 .. gc_idx.? + 1]) |ins| {
        try testing.expectEqual(@as(trace_ir.SnapIdx, 0), ins.snap); // prologue = entry replay
    }
    var body_guard_snaps: usize = 0;
    for (t.code.instrs[gc_idx.? + 1 ..], gc_idx.? + 1..) |ins, i| {
        if (trace_ir.isSideExitGuardOp(ins.op)) {
            try testing.expect(ins.snap != 0);
            // The captured refs are all defined before this use site.
            try testing.expect(trace_snapshot.refsDefinedAt(ins.snap, i, t.code.snapshots, t.code.snapshot_slots));
            body_guard_snaps += 1;
        }
    }
    try testing.expect(body_guard_snaps > 0);
}

test "executor (precise deopt, doc 45 D6): a mid-body guard failure precise-resumes on tier-1a and matches pure tier-0 output" {
    const gpa = testing.allocator;
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");

    // A value-lane array read whose element guard fails MID-LOOP (a[200] is a
    // float in an otherwise-int array): the recorded precise trace runs its
    // steady state on tier-1a, then the element guard fails mid-iteration and
    // the dispatcher must resume tier-0 at the snapshot's resume_pc — regs
    // restored to mid-iteration state — never at the anchor and never via a
    // sibling trial. The first loop (astore) never traces precise (stores are
    // refused this phase); only the read loop is under test.
    const source: [:0]const u8 =
        \\local a = {}
        \\for i = 1, 300 do a[i] = i end
        \\a[200] = 1.5
        \\local s = 0
        \\for i = 1, 300 do s = s + a[i] end
        \\print(s)
    ;

    // Tier-0 truth first.
    var truth: [64]u8 = undefined;
    var truth_len: usize = 0;
    {
        var vm = try Vm.init(gpa);
        defer vm.deinit();
        var diags = diag.Diagnostics.init(gpa);
        defer diags.deinit();
        var tree = try parser.parse(gpa, source, &diags);
        defer tree.deinit();
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

    // Precise-executing run: pre-seed every pc into the memo so the read
    // loop's first recording arms precise, and let tier-1a ENTER it.
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();
    vm.trace.config.enabled = true;
    vm.trace.config.execute = true;
    vm.trace.config.optimize = false;
    vm.trace.config.hotloop = 4;
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;
    var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    var pc: u32 = 0;
    while (pc < chunk.proto.code.len) : (pc += 1)
        try vm.trace.precise_anchor_memo.put(gpa, .{ .proto = chunk.proto, .pc = pc, .proto_id = chunk.proto.id }, .{});

    _ = try vm.run(chunk.proto);

    // Output identity is necessary but not sufficient (for a pure body,
    // entry replay is observationally equivalent) — the witness counter
    // proves the precise restore path actually fired.
    try testing.expectEqualStrings(truth[0..truth_len], sink.buffered());
    try testing.expect(vm.trace.precise_resumes >= 1);
    // And the entered trace really was precise.
    var saw_precise = false;
    for (vm.trace.registry.cache.items) |ct| {
        if (ct.code.deopt_mode == .precise) saw_precise = true;
    }
    try testing.expect(saw_precise);
}

test "executor (precise deopt, doc 45 D6): the snapshot restore writes mid-iteration values into the guest registers" {
    const gpa = testing.allocator;
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    var vm = try Vm.init(gpa);
    defer vm.deinit();

    // `x = i + 10` writes a register BEFORE `x // d` can fail — the arith
    // failure's snapshot must restore x's MID-ITERATION value (the doc 45 D2
    // boundary contract: completed instruction results only, resumed at the
    // failing bytecode). Recording runs with d == 1 (no failure); the direct
    // executor call below re-enters with a crafted d == 0.
    const source: [:0]const u8 =
        \\local d = 1
        \\local s = 0
        \\for i = 1, 400 do
        \\  local x = i + 10
        \\  s = s + x // d
        \\end
        \\print(s)
    ;
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();
    vm.trace.config.enabled = true;
    vm.trace.config.execute = false; // keep the committed trace un-entered
    vm.trace.config.optimize = false;
    vm.trace.config.hotloop = 4;
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;
    var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    var pc: u32 = 0;
    while (pc < chunk.proto.code.len) : (pc += 1)
        try vm.trace.precise_anchor_memo.put(gpa, .{ .proto = chunk.proto, .pc = pc, .proto_id = chunk.proto.id }, .{});
    _ = try vm.run(chunk.proto);

    try testing.expectEqual(@as(usize, 1), vm.trace.registry.cache.items.len);
    const t = &vm.trace.registry.cache.items[0].code;
    try testing.expectEqual(trace_snapshot.DeoptMode.precise, t.deopt_mode);

    // Structural slot discovery — no hardcoded compiler layout. The `//`
    // lowers to `.idiv`; its divisor ref is d's entry `slot_load` (d never
    // changes in the loop, dupe-path indices are identity).
    var idiv_idx: ?usize = null;
    for (t.instrs, 0..) |ins, i| {
        if (ins.op == .idiv) idiv_idx = i;
    }
    try testing.expect(idiv_idx != null);
    const div_b = t.instrs[idiv_idx.?].b;
    try testing.expectEqual(trace_ir.IrOp.slot_load, t.instrs[div_b].op);
    const d_slot: usize = @intCast(t.instrs[div_b].aux);
    // The numeric-for control base from the bytecode.
    var for_base: ?usize = null;
    for (chunk.proto.code) |ins| {
        if (ins.op == .for_prep) for_base = ins.a;
    }
    try testing.expect(for_base != null);
    const base = for_base.?;

    // Craft a coherent anchor-entry state. The loop anchor's entry contract
    // is POST-for_loop: `i` already holds the current iteration's value (the
    // recorded body uses it directly; the increment + done guard sit at the
    // body's END, LuaJIT-style). With i == 7 this iteration computes
    // x == 17, then divides by the crafted d == 0 and fails mid-body.
    const nregs: usize = chunk.proto.num_registers;
    const regs = try gpa.alloc(Value, nregs);
    defer gpa.free(regs);
    for (regs) |*r| r.* = Value.int(1);
    regs[base] = Value.int(7); // control index (current iteration)
    regs[base + 1] = Value.int(400); // limit
    regs[base + 2] = Value.int(1); // step
    regs[base + 3] = Value.int(7); // visible i
    regs[d_slot] = Value.int(0); // divide-by-zero mid-body
    const entry = try gpa.dupe(Value, regs);
    defer gpa.free(entry);

    const values = try gpa.alloc(Value, t.instrs.len);
    defer gpa.free(values);
    const result = irinterp.executeValuesCtx(.{ .heap = vm.heap }, t, regs, values);

    // The failing op is the idiv, at iteration 0, and the exit is a precise
    // resume carrying that op's one-based snapshot.
    try testing.expectEqual(@as(usize, 0), result.completed);
    try testing.expectEqual(trace_exec.ExitReason.precise_resume, result.exit_reason);
    try testing.expectEqual(@as(usize, idiv_idx.?), @as(usize, result.exit_instr));
    try testing.expect(result.snapshot_id != 0);
    try testing.expectEqual(t.instrs[idiv_idx.?].snap, result.snapshot_id);
    const snap = t.snapshots[result.snapshot_id - 1];
    try testing.expect(snap.resume_pc < chunk.proto.code.len);

    // Restored registers: x holds 17 — a value computed THIS iteration,
    // before the failure — the proof the restore wrote mid-iteration state
    // rather than leaving entry state or applying a φ flush. The other
    // changed slots are the compiler's operand-alias temps (bytecode moves
    // alias the recorder's reg_map, so their captured refs are the same
    // this-iteration values): a copy of i (7), of d (0), of x (17). Nothing
    // outside that envelope may change; in particular the loop controls are
    // untouched (the increment lives at the body's END and never ran) and s
    // keeps its entry value (the add after the div never executed).
    var saw_x = false;
    var diffs: usize = 0;
    for (regs, entry) |after, before| {
        if (after.eql(before)) continue;
        diffs += 1;
        try testing.expect(after.eql(Value.int(17)) or after.eql(Value.int(7)) or after.eql(Value.int(0)));
        if (after.eql(Value.int(17))) saw_x = true;
    }
    try testing.expect(diffs >= 1);
    try testing.expect(saw_x);
    try testing.expect(regs[base].eql(Value.int(7)));
    try testing.expect(regs[base + 1].eql(Value.int(400)));
    try testing.expect(regs[base + 2].eql(Value.int(1)));
    try testing.expect(regs[base + 3].eql(Value.int(7)));
}

test "executor (tnew, doc 45 D3): a pure construction loop commits precise, executes on tier-1a, and allocates exactly once per iteration" {
    const gpa = testing.allocator;
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");

    // The money shape for the whole increment: `local t = {}` per iteration.
    // The FIRST recording cancels `.needs_precise`; the natural retry arms
    // precise (no memo pre-seeding here — the full cancel/re-arm/commit/
    // execute pipeline is under test), records `tnew`, commits, and tier-1a
    // runs the loop. Identity bar: output, `next_obj_id` (a monotonic count
    // of every allocation ever — the exactly-once witness: a re-run of any
    // iteration's `tnew`, e.g. across the final loop-done deopt, would
    // advance it extra) and `object_count` must all match pure tier-0.
    const source: [:0]const u8 =
        \\local n = 0
        \\for i = 1, 400 do
        \\  local t = {}
        \\  n = n + 1
        \\end
        \\print(n)
    ;

    // Tier-0 truth.
    var truth: [64]u8 = undefined;
    var truth_len: usize = 0;
    var truth_next_id: u32 = 0;
    var truth_obj_count: usize = 0;
    {
        var vm = try Vm.init(gpa);
        defer vm.deinit();
        var diags = diag.Diagnostics.init(gpa);
        defer diags.deinit();
        var tree = try parser.parse(gpa, source, &diags);
        defer tree.deinit();
        var buf: [64]u8 = undefined;
        var sink = io.Writer.fixed(&buf);
        vm.out = &sink;
        var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
        defer chunk.deinit();
        try testing.expect(!diags.hasErrors());
        _ = try vm.run(chunk.proto);
        truth_len = sink.buffered().len;
        @memcpy(truth[0..truth_len], sink.buffered());
        truth_next_id = vm.heap.next_obj_id;
        truth_obj_count = vm.heap.object_count;
    }

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();
    vm.trace.config.enabled = true;
    vm.trace.config.execute = true;
    vm.trace.config.optimize = false;
    vm.trace.config.hotloop = 4;
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;
    var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    _ = try vm.run(chunk.proto);

    try testing.expectEqualStrings(truth[0..truth_len], sink.buffered());
    try testing.expectEqual(truth_next_id, vm.heap.next_obj_id);
    try testing.expectEqual(truth_obj_count, vm.heap.object_count);

    // A precise trace committed carrying the construction: exactly one
    // `tnew`, routed through `emitAlloc` — the eager `guard_gc`'s stamped
    // bound is exactly 1 — and every fallible body op snapshot-stamped.
    var money: ?*const trace.Trace = null;
    for (vm.trace.registry.cache.items) |ct| {
        for (ct.code.instrs) |ins| {
            if (ins.op == .tnew) money = ct;
        }
    }
    try testing.expect(money != null);
    const t = &money.?.code;
    try testing.expectEqual(trace_snapshot.DeoptMode.precise, t.deopt_mode);
    var tnew_count: usize = 0;
    var gc_aux: ?i32 = null;
    for (t.instrs) |ins| {
        if (ins.op == .tnew) {
            tnew_count += 1;
            try testing.expect(ins.snap > 0); // requiresPreciseSnapshot held
        }
        if (ins.op == .guard_gc) gc_aux = ins.aux;
    }
    try testing.expectEqual(@as(usize, 1), tnew_count);
    try testing.expectEqual(@as(i32, 1), gc_aux.?);
    // The loop-done exit of a precise dupe-path trace is a body guard with a
    // snapshot — the run's clean completions surface as precise resumes.
    try testing.expect(vm.trace.precise_resumes >= 1);
}

test "executor (tnew OOM, doc 45 D5): a one-shot allocation failure exits precise_error with restored registers and zero heap effect" {
    const gpa = testing.allocator;
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    const table_runtime = @import("table_runtime.zig");
    var vm = try Vm.init(gpa);
    defer vm.deinit();

    const source: [:0]const u8 =
        \\local n = 0
        \\for i = 1, 400 do
        \\  local t = {}
        \\  n = n + 1
        \\end
        \\print(n)
    ;
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();
    vm.trace.config.enabled = true;
    vm.trace.config.execute = false; // keep the committed trace un-entered
    vm.trace.config.optimize = false;
    vm.trace.config.hotloop = 4;
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;
    var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    var pcs: u32 = 0;
    while (pcs < chunk.proto.code.len) : (pcs += 1)
        try vm.trace.precise_anchor_memo.put(gpa, .{ .proto = chunk.proto, .pc = pcs, .proto_id = chunk.proto.id }, .{});
    _ = try vm.run(chunk.proto);

    try testing.expectEqual(@as(usize, 1), vm.trace.registry.cache.items.len);
    const t = &vm.trace.registry.cache.items[0].code;
    try testing.expectEqual(trace_snapshot.DeoptMode.precise, t.deopt_mode);
    var tnew_idx: ?usize = null;
    for (t.instrs, 0..) |ins, i| {
        if (ins.op == .tnew) tnew_idx = i;
    }
    try testing.expect(tnew_idx != null);

    // Coherent anchor-entry state (POST-for_loop contract), limit 20 so the
    // success run below stays far under the GC trigger.
    var for_base: ?usize = null;
    for (chunk.proto.code) |ins| {
        if (ins.op == .for_prep) for_base = ins.a;
    }
    try testing.expect(for_base != null);
    const base = for_base.?;
    const nregs: usize = chunk.proto.num_registers;
    const regs = try gpa.alloc(Value, nregs);
    defer gpa.free(regs);
    for (regs) |*r| r.* = Value.int(1);
    regs[base] = Value.int(7); // control index (current iteration)
    regs[base + 1] = Value.int(20); // limit
    regs[base + 2] = Value.int(1); // step
    regs[base + 3] = Value.int(7); // visible i
    const entry = try gpa.dupe(Value, regs);
    defer gpa.free(entry);
    const values = try gpa.alloc(Value, t.instrs.len);
    defer gpa.free(values);
    vm.heap.next_gc = 1_000_000; // keep guard_gc out of the way

    // One-shot failing allocator over the heap's real gpa: the FIRST heap
    // allocation attempt (this iteration's `tnew`) fails.
    const FailNth = struct {
        inner: std.mem.Allocator,
        fail_at: usize, // 1-based allocation call that fails; others forward
        count: usize = 0,
        const VT = std.mem.Allocator.VTable{ .alloc = allocFn, .resize = resizeFn, .remap = remapFn, .free = freeFn };
        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &VT };
        }
        fn allocFn(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.count += 1;
            if (self.count == self.fail_at) return null;
            return self.inner.vtable.alloc(self.inner.ptr, len, alignment, ret_addr);
        }
        fn resizeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.inner.vtable.resize(self.inner.ptr, memory, alignment, new_len, ret_addr);
        }
        fn remapFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.inner.vtable.remap(self.inner.ptr, memory, alignment, new_len, ret_addr);
        }
        fn freeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.inner.vtable.free(self.inner.ptr, memory, alignment, ret_addr);
        }
    };
    var failing = FailNth{ .inner = vm.heap.gpa, .fail_at = 1 };
    const real_gpa = vm.heap.gpa;
    vm.heap.gpa = failing.allocator();
    const id_before = vm.heap.next_obj_id;
    const count_before = vm.heap.object_count;
    const oom = irinterp.executeValuesCtx(.{ .heap = vm.heap }, t, regs, values);
    vm.heap.gpa = real_gpa;

    // D5: the failing `tnew` performed NOTHING — no object linked, no id
    // consumed — and the exit carries the op's snapshot with the shim's
    // status; the registers are the exact pre-instruction (== entry, nothing
    // was written yet this iteration) state.
    try testing.expectEqual(@as(usize, 0), oom.completed);
    try testing.expectEqual(trace_exec.ExitReason.precise_error, oom.exit_reason);
    try testing.expectEqual(@as(u32, @intFromEnum(table_runtime.Status.out_of_memory)), oom.runtime_error);
    try testing.expectEqual(@as(usize, tnew_idx.?), @as(usize, oom.exit_instr));
    try testing.expectEqual(t.instrs[tnew_idx.?].snap, oom.snapshot_id);
    try testing.expectEqual(@as(u32, 0), oom.activation_base);
    try testing.expectEqual(@as(u32, 0), oom.activation_depth);
    try testing.expectEqual(id_before, vm.heap.next_obj_id);
    try testing.expectEqual(count_before, vm.heap.object_count);
    for (regs, entry) |after, before| try testing.expect(after.eql(before));

    // Same entry against the REAL heap: i = 7..20 is 14 iterations, each
    // allocating exactly one table — the executor-level exactly-once count.
    @memcpy(regs, entry);
    const ok = irinterp.executeValuesCtx(.{ .heap = vm.heap }, t, regs, values);
    try testing.expectEqual(trace_exec.ExitReason.precise_resume, ok.exit_reason);
    try testing.expectEqual(@as(u32, 14), vm.heap.next_obj_id - id_before);
    try testing.expectEqual(@as(usize, 14), vm.heap.object_count - count_before);
}

test "pipeline (tnew OOM, doc 45 D5): a mid-execution heap OOM raises identically to tier-0 through the precise_error path" {
    const gpa = testing.allocator;
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");

    const source: [:0]const u8 =
        \\local n = 0
        \\for i = 1, 400 do
        \\  local t = {}
        \\  n = n + 1
        \\end
        \\print(n)
    ;

    // The K-th allocation THROUGH THE HEAP fails (guest allocations only —
    // the trace machinery holds its own copy of the VM allocator, so the
    // swap below never sees it). K = 150 lands mid-loop, well after the
    // precise trace commits (~iteration 10 at hotloop 4), so tier-1a is
    // executing when the OOM hits — the guest-visible outcome must be
    // byte-identical to tier-0 dying at the same allocation.
    const FailNth = struct {
        inner: std.mem.Allocator,
        fail_at: usize,
        count: usize = 0,
        const VT = std.mem.Allocator.VTable{ .alloc = allocFn, .resize = resizeFn, .remap = remapFn, .free = freeFn };
        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &VT };
        }
        fn allocFn(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.count += 1;
            if (self.count == self.fail_at) return null;
            return self.inner.vtable.alloc(self.inner.ptr, len, alignment, ret_addr);
        }
        fn resizeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.inner.vtable.resize(self.inner.ptr, memory, alignment, new_len, ret_addr);
        }
        fn remapFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.inner.vtable.remap(self.inner.ptr, memory, alignment, new_len, ret_addr);
        }
        fn freeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.inner.vtable.free(self.inner.ptr, memory, alignment, ret_addr);
        }
    };
    const K: usize = 150;

    // Tier-0 truth under the same failure schedule.
    var truth_next_id: u32 = 0;
    var truth_obj_count: usize = 0;
    var truth_parked_pc: usize = 0;
    {
        var vm = try Vm.init(gpa);
        defer vm.deinit();
        var diags = diag.Diagnostics.init(gpa);
        defer diags.deinit();
        var tree = try parser.parse(gpa, source, &diags);
        defer tree.deinit();
        var buf: [64]u8 = undefined;
        var sink = io.Writer.fixed(&buf);
        vm.out = &sink;
        var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
        defer chunk.deinit();
        try testing.expect(!diags.hasErrors());
        var failing = FailNth{ .inner = vm.heap.gpa, .fail_at = K };
        vm.heap.gpa = failing.allocator();
        try testing.expectError(interp.Error.OutOfMemory, vm.run(chunk.proto));
        vm.heap.gpa = failing.inner;
        try testing.expectEqual(@as(usize, 0), sink.buffered().len); // died pre-print
        truth_next_id = vm.heap.next_obj_id;
        truth_obj_count = vm.heap.object_count;
        truth_parked_pc = vm.frames[0].pc;
    }

    // Traced run, same schedule: the OOM must surface as the SAME error with
    // the SAME partial heap (execute-once through `.precise_error` — a
    // double-run or a skip of any iteration's `tnew` shifts the failing
    // iteration and breaks the counts) and park at the SAME bytecode.
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();
    vm.trace.config.enabled = true;
    vm.trace.config.execute = true;
    vm.trace.config.optimize = false;
    vm.trace.config.hotloop = 4;
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;
    var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    var failing = FailNth{ .inner = vm.heap.gpa, .fail_at = K };
    vm.heap.gpa = failing.allocator();
    try testing.expectError(interp.Error.OutOfMemory, vm.run(chunk.proto));
    vm.heap.gpa = failing.inner;

    try testing.expectEqual(@as(usize, 0), sink.buffered().len);
    try testing.expectEqual(truth_next_id, vm.heap.next_obj_id);
    try testing.expectEqual(truth_obj_count, vm.heap.object_count);
    try testing.expectEqual(truth_parked_pc, vm.frames[0].pc);
    // The witness: the OOM was raised THROUGH the tier-1a precise_error
    // consumer (state identity alone can't distinguish "the trace never
    // entered and tier-0 OOM'd on its own").
    try testing.expectEqual(@as(u64, 1), vm.trace.precise_errors);
}

/// Doc 45 D5 for the string helpers (doc 63 Prerequisite A): a precise trace
/// whose allocating string helper (`tostr_*`, the snew class, `scap_str`)
/// fails must surface the one-shot allocation failure exactly like tier-0 —
/// through `.precise_error`, never by resuming tier-0 at the bytecode to
/// retry the allocation (the retry succeeds under a one-shot failure, so the
/// traced run would outlive tier-0). The `{}` in each loop makes the
/// recording precise.
const PreciseStrOom = struct {
    const tostr_source: [:0]const u8 =
        \\local n = 0
        \\for i = 1, 400 do
        \\  local t = {}
        \\  local s = tostring(i)
        \\  n = n + #s
        \\end
        \\print(n)
    ;

    /// One loop per helper; each iteration makes a string not seen before,
    /// so the helper allocates (an intern hit would not). The library
    /// functions are hoisted into locals: a `string.x` lookup in the body is
    /// a `get_index`, which precise recording does not support. Likewise a
    /// call nested as another call's last argument is a multret feed, so each
    /// result gets its own local.
    const Case = struct {
        name: []const u8,
        op: @import("trace_ir.zig").IrOp,
        source: [:0]const u8,
        /// The traced helper and tier-0's native make the same allocator
        /// calls (the ONE shared core), so the K-th call is the same logical
        /// allocation in both and the outcomes must match exactly. False when
        /// tier-0 reaches the result by another allocation path.
        same_schedule: bool,
    };
    const cases = [_]Case{
        .{ .name = "tostr_num", .op = .tostr_num, .same_schedule = true, .source =
        \\local tostr = tostring
        \\local n = 0
        \\for i = 1, 400 do
        \\  local t = {}
        \\  local s = tostr(i + 0.5)
        \\  n = n + #s
        \\end
        \\print(n)
        },
        .{ .name = "ssub", .op = .ssub, .same_schedule = true, .source =
        \\local sub = string.sub
        \\local big = string.rep("AbCdEfGhIj", 50)
        \\local n = 0
        \\for i = 1, 400 do
        \\  local t = {}
        \\  local s = sub(big, 1, i)
        \\  n = n + #s
        \\end
        \\print(n)
        },
        .{ .name = "srev", .op = .srev, .same_schedule = true, .source =
        \\local sub, rev = string.sub, string.reverse
        \\local big = string.rep("AbCdEfGhIj", 50)
        \\local n = 0
        \\for i = 1, 400 do
        \\  local t = {}
        \\  local p = sub(big, 1, i)
        \\  local s = rev(p)
        \\  n = n + #s
        \\end
        \\print(n)
        },
        .{ .name = "srep2", .op = .srep2, .same_schedule = true, .source =
        \\local rep = string.rep
        \\local n = 0
        \\for i = 1, 400 do
        \\  local t = {}
        \\  local s = rep("ab", i)
        \\  n = n + #s
        \\end
        \\print(n)
        },
        .{ .name = "supper", .op = .supper, .same_schedule = true, .source =
        \\local sub, upper = string.sub, string.upper
        \\local big = string.rep("AbCdEfGhIj", 50)
        \\local n = 0
        \\for i = 1, 400 do
        \\  local t = {}
        \\  local p = sub(big, 1, i)
        \\  local s = upper(p)
        \\  n = n + #s
        \\end
        \\print(n)
        },
        .{ .name = "slower", .op = .slower, .same_schedule = true, .source =
        \\local sub, lower = string.sub, string.lower
        \\local big = string.rep("AbCdEfGhIj", 50)
        \\local n = 0
        \\for i = 1, 400 do
        \\  local t = {}
        \\  local p = sub(big, 1, i)
        \\  local s = lower(p)
        \\  n = n + #s
        \\end
        \\print(n)
        },
        .{ .name = "schar1", .op = .schar1, .same_schedule = false, .source =
        \\local char = string.char
        \\local n = 0
        \\for i = 1, 400 do
        \\  local t = {}
        \\  local s = char(0x4E00 + i)
        \\  n = n + #s
        \\end
        \\print(n)
        },
        .{ .name = "scap_str", .op = .scap_str, .same_schedule = false, .source =
        \\local sub, match = string.sub, string.match
        \\local big = string.rep("AbCdEfGhIj", 50)
        \\local n = 0
        \\for i = 1, 400 do
        \\  local t = {}
        \\  local p = sub(big, 1, i)
        \\  local s = match(p, "%a(%a*)")
        \\  n = n + #s
        \\end
        \\print(n)
        },
    };

    const FailNth = struct {
        inner: std.mem.Allocator,
        fail_at: usize,
        count: usize = 0,
        const VT = std.mem.Allocator.VTable{ .alloc = allocFn, .resize = resizeFn, .remap = remapFn, .free = freeFn };
        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &VT };
        }
        fn allocFn(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.count += 1;
            if (self.count == self.fail_at) return null;
            return self.inner.vtable.alloc(self.inner.ptr, len, alignment, ret_addr);
        }
        // In-place growth is refused, so every growth is a counted `alloc`.
        // Whether the backing allocator could grow a block in place depends
        // on its memory layout, which differs between the tier-0 and the
        // traced VM (the trace's own allocations share it). Counting only
        // `alloc` while forwarding `remap` made the schedule depend on that
        // layout, not on the VM: a `string.rep` scratch buffer grew in place
        // in one run and by a fresh allocation in the other.
        fn resizeFn(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
            return false;
        }
        fn remapFn(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
            return null;
        }
        fn freeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.inner.vtable.free(self.inner.ptr, memory, alignment, ret_addr);
        }
    };

    const Outcome = struct {
        oom: bool,
        /// The injected failure was reached (the run made ≥ `fail_at`
        /// allocator calls). Nothing in the VM retries an allocation, so a
        /// fired failure must end the run in OOM — in every tier.
        fired: bool,
        next_id: u32,
        obj_count: usize,
        parked_pc: usize,
        /// The run raised at the call to the helper under test — the
        /// source's last call before `print(n)` — not at the loop's
        /// `new_table` or an earlier feeding call.
        at_helper: bool,
        precise_errors: u64,
        native_entries: u64,
        /// Some committed trace contains the op under test.
        has_op: bool,
    };

    /// Pc of the call to the helper under test: every source ends with the
    /// loop then `print(n)`, so it is the second-to-last `call`.
    fn helperCallPc(code: []const @import("bytecode.zig").Instr) usize {
        var last: ?usize = null;
        var prev: ?usize = null;
        for (code, 0..) |ins, pc| {
            if (ins.op == .call) {
                prev = last;
                last = pc;
            }
        }
        return prev.?;
    }

    const Tier = enum { tier0, tier1a, native };

    fn run(gpa: std.mem.Allocator, source: [:0]const u8, op: @import("trace_ir.zig").IrOp, fail_at: usize, tier: Tier) !Outcome {
        const parser = @import("parser.zig");
        const diag = @import("diag.zig");
        var vm = try Vm.init(gpa);
        defer vm.deinit();
        var diags = diag.Diagnostics.init(gpa);
        defer diags.deinit();
        var tree = try parser.parse(gpa, source, &diags);
        defer tree.deinit();
        if (tier != .tier0) {
            vm.trace.config.enabled = true;
            vm.trace.config.execute = true;
            vm.trace.config.optimize = false;
            vm.trace.config.native_codegen = tier == .native;
            vm.trace.config.hotloop = 4;
        }
        var buf: [64]u8 = undefined;
        var sink = io.Writer.fixed(&buf);
        vm.out = &sink;
        var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
        defer chunk.deinit();
        try testing.expect(!diags.hasErrors());
        var failing = FailNth{ .inner = vm.heap.gpa, .fail_at = fail_at };
        vm.heap.gpa = failing.allocator();
        const res = vm.run(chunk.proto);
        vm.heap.gpa = failing.inner;
        const oom = if (res) |_| false else |e| blk: {
            try testing.expectEqual(interp.Error.OutOfMemory, e);
            break :blk true;
        };
        var has_op = false;
        for (vm.trace.registry.cache.items) |t| {
            for (t.code.instrs) |ins| {
                if (ins.op == op) has_op = true;
            }
        }
        return .{
            .oom = oom,
            .fired = failing.count >= fail_at,
            .next_id = vm.heap.next_obj_id,
            .obj_count = vm.heap.object_count,
            .parked_pc = vm.frames[0].pc,
            .at_helper = oom and vm.frames[0].pc == helperCallPc(chunk.proto.code),
            .precise_errors = vm.trace.precise_errors,
            .native_entries = vm.trace.native_entries,
            .has_op = has_op,
        };
    }

    /// Sweep the failure point across `window` consecutive mid-loop
    /// allocations from `lo` (after the precise trace commits), so it lands on
    /// both `tnew` and the string helper. A fired failure is never survived;
    /// with a shared allocation schedule every point also matches tier-0.
    /// Counts the runs raised through the precise_error consumer, and of
    /// those the ones whose failure was the helper under test itself.
    const Raised = struct { through_precise: usize = 0, at_helper: usize = 0 };

    fn sweep(source: [:0]const u8, op: @import("trace_ir.zig").IrOp, tier: Tier, same_schedule: bool, lo: usize, window: usize) !Raised {
        const gpa = testing.allocator;
        var raised: Raised = .{};
        for (lo..lo + window) |k| {
            const truth = try run(gpa, source, op, k, .tier0);
            const got = try run(gpa, source, op, k, tier);
            try testing.expect(truth.fired and truth.oom);
            try testing.expect(got.fired and got.oom);
            try testing.expect(got.has_op);
            if (same_schedule) {
                try testing.expectEqual(truth.next_id, got.next_id);
                try testing.expectEqual(truth.obj_count, got.obj_count);
                try testing.expectEqual(truth.parked_pc, got.parked_pc);
            }
            raised.through_precise += got.precise_errors;
            if (got.precise_errors != 0 and got.at_helper) raised.at_helper += 1;
            if (tier == .native and @import("nativegen.zig").is_x64_linux)
                try testing.expect(got.native_entries >= 1);
        }
        return raised;
    }

    fn checkTostr(tier: Tier) !void {
        // Every allocation in this window is a `tnew` or a `tostr_int`
        // intern, each raised through the precise_error consumer (never a
        // tier-0 retry).
        const raised = try sweep(tostr_source, .tostr_int, tier, true, 150, 20);
        try testing.expectEqual(@as(usize, 20), raised.through_precise);
        try testing.expect(raised.at_helper >= 1);
    }

    fn checkCase(c: Case, tier: Tier) !void {
        const raised = try sweep(c.source, c.op, tier, c.same_schedule, 150, 40);
        try testing.expect(raised.at_helper >= 1);
    }

    /// The native exit materializer flushes a helper's snapshot from the
    /// allocator's register/spill homes, which `operandReads` cannot see: the
    /// allocator must keep every captured ref live up to the helper, or the
    /// flush reads a recycled register. Checks the allocator's own
    /// `last_use` on each precise trace the source commits, and that the
    /// helper is one finalize and native admission require a snapshot for.
    /// Returns how many helper exits were checked.
    fn checkSnapshotLiveness(source: [:0]const u8) !usize {
        const gpa = testing.allocator;
        const parser = @import("parser.zig");
        const diag = @import("diag.zig");
        const nativegen = @import("nativegen.zig");
        var vm = try Vm.init(gpa);
        defer vm.deinit();
        var diags = diag.Diagnostics.init(gpa);
        defer diags.deinit();
        var tree = try parser.parse(gpa, source, &diags);
        defer tree.deinit();
        vm.trace.config.enabled = true;
        vm.trace.config.execute = true;
        vm.trace.config.optimize = false;
        vm.trace.config.native_codegen = true;
        vm.trace.config.hotloop = 4;
        var buf: [64]u8 = undefined;
        var sink = io.Writer.fixed(&buf);
        vm.out = &sink;
        var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
        defer chunk.deinit();
        try testing.expect(!diags.hasErrors());
        _ = try vm.run(chunk.proto);
        var checked: usize = 0;
        for (vm.trace.registry.cache.items) |tr| {
            const t = &tr.code;
            if (t.deopt_mode != .precise) continue;
            const kinds = try gpa.alloc(nativegen.Kind, t.instrs.len);
            defer gpa.free(kinds);
            const slot_of = try gpa.alloc(i32, t.instrs.len);
            defer gpa.free(slot_of);
            try testing.expect(nativegen.proveKinds(gpa, t, kinds, slot_of));
            var alloc = nativegen.analyze(gpa, t, kinds, slot_of) orelse return error.AnalyzeBailed;
            defer alloc.deinit(gpa);
            for (t.instrs, 0..) |ins, i| {
                if (!@import("nativegen_emit.zig").isStrAllocOp(ins.op)) continue;
                try testing.expect(trace_ir.requiresPreciseSnapshot(ins.op));
                try testing.expect(ins.snap != 0);
                const rec = t.snapshots[ins.snap - 1];
                for (t.snapshot_slots[rec.slots_begin..][0..rec.slots_len]) |ss| {
                    try testing.expect(alloc.last_use[ss.ref] >= i);
                }
                checked += 1;
            }
        }
        return checked;
    }

    /// Runs every case and names each failing one, so a regression shows
    /// its full extent rather than stopping at the first helper.
    fn checkCases(tier: Tier) !void {
        var failed = false;
        for (cases) |c| {
            checkCase(c, tier) catch |e| {
                std.debug.print("string helper OOM case {s}: {s}\n", .{ c.name, @errorName(e) });
                failed = true;
            };
        }
        try testing.expect(!failed);
    }
};

test "pipeline (string helper OOM, doc 45 D5): a precise trace's tostring allocation failure raises like tier-0, never retried (tier-1a)" {
    try PreciseStrOom.checkTostr(.tier1a);
}

test "pipeline (string helper OOM native, doc 45 D5): a precise trace's tostring allocation failure raises like tier-0, never retried (native)" {
    try PreciseStrOom.checkTostr(.native);
}

test "pipeline (string helper OOM, doc 45 D5): every allocating snew/scap helper's failure in a precise trace raises, never retried (tier-1a)" {
    try PreciseStrOom.checkCases(.tier1a);
}

test "pipeline (string helper OOM native, doc 45 D5): every allocating snew/scap helper's failure in a precise trace raises, never retried (native)" {
    try PreciseStrOom.checkCases(.native);
}

test "nativegen (precise string helper exits, doc 45 D6): the allocator keeps every snapshot-captured ref live up to the helper" {
    if (!@import("nativegen.zig").is_x64_linux) return error.SkipZigTest;
    try testing.expect(try PreciseStrOom.checkSnapshotLiveness(PreciseStrOom.tostr_source) >= 1);
    for (PreciseStrOom.cases) |c| {
        const checked = PreciseStrOom.checkSnapshotLiveness(c.source) catch |e| {
            std.debug.print("string helper liveness case {s}: {s}\n", .{ c.name, @errorName(e) });
            return e;
        };
        try testing.expect(checked >= 1);
    }
}

noinline fn stackDepthHere() usize {
    var buf: [64]usize = undefined;
    return std.debug.captureCurrentStackTrace(.{}, &buf).return_addresses.len;
}

test "jit_unwind: std's unwinder never searches its modules for a JIT frame, and still works after one" {
    // testing.allocator traces every allocation; one made by a helper the
    // native trace calls walks into the trace's frame. The installed
    // SelfInfo (tests/test_runner.zig) must answer that PC itself: std's
    // own answer to a PC outside every module is a full rebuild of its
    // unwind state, per allocation. Before the wrapper, the dev.813 std
    // instead broke for good at the first such PC: every later trace in
    // the process came back empty.
    const jit_unwind = @import("jit_unwind");
    try testing.expect(std.debug.SelfInfo == jit_unwind.TargetSelfInfo);
    if (!@import("nativegen.zig").is_x64_linux) return error.SkipZigTest;
    const depth_before = stackDepthHere();
    const before = jit_unwind.interceptCount();
    const got = try PreciseStrOom.run(testing.allocator, PreciseStrOom.tostr_source, .tostr_int, std.math.maxInt(usize), .native);
    try testing.expect(!got.oom);
    try testing.expect(got.native_entries >= 1);
    try testing.expectEqual(depth_before, stackDepthHere());
    // SafeAllocator captures allocation traces only in Debug builds.
    if (@import("builtin").mode == .debug) {
        try testing.expect(depth_before > 0);
        try testing.expect(jit_unwind.interceptCount() > before);
    }
}

test "pipeline (string helper decline, doc 45 D5): an out-of-range string.char in a precise trace resumes tier-0, which raises the catchable located error" {
    // The decline arm of the `StrResult` protocol: `schar1` fails on a
    // codepoint past 0x10FFFF WITHOUT an OOM, so the precise exit must be
    // `.precise_resume` — tier-0 re-executes the call and raises `bad
    // argument`, which pcall catches. Treating the decline as an OOM would
    // raise an uncatchable OOM instead. The codepoint crosses the range at
    // i = 256 with no branch in the body, so the failing op is `schar1`
    // itself, not a guard before it.
    const gpa = testing.allocator;
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    const source =
        \\local char = string.char
        \\local function f()
        \\  local n = 0
        \\  for i = 1, 400 do
        \\    local t = {}
        \\    local s = char(0x10FF00 + i)
        \\    n = n + #s
        \\  end
        \\  return n
        \\end
        \\print(pcall(f))
    ;
    var t0_buf: [256]u8 = undefined;
    var t0_len: usize = 0;
    for ([_]PreciseStrOom.Tier{ .tier0, .tier1a, .native }) |tier| {
        var vm = try Vm.init(gpa);
        defer vm.deinit();
        var diags = diag.Diagnostics.init(gpa);
        defer diags.deinit();
        var tree = try parser.parse(gpa, source, &diags);
        defer tree.deinit();
        if (tier != .tier0) {
            vm.trace.config.enabled = true;
            vm.trace.config.execute = true;
            vm.trace.config.optimize = false;
            vm.trace.config.native_codegen = tier == .native;
            vm.trace.config.hotloop = 4;
        }
        var buf: [256]u8 = undefined;
        var sink = io.Writer.fixed(&buf);
        vm.out = &sink;
        var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
        defer chunk.deinit();
        try testing.expect(!diags.hasErrors());
        _ = try vm.run(chunk.proto);
        const out = sink.buffered();
        if (tier == .tier0) {
            try testing.expect(std.mem.startsWith(u8, out, "false\t"));
            try testing.expect(std.mem.indexOf(u8, out, "bad argument") != null);
            @memcpy(t0_buf[0..out.len], out);
            t0_len = out.len;
            continue;
        }
        try testing.expectEqualStrings(t0_buf[0..t0_len], out);
        var has_schar1 = false;
        for (vm.trace.registry.cache.items) |t| {
            for (t.code.instrs) |ins| {
                if (ins.op == .schar1) has_schar1 = true;
            }
        }
        try testing.expect(has_schar1);
        try testing.expectEqual(@as(u64, 0), vm.trace.precise_errors);
        if (tier == .native and @import("nativegen.zig").is_x64_linux)
            try testing.expect(vm.trace.native_entries >= 1);
    }
}

test "executor (tnew mixed body, doc 45 D3): an immediate store rides a precise construction trace and neither effect repeats across a mid-loop resume" {
    const gpa = testing.allocator;
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");

    // Codex-flagged coverage: `tnew` unlocks MIXED effect bodies (immediate
    // astores still emit in precise mode; only sunk stores are refused). At
    // i == 200 the element guard fails MID-ITERATION — after this
    // iteration's `tnew` AND `a[1] = i` already ran in-trace — and tier-0
    // resumes at the load bytecode. Exactly-once bar: `next_obj_id` (no
    // re-run of the tnew across the resume), `a[1]` (no doubled store), and
    // the printed sums all byte-match pure tier-0.
    const source: [:0]const u8 =
        \\local a = {}
        \\for i = 1, 300 do a[i] = i end
        \\a[200] = 1.5
        \\local s = 0
        \\local n = 0
        \\for i = 1, 300 do
        \\  local t = {}
        \\  a[1] = i
        \\  s = s + a[i]
        \\  n = n + 1
        \\end
        \\print(s)
        \\print(n)
        \\print(a[1])
    ;

    var truth: [64]u8 = undefined;
    var truth_len: usize = 0;
    var truth_next_id: u32 = 0;
    {
        var vm = try Vm.init(gpa);
        defer vm.deinit();
        var diags = diag.Diagnostics.init(gpa);
        defer diags.deinit();
        var tree = try parser.parse(gpa, source, &diags);
        defer tree.deinit();
        var buf: [64]u8 = undefined;
        var sink = io.Writer.fixed(&buf);
        vm.out = &sink;
        var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
        defer chunk.deinit();
        try testing.expect(!diags.hasErrors());
        _ = try vm.run(chunk.proto);
        truth_len = sink.buffered().len;
        @memcpy(truth[0..truth_len], sink.buffered());
        truth_next_id = vm.heap.next_obj_id;
    }

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();
    vm.trace.config.enabled = true;
    vm.trace.config.execute = true;
    vm.trace.config.optimize = false;
    vm.trace.config.hotloop = 4;
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;
    var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    _ = try vm.run(chunk.proto);

    try testing.expectEqualStrings(truth[0..truth_len], sink.buffered());
    try testing.expectEqual(truth_next_id, vm.heap.next_obj_id);
    try testing.expect(vm.trace.precise_resumes >= 1);
    // The mixed body really recorded: one precise trace carries BOTH the
    // `tnew` and an inline `astore` (were the store refused, this documents
    // the regression; were tnew refused, the trace never commits).
    var saw_mixed = false;
    for (vm.trace.registry.cache.items) |ct| {
        if (ct.code.deopt_mode != .precise) continue;
        var has_tnew = false;
        var has_store = false;
        for (ct.code.instrs) |ins| {
            if (ins.op == .tnew) has_tnew = true;
            if (ins.op == .astore) has_store = true;
        }
        if (has_tnew and has_store) saw_mixed = true;
    }
    try testing.expect(saw_mixed);
}

test "recorder (precise deopt, doc 45 D8 interim): an exec-log session never produces a precise trace and serializes cleanly" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    vm.trace.config.record_exec_log = true;
    // The increment-2 constructing loop: under an exec-log session the
    // `needs_precise` cancel must fall through to an ORDINARY strike — no
    // memo, no precise retry, no precise commit — because the wire format
    // cannot carry a precise trace until the D8 bump.
    var chunk = try runForTrace(&vm, gpa,
        \\local s = 0
        \\for i = 1, 400 do
        \\  local t = {}
        \\  t.x = i
        \\  s = s + t.x
        \\end
        \\print(s)
    , true);
    defer chunk.deinit();

    try testing.expectEqual(@as(usize, 0), vm.trace.precise_anchor_memo.count());
    for (vm.trace.registry.cache.items) |ct| {
        try testing.expect(ct.code.deopt_mode != .precise);
    }
    // The whole cache serializes (would hard-error on any precise trace).
    const bytes = try vm.trace.encodeTraceFile(gpa);
    gpa.free(bytes);
}

test "executor (tnew native, doc 45 D6): the construction loop runs on the NATIVE page and loop-done rides the precise materializer" {
    const gpa = testing.allocator;
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");

    // The D3 money shape with `native_codegen` ON: the precise trace must
    // compile to a native page (heap-armed `tnew` callout + inline snapshot
    // materializers), enter it, allocate exactly once per iteration through
    // the callout, and surface every clean completion as a `precise_resume`
    // via the loop-done materializer — never the linked/ordinary machinery.
    // Identity bar is the same as tier-1a: output, `next_obj_id`,
    // `object_count` byte-match pure tier-0. On non-x64 hosts the selection
    // change routes the same trace to tier-1a and the identity half still
    // runs; the native-entry asserts are gated.
    const source: [:0]const u8 =
        \\local n = 0
        \\for i = 1, 400 do
        \\  local t = {}
        \\  n = n + 1
        \\end
        \\print(n)
    ;

    // Tier-0 truth.
    var truth: [64]u8 = undefined;
    var truth_len: usize = 0;
    var truth_next_id: u32 = 0;
    var truth_obj_count: usize = 0;
    {
        var vm = try Vm.init(gpa);
        defer vm.deinit();
        var diags = diag.Diagnostics.init(gpa);
        defer diags.deinit();
        var tree = try parser.parse(gpa, source, &diags);
        defer tree.deinit();
        var buf: [64]u8 = undefined;
        var sink = io.Writer.fixed(&buf);
        vm.out = &sink;
        var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
        defer chunk.deinit();
        try testing.expect(!diags.hasErrors());
        _ = try vm.run(chunk.proto);
        truth_len = sink.buffered().len;
        @memcpy(truth[0..truth_len], sink.buffered());
        truth_next_id = vm.heap.next_obj_id;
        truth_obj_count = vm.heap.object_count;
    }

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();
    vm.trace.config.enabled = true;
    vm.trace.config.execute = true;
    vm.trace.config.optimize = false;
    vm.trace.config.native_codegen = @import("nativegen.zig").is_x64_linux;
    vm.trace.config.hotloop = 4;
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;
    var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    _ = try vm.run(chunk.proto);

    try testing.expectEqualStrings(truth[0..truth_len], sink.buffered());
    try testing.expectEqual(truth_next_id, vm.heap.next_obj_id);
    try testing.expectEqual(truth_obj_count, vm.heap.object_count);

    // The precise construction trace committed (same shape as the D3 test).
    var money: ?*const trace.Trace = null;
    for (vm.trace.registry.cache.items) |ct| {
        for (ct.code.instrs) |ins| {
            if (ins.op == .tnew) money = ct;
        }
    }
    try testing.expect(money != null);
    try testing.expectEqual(trace_snapshot.DeoptMode.precise, money.?.code.deopt_mode);
    try testing.expect(vm.trace.precise_resumes >= 1);
    // The payoff assertion: on x64 the page really COMPILED and ENTERED —
    // a compileImpl bail here would silently demote to tier-1a and turn
    // this into a duplicate of the D3 test.
    if (@import("nativegen.zig").is_x64_linux)
        try testing.expect(vm.trace.native_entries >= 1);
}

test "pipeline (tnew OOM native, doc 45 D6): a mid-execution heap OOM inside the native page raises identically to tier-0" {
    const gpa = testing.allocator;
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");

    const source: [:0]const u8 =
        \\local n = 0
        \\for i = 1, 400 do
        \\  local t = {}
        \\  n = n + 1
        \\end
        \\print(n)
    ;

    // Same failure schedule as the tier-1a pipeline twin: the K-th guest
    // heap allocation fails. K = 150 lands mid-loop, long after the native
    // page is compiled and entered (~iteration 10 at hotloop 4), so the
    // `tnew` CALLOUT is what observes the null — the stub must preserve the
    // shim's status across the register restore, run the error materializer,
    // and hand tier-0 a byte-identical death (same error, same partial heap,
    // same parked pc). JIT-side allocations never see the swap: the trace
    // machinery holds its own copy of the VM allocator.
    const FailNth = struct {
        inner: std.mem.Allocator,
        fail_at: usize,
        count: usize = 0,
        const VT = std.mem.Allocator.VTable{ .alloc = allocFn, .resize = resizeFn, .remap = remapFn, .free = freeFn };
        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &VT };
        }
        fn allocFn(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.count += 1;
            if (self.count == self.fail_at) return null;
            return self.inner.vtable.alloc(self.inner.ptr, len, alignment, ret_addr);
        }
        fn resizeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.inner.vtable.resize(self.inner.ptr, memory, alignment, new_len, ret_addr);
        }
        fn remapFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.inner.vtable.remap(self.inner.ptr, memory, alignment, new_len, ret_addr);
        }
        fn freeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.inner.vtable.free(self.inner.ptr, memory, alignment, ret_addr);
        }
    };
    const K: usize = 150;

    // Tier-0 truth under the same failure schedule.
    var truth_next_id: u32 = 0;
    var truth_obj_count: usize = 0;
    var truth_parked_pc: usize = 0;
    {
        var vm = try Vm.init(gpa);
        defer vm.deinit();
        var diags = diag.Diagnostics.init(gpa);
        defer diags.deinit();
        var tree = try parser.parse(gpa, source, &diags);
        defer tree.deinit();
        var buf: [64]u8 = undefined;
        var sink = io.Writer.fixed(&buf);
        vm.out = &sink;
        var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
        defer chunk.deinit();
        try testing.expect(!diags.hasErrors());
        var failing = FailNth{ .inner = vm.heap.gpa, .fail_at = K };
        vm.heap.gpa = failing.allocator();
        try testing.expectError(interp.Error.OutOfMemory, vm.run(chunk.proto));
        vm.heap.gpa = failing.inner;
        try testing.expectEqual(@as(usize, 0), sink.buffered().len); // died pre-print
        truth_next_id = vm.heap.next_obj_id;
        truth_obj_count = vm.heap.object_count;
        truth_parked_pc = vm.frames[0].pc;
    }

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();
    vm.trace.config.enabled = true;
    vm.trace.config.execute = true;
    vm.trace.config.optimize = false;
    vm.trace.config.native_codegen = @import("nativegen.zig").is_x64_linux;
    vm.trace.config.hotloop = 4;
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;
    var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    var failing = FailNth{ .inner = vm.heap.gpa, .fail_at = K };
    vm.heap.gpa = failing.allocator();
    try testing.expectError(interp.Error.OutOfMemory, vm.run(chunk.proto));
    vm.heap.gpa = failing.inner;

    try testing.expectEqual(@as(usize, 0), sink.buffered().len);
    try testing.expectEqual(truth_next_id, vm.heap.next_obj_id);
    try testing.expectEqual(truth_obj_count, vm.heap.object_count);
    try testing.expectEqual(truth_parked_pc, vm.frames[0].pc);
    // The OOM surfaced through the precise_error consumer exactly once, and
    // on x64 the trace was executing NATIVELY when it did.
    try testing.expectEqual(@as(u64, 1), vm.trace.precise_errors);
    if (@import("nativegen.zig").is_x64_linux)
        try testing.expect(vm.trace.native_entries >= 1);
}

test "executor (tnew mixed body native, doc 45 D6): a mid-loop element-guard exit restores through the native materializer exactly once" {
    const gpa = testing.allocator;
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");

    // The tier-1a mixed-body twin with `native_codegen` ON. At i == 200 the
    // `a[i]` element guard fails MID-ITERATION on the native page — after
    // this iteration's `tnew` callout AND the inline `a[1] = i` store
    // already ran — and the guard's materializer must flush the FULL
    // snapshot window (including the carried scalars and the freshly
    // allocated table's slot) so tier-0 resumes at the load bytecode with
    // nothing re-run and nothing lost. Exactly-once bar: `next_obj_id`,
    // `a[1]`, and both printed sums byte-match pure tier-0.
    const source: [:0]const u8 =
        \\local a = {}
        \\for i = 1, 300 do a[i] = i end
        \\a[200] = 1.5
        \\local s = 0
        \\local n = 0
        \\for i = 1, 300 do
        \\  local t = {}
        \\  a[1] = i
        \\  s = s + a[i]
        \\  n = n + 1
        \\end
        \\print(s)
        \\print(n)
        \\print(a[1])
    ;

    var truth: [64]u8 = undefined;
    var truth_len: usize = 0;
    var truth_next_id: u32 = 0;
    {
        var vm = try Vm.init(gpa);
        defer vm.deinit();
        var diags = diag.Diagnostics.init(gpa);
        defer diags.deinit();
        var tree = try parser.parse(gpa, source, &diags);
        defer tree.deinit();
        var buf: [64]u8 = undefined;
        var sink = io.Writer.fixed(&buf);
        vm.out = &sink;
        var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
        defer chunk.deinit();
        try testing.expect(!diags.hasErrors());
        _ = try vm.run(chunk.proto);
        truth_len = sink.buffered().len;
        @memcpy(truth[0..truth_len], sink.buffered());
        truth_next_id = vm.heap.next_obj_id;
    }

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();
    vm.trace.config.enabled = true;
    vm.trace.config.execute = true;
    vm.trace.config.optimize = false;
    vm.trace.config.native_codegen = @import("nativegen.zig").is_x64_linux;
    vm.trace.config.hotloop = 4;
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;
    var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    _ = try vm.run(chunk.proto);

    try testing.expectEqualStrings(truth[0..truth_len], sink.buffered());
    try testing.expectEqual(truth_next_id, vm.heap.next_obj_id);
    try testing.expect(vm.trace.precise_resumes >= 1);
    if (@import("nativegen.zig").is_x64_linux)
        try testing.expect(vm.trace.native_entries >= 1);
}

// Doc 45 D6.1 (codex-reviewed): the native safety net, one-shot flavor. A
// precise trace at a HEAD/CONT anchor can never compile natively (the D6
// acceptance checklist is loop-anchor-only), and running it on tier-1a per
// call — no iteration amortization — is a strict loss vs the tier-0 body
// (binary-trees paid +40% wall for exactly this). Under `native_codegen`,
// `enterPatchedTrace` must DECLINE such candidates without entering, and a
// full all-declined walk memoizes a fast tier-0 dispatch on the patch
// (`native_decline_gen`, invalidated by any `cache_gen` bump).
const D61_MK_SOURCE: [:0]const u8 =
    \\local function mk(a, b)
    \\  local t = {}
    \\  return a + b
    \\end
    \\local r = 0
    \\r = mk(r, 1)
    \\r = mk(r, 2)
    \\r = mk(r, 3)
    \\r = mk(r, 4)
    \\r = mk(r, 5)
    \\r = mk(r, 6)
    \\r = mk(r, 7)
    \\r = mk(r, 8)
    \\r = mk(r, 9)
    \\r = mk(r, 10)
    \\r = mk(r, 11)
    \\r = mk(r, 12)
    \\r = mk(r, 13)
    \\r = mk(r, 14)
    \\r = mk(r, 15)
    \\r = mk(r, 16)
    \\print(r)
;

fn d61Truth(gpa: std.mem.Allocator, out: *[64]u8) !usize {
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, D61_MK_SOURCE, &diags);
    defer tree.deinit();
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;
    var chunk = try compiler.compile(gpa, vm.heap, D61_MK_SOURCE, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    _ = try vm.run(chunk.proto);
    const len = sink.buffered().len;
    @memcpy(out[0..len], sink.buffered());
    return len;
}

test "selection (one-shot precise, doc 45 D6.1): under native mode an unsupported precise head trace is declined, memoized, and never runs tier-1a" {
    const gpa = testing.allocator;
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");

    var truth: [64]u8 = undefined;
    const truth_len = try d61Truth(gpa, &truth);

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, D61_MK_SOURCE, &diags);
    defer tree.deinit();
    vm.trace.config.enabled = true;
    vm.trace.config.execute = true;
    vm.trace.config.optimize = false;
    vm.trace.config.native_codegen = @import("nativegen.zig").is_x64_linux;
    // Straight-line calls only: the shared `mk` HEAD anchor heats (hotcall
    // 4), while every call site's cont resume pc is distinct and stays cold.
    vm.trace.config.hotcall = 4;
    // A1' (task 27): the precise commit requests an ordinary probe; `mk`
    // constructs on EVERY path, so the forced attempt aborts with a strike.
    // In a straight-line program the back-edge tick never advances, so gate
    // cooldowns cannot elapse — one strike must be PERMANENT abandonment for
    // the probe to resolve (clearing it re-opens the D6.1 decline memo this
    // test asserts). This also exercises the probe's stop-at-the-gate path.
    vm.trace.config.max_strikes = 1;
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;
    var chunk = try compiler.compile(gpa, vm.heap, D61_MK_SOURCE, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    _ = try vm.run(chunk.proto);

    try testing.expectEqualStrings(truth[0..truth_len], sink.buffered());
    // Vacuity guard: the precise HEAD trace really committed.
    var precise_head: ?*const trace.Trace = null;
    for (vm.trace.registry.cache.items) |ct| {
        if (ct.code.deopt_mode == .precise and trace.anchorKind(ct.code.anchor.pc) != .loop)
            precise_head = ct;
    }
    try testing.expect(precise_head != null);
    // A1': the probe resolved (aborted attempt -> permanent gate -> cleared),
    // so no anchor still requests an ordinary probe.
    try testing.expectEqual(@as(u32, 0), vm.trace.ordinary_probe_count);
    if (@import("nativegen.zig").is_x64_linux) {
        // The decline: NOTHING ever entered — no native page exists for a
        // non-loop precise trace, and tier-1a must not be substituted.
        try testing.expectEqual(@as(u64, 0), vm.trace.entries);
        try testing.expectEqual(@as(u64, 0), vm.trace.native_entries);
        try testing.expectEqual(@as(u64, 0), vm.trace.precise_resumes);
        try testing.expectEqual(@as(u64, 0), vm.trace.precise_errors);
        // The memo: a full all-declined walk armed the fast tier-0 dispatch
        // (keyed to the LIVE cache_gen — nothing committed after it).
        var memoized = false;
        for (vm.trace.registry.entry_registry.entry_patches.items) |p| {
            if (p.live and p.native_decline_gen == vm.trace.registry.cache_gen)
                memoized = true;
        }
        try testing.expect(memoized);
    } else {
        // Non-x64: native_codegen stayed false, so tier-1a owns the trace.
        try testing.expect(vm.trace.entries > 0);
    }
}

test "selection (one-shot precise, doc 45 D6.1): tier-1a mode still enters the same precise head trace" {
    const gpa = testing.allocator;
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");

    var truth: [64]u8 = undefined;
    const truth_len = try d61Truth(gpa, &truth);

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, D61_MK_SOURCE, &diags);
    defer tree.deinit();
    vm.trace.config.enabled = true;
    vm.trace.config.execute = true;
    vm.trace.config.optimize = false;
    // native_codegen OFF: tier-1a is the precise executor and MUST keep
    // running one-shot precise traces (the decline is native-mode-only).
    vm.trace.config.hotcall = 4;
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;
    var chunk = try compiler.compile(gpa, vm.heap, D61_MK_SOURCE, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    _ = try vm.run(chunk.proto);

    try testing.expectEqualStrings(truth[0..truth_len], sink.buffered());
    var precise_head: ?*const trace.Trace = null;
    for (vm.trace.registry.cache.items) |ct| {
        if (ct.code.deopt_mode == .precise and trace.anchorKind(ct.code.anchor.pc) != .loop)
            precise_head = ct;
    }
    try testing.expect(precise_head != null);
    try testing.expect(vm.trace.entries > 0);
    try testing.expectEqual(@as(u64, 0), vm.trace.native_entries);
    // No memo in tier-1a mode: the decline path never ran.
    for (vm.trace.registry.entry_registry.entry_patches.items) |p| {
        try testing.expectEqual(@as(u32, 0), p.native_decline_gen);
    }
}

// A1' (doc 45 / task 27): mini binary-trees — leaf path constructs, descent
// path is clean. The first hot recording lands on a construction path and
// goes precise; the probe then grows an ORDINARY sibling from a clean path.
const A1_BTREE_SOURCE: [:0]const u8 =
    \\local function build(d)
    \\  if d > 0 then
    \\    local l = build(d - 1)
    \\    local r = build(d - 1)
    \\    return l + r
    \\  else
    \\    local t = {}
    \\    return 1
    \\  end
    \\end
    \\local total = 0
    \\for i = 1, 6 do
    \\  total = total + build(4)
    \\end
    \\print(total)
;

fn a1Truth(gpa: std.mem.Allocator, out: *[64]u8) !usize {
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, A1_BTREE_SOURCE, &diags);
    defer tree.deinit();
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;
    var chunk = try compiler.compile(gpa, vm.heap, A1_BTREE_SOURCE, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    _ = try vm.run(chunk.proto);
    const len = sink.buffered().len;
    @memcpy(out[0..len], sink.buffered());
    return len;
}

fn a1RunAndAssertPopulation(gpa: std.mem.Allocator, native: bool) !void {
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");

    var truth: [64]u8 = undefined;
    const truth_len = try a1Truth(gpa, &truth);

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, A1_BTREE_SOURCE, &diags);
    defer tree.deinit();
    vm.trace.config.enabled = true;
    vm.trace.config.execute = true;
    vm.trace.config.optimize = false;
    vm.trace.config.native_codegen = native;
    vm.trace.config.hotcall = 4;
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;
    var chunk = try compiler.compile(gpa, vm.heap, A1_BTREE_SOURCE, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    _ = try vm.run(chunk.proto);

    try testing.expectEqualStrings(truth[0..truth_len], sink.buffered());
    // Vacuity: a precise ONE-SHOT trace committed somewhere (the leaf-path
    // construction forced needs_precise at a head/cont anchor)...
    var precise_anchor: ?trace.AnchorKey = null;
    for (vm.trace.registry.cache.items) |ct| {
        if (ct.code.deopt_mode == .precise and trace.anchorKind(ct.code.anchor.pc) != .loop)
            precise_anchor = ct.code.anchor;
    }
    try testing.expect(precise_anchor != null);
    // ...and the probe grew an ORDINARY sibling at that SAME anchor: without
    // A1' a precise incumbent permanently claims the anchor (sibling
    // recording only triggers on hot exits of entered traces).
    var ordinary_sibling = false;
    for (vm.trace.registry.cache.items) |ct| {
        if (ct.code.anchor.proto == precise_anchor.?.proto and
            ct.code.anchor.pc == precise_anchor.?.pc and
            ct.code.deopt_mode != .precise) ordinary_sibling = true;
    }
    try testing.expect(ordinary_sibling);
    // The probe resolved on the ordinary commit — no outstanding requests.
    try testing.expectEqual(@as(u32, 0), vm.trace.ordinary_probe_count);
}

test "population (ordinary probe, A1' task 27): a precise one-shot anchor grows an ordinary sibling — native mode" {
    // On non-x64 hosts native_codegen stays inert, making this the tier-1a
    // twin below — still a valid population assertion, just not distinct.
    try a1RunAndAssertPopulation(testing.allocator, @import("nativegen.zig").is_x64_linux);
}

test "population (ordinary probe, A1' task 27): tier-1a mode produces the SAME ordinary sibling (mode-independent population)" {
    try a1RunAndAssertPopulation(testing.allocator, false);
}

// B1' (task 27): X constructs on EVERY path — its head anchor goes
// precise-only and (under native) is declined, never entered. X's cont pages
// are clean, commit natively, and file call-head arm requests wanting an X
// head child that can never arrive: a permanently unsatisfiable request.
// Pre-B1' that request froze the single global pending slot and starved
// EVERY proto's frame links (binary-trees lost ItemCheck's links to
// BottomUpTree's poisoned anchor). Y (clean fib) must still arm.
const B1_STARVE_SOURCE: [:0]const u8 =
    \\local function xr(d)
    \\  local t = { d }
    \\  if d > 0 then
    \\    return xr(d - 1) + xr(d - 2) + t[1]
    \\  end
    \\  return 0
    \\end
    \\local function fib(n)
    \\  if n < 2 then return n end
    \\  return fib(n - 1) + fib(n - 2)
    \\end
    \\local acc = 0
    \\for i = 1, 30 do
    \\  acc = acc + xr(6) + fib(12)
    \\end
    \\print(acc)
;

test "frame-link liveness (B1' task 27): an unsatisfiable call-head request cannot starve another proto's arms" {
    const gpa = testing.allocator;
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");

    // Tier-0 truth.
    var truth: [64]u8 = undefined;
    var truth_len: usize = 0;
    {
        var vm = try Vm.init(gpa);
        defer vm.deinit();
        var diags = diag.Diagnostics.init(gpa);
        defer diags.deinit();
        var tree = try parser.parse(gpa, B1_STARVE_SOURCE, &diags);
        defer tree.deinit();
        var buf: [64]u8 = undefined;
        var sink = io.Writer.fixed(&buf);
        vm.out = &sink;
        var chunk = try compiler.compile(gpa, vm.heap, B1_STARVE_SOURCE, tree.root, &diags);
        defer chunk.deinit();
        try testing.expect(!diags.hasErrors());
        _ = try vm.run(chunk.proto);
        truth_len = sink.buffered().len;
        @memcpy(truth[0..truth_len], sink.buffered());
    }

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, B1_STARVE_SOURCE, &diags);
    defer tree.deinit();
    vm.trace.config.enabled = true;
    vm.trace.config.execute = true;
    vm.trace.config.optimize = false;
    vm.trace.config.native_codegen = @import("nativegen.zig").is_x64_linux;
    vm.trace.config.hotcall = 4;
    vm.trace.config.hotguard = 2;
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;
    var chunk = try compiler.compile(gpa, vm.heap, B1_STARVE_SOURCE, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    _ = try vm.run(chunk.proto);

    try testing.expectEqualStrings(truth[0..truth_len], sink.buffered());
    if (@import("nativegen.zig").is_x64_linux) {
        // The clean recursion's frame links armed despite the poisoned
        // anchor's stale request (displacement, B1'). Pre-B1' this is 0.
        try testing.expect(vm.trace.call_head_link_arms >= 1);
    }
}

// A generic `for`'s ctrl register is dead from `itern` (its last read) to
// `tfor_loop` (which overwrites it), so a collection in between may scrub it
// to nil (doc 61). The recorder's ctrl type pin used to read it at
// `tfor_loop`, saw nil under GC stress, and aborted every attempt: the loop
// kept no trace. It now pins where `itern` reads the register.
test "generic for: the ctrl pin survives a collection inside the recorded iteration" {
    const Inspect = struct {
        fn run(vm: *Vm, mode: util.TraceMode) anyerror!void {
            _ = mode;
            for (vm.trace.abort_log.items) |r| {
                try testing.expect(r.op != .tfor_loop);
            }
            var compiled = false;
            for (vm.trace.registry.cache.items) |t| {
                if (!std.mem.eql(u8, t.code.anchor.proto.name, "walk")) continue;
                if (t.native == .compiled) compiled = true;
            }
            try testing.expect(compiled);
        }
    };
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    try util.runCapturedTuned(testing.allocator,
        \\local function walk(f, s, c)
        \\  local n, acc = 0, 0
        \\  for k in f, s, c do
        \\    n = n + 1
        \\    acc = acc + #k
        \\  end
        \\  return n, acc
        \\end
        \\print(walk(string.gmatch(string.rep("ab cde ", 150), "%a+")))
        \\
    , &sink, true, .record_execute_native, .{ .record_aborts = true, .inspect = Inspect.run });
    try testing.expectEqualStrings("300\t750\n", sink.buffered());
}
