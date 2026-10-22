//! Tests for `interp.zig` — tier1a.
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
const runCaptured = util.runCaptured;
const runExecForTrace = util.runExecForTrace;
const runNativeForTrace = util.runNativeForTrace;

// ---------------------------------------------------------------------------
// Tier-1a executor shape + deopt (Phase 6). The `expectProgram` matrix above
// already proves output transparency across {off, record_only, record_execute}
// × gc_stress; these target the executor-specific behaviours that the matrix
// can't *observe*: that a cached trace genuinely runs (back-edge counts collapse
// once it takes over), that a guard/arith failure side-exits and tier-0 resumes
// byte-identically, and that the re-entry brake blacklists a thrashing anchor.
// ---------------------------------------------------------------------------

test "nested-loop: a hot inner loop's continuation links to the inner root at the inner for_prep (Phase 2)" {
    // Phase 2 of nested-loop trace linking (`docs/design/15-nested-loop-linking.md`).
    // The inner numeric-`for` traces as a root; on its loop-done exit we arm a
    // *continuation* recording anchored at the **post-inner-loop pc** — a non-header
    // anchor (the Phase 1 machinery). That continuation records the outer body
    // forward and re-reaches the inner `for_prep`; because the inner root is already
    // cached, Phase 2 reconstructs the inner root's entry snapshot and **closes the
    // trace with a `.link`** to the inner root (instead of the Phase 1 LINNER abort).
    // Phase 3 may execute the link, but this shape test is still about the recorded
    // cache: prove the link committed by finding a `.link`-terminated trace alongside
    // the inner `.loop` root.
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    // Inner trip count (30) exceeds `min_trip_entry` (24) so the inner trace is
    // actually *entered* — below it the dispatch declines tier-1 and the loop-done
    // exit never runs through `irinterp`, so the continuation could not arm.
    var chunk = try runExecForTrace(&vm, gpa,
        \\local s = 0
        \\for i = 1, 40 do
        \\  for j = 1, 30 do
        \\    s = s + i * j
        \\  end
        \\end
        \\print(s)
    , &sink);
    defer chunk.deinit(); // keep the proto alive: anchors point into it

    // sum(1..40)=820, sum(1..30)=465, 820*465 = 381300.
    try testing.expectEqualStrings("381300\n", sink.buffered());

    // The cache holds the inner `.loop` root AND the continuation `.link` trace.
    var loop_traces: usize = 0;
    var link_traces: usize = 0;
    for (vm.trace.registry.cache.items) |t| {
        try testing.expect(t.code.instrs.len >= 1);
        switch (t.code.instrs[t.code.instrs.len - 1].op) {
            .loop => loop_traces += 1,
            .link => link_traces += 1,
            else => {},
        }
    }
    try testing.expect(loop_traces >= 1); // the inner numeric-for root
    try testing.expect(link_traces >= 1); // the continuation linked, not aborted

    // The link trace's terminator carries the inner root's anchor pc, and that pc
    // really is the anchor of a cached root trace (the hand-off target — P2).
    for (vm.trace.registry.cache.items) |t| {
        const term = t.code.instrs[t.code.instrs.len - 1];
        if (term.op != .link) continue;
        const inner_pc: u32 = @intCast(term.aux);
        var found_root = false;
        for (vm.trace.registry.cache.items) |r| {
            if (r.code.anchor.proto == t.code.anchor.proto and r.code.anchor.pc == inner_pc and
                r.code.instrs[r.code.instrs.len - 1].op == .loop) found_root = true;
        }
        try testing.expect(found_root);
    }
}

test "nested-loop: linked continuation execution is observable (Phase 3)" {
    const source =
        \\local s = 0
        \\for i = 1, 40 do
        \\  for j = 1, 30 do
        \\    s = s + i * j
        \\  end
        \\  s = s + i
        \\end
        \\print(s)
    ;

    var tier0_buf: [64]u8 = undefined;
    var tier0 = io.Writer.fixed(&tier0_buf);
    try runCaptured(testing.allocator, source, &tier0, false, .off);

    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var jit_buf: [64]u8 = undefined;
    var jit = io.Writer.fixed(&jit_buf);
    var chunk = try runExecForTrace(&vm, gpa, source, &jit);
    defer chunk.deinit();

    try testing.expectEqualStrings(tier0.buffered(), jit.buffered());
    try testing.expect(vm.trace.link_ir_exits > 0);
    try testing.expect(vm.trace.link_follow_count > 0);
}

test "nested-loop: linked array stores commit exactly once at tier-1a boundary" {
    const source =
        \\local a = {}
        \\for k = 1, 200 do a[k] = 0 end
        \\local s = 0
        \\for i = 1, 400 do
        \\  for j = 1, 100 do
        \\    a[j] = a[j] + i
        \\  end
        \\  s = s + i
        \\end
        \\local sum = 0
        \\for k = 1, 200 do sum = sum + a[k] end
        \\print(sum)
        \\print(s)
    ;

    var tier0_buf: [64]u8 = undefined;
    var tier0 = io.Writer.fixed(&tier0_buf);
    try runCaptured(testing.allocator, source, &tier0, false, .off);
    try testing.expectEqualStrings("8020000\n80200\n", tier0.buffered());

    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var jit_buf: [64]u8 = undefined;
    var jit = io.Writer.fixed(&jit_buf);
    var chunk = try runExecForTrace(&vm, gpa, source, &jit);
    defer chunk.deinit();

    try testing.expect(vm.trace.link_ir_exits > 0);
    try testing.expect(vm.trace.link_follow_count > 0);
    try testing.expectEqualStrings(tier0.buffered(), jit.buffered());
}

test "nested-loop: linked continuation execution goes native (Phase 4)" {
    if (comptime !@import("nativegen.zig").is_x64_linux) return error.SkipZigTest;
    const source =
        \\local s = 0
        \\for i = 1, 50 do
        \\  for j = 1, 35 do
        \\    s = s + i * j
        \\  end
        \\  s = s + i
        \\end
        \\print(s)
    ;

    var tier0_buf: [64]u8 = undefined;
    var tier0 = io.Writer.fixed(&tier0_buf);
    try runCaptured(testing.allocator, source, &tier0, false, .off);

    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var native_buf: [64]u8 = undefined;
    var native = io.Writer.fixed(&native_buf);
    var chunk = try runNativeForTrace(&vm, gpa, source, &native);
    defer chunk.deinit();

    try testing.expectEqualStrings(tier0.buffered(), native.buffered());
    try testing.expect(vm.trace.native_link_exits > 0);
    try testing.expect(vm.trace.native_link_follow_count > 0);
}

test "nested-loop: native linked array stores commit exactly once (Phase 4)" {
    if (comptime !@import("nativegen.zig").is_x64_linux) return error.SkipZigTest;
    const source =
        \\local a = {}
        \\for k = 1, 30 do a[k] = 0 end
        \\local s = 0
        \\for i = 1, 400 do
        \\  for j = 1, 30 do
        \\    a[j] = a[j] + i
        \\  end
        \\  s = s + i
        \\end
        \\local sum = 0
        \\for k = 1, 30 do sum = sum + a[k] end
        \\print(sum)
        \\print(s)
    ;

    var tier0_buf: [64]u8 = undefined;
    var tier0 = io.Writer.fixed(&tier0_buf);
    try runCaptured(testing.allocator, source, &tier0, false, .off);
    try testing.expectEqualStrings("2406000\n80200\n", tier0.buffered());

    const gpa = testing.allocator;
    var opt_vm = try Vm.init(gpa);
    defer opt_vm.deinit();
    var opt_buf: [64]u8 = undefined;
    var opt = io.Writer.fixed(&opt_buf);
    var opt_chunk = try runExecForTrace(&opt_vm, gpa, source, &opt);
    defer opt_chunk.deinit();
    try testing.expectEqualStrings(tier0.buffered(), opt.buffered());

    var native_vm = try Vm.init(gpa);
    defer native_vm.deinit();
    var native_buf: [64]u8 = undefined;
    var native = io.Writer.fixed(&native_buf);
    var native_chunk = try runNativeForTrace(&native_vm, gpa, source, &native);
    defer native_chunk.deinit();

    try testing.expectEqualStrings(tier0.buffered(), native.buffered());
    try testing.expect(native_vm.trace.native_link_exits > 0);
    try testing.expect(native_vm.trace.native_link_follow_count > 0);
}

test "2c-E (doc 17): loop-done inner→continuation arm fires and closes the native cycle" {
    if (comptime !@import("nativegen.zig").is_x64_linux) return error.SkipZigTest;
    // A plain hot nested loop: the doc-15 chain (continuation ⇄ inner) runs every
    // outer iteration. 2c-E arms the inner's loop-done slot → the continuation's
    // `ordinary_entry` on the first accounted loop-done hop; every later native
    // loop-done then fuses `I→C` in ONE trampoline entry and the multi-entry
    // ledger drains through `replayLedger`.
    const source =
        \\local s = 0
        \\for i = 1, 400 do
        \\  for j = 1, 30 do
        \\    s = s + i
        \\  end
        \\  s = s + 1
        \\end
        \\print(s)
    ;

    var tier0_buf: [64]u8 = undefined;
    var tier0 = io.Writer.fixed(&tier0_buf);
    try runCaptured(testing.allocator, source, &tier0, false, .off);

    const gpa = testing.allocator;
    var native_vm = try Vm.init(gpa);
    defer native_vm.deinit();
    var native_buf: [64]u8 = undefined;
    var native = io.Writer.fixed(&native_buf);
    var native_chunk = try runNativeForTrace(&native_vm, gpa, source, &native);
    defer native_chunk.deinit();

    // Primary gate: byte-identical output with the cycle live.
    try testing.expectEqualStrings(tier0.buffered(), native.buffered());
    // The `I.loopdone → C.ordinary_entry` slot was actually armed (any of the
    // three arm sites) …
    try testing.expect(native_vm.trace.native_loopdone_link_arms > 0);
    // … and a subsequent native run actually FUSED through it — the consumer-side
    // proof (`replayLedger`'s non-last `.loop_done_linked` arm). Output equality
    // alone cannot distinguish the fused cycle from the unfused ping-pong.
    try testing.expect(native_vm.trace.native_loopdone_link_fused > 0);
}

test "2c-E (doc 17): native one-trip linked loop-done is productive, not a guard failure" {
    if (comptime !@import("nativegen.zig").is_x64_linux) return error.SkipZigTest;
    // One-trip reachability: a 2-trip inner loop's dispatcher entry happens on the
    // FIRST back-edge (tier-0 ran iteration 1), so the native trace runs exactly
    // one iteration and hits its loop-done LINKED with `local_completed == 0` (the
    // final linked snapshot commits WITHOUT the back-edge rbx increment). The warm
    // phase (m=30) records the inner root + continuation and compiles them native;
    // the m=2 phase then produces a one-trip linked receipt on every outer
    // iteration. Without the `linked_one_trip` fix each such receipt takes the
    // zero path and `countGuardFailure` charges the loop-done exit PC — at a PC
    // where the trace just SUCCEEDED (the linked snapshot committed).
    //
    // The `%` in the outer body is LOAD-BEARING twice over: it makes the
    // continuation nativegen-unsupported, so (a) `armLoopDoneLink` fails closed at
    // `nativeFor(cont).ordinary_entry` and the loop-done slot stays UNARMED — every
    // m=2 receipt therefore reaches the scalar dispatcher path instead of fusing
    // through the armed slot into the multi-entry ledger drain; and (b) the burst
    // never runs the continuation natively, so the one-trip receipts keep coming
    // via the dispatcher for the whole phase (gate-cooldown cycles re-admit them).
    const source =
        \\local s = 0
        \\local m = 30
        \\for i = 1, 300 do
        \\  if i == 60 then m = 2 end
        \\  for j = 1, m do s = s + 1 end
        \\  s = s % 100000007
        \\end
        \\print(s)
    ;

    var tier0_buf: [64]u8 = undefined;
    var tier0 = io.Writer.fixed(&tier0_buf);
    try runCaptured(testing.allocator, source, &tier0, false, .off);

    const gpa = testing.allocator;
    var native_vm = try Vm.init(gpa);
    defer native_vm.deinit();
    // One-trip receipts are UNREACHABLE at the default `min_trip_entry` (24): the
    // dispatcher declines numeric-for entry when the EXACT remaining trip count
    // (`forRemainingTrips`) is below it, and the m=2 inner has 1 remaining trip at
    // its first back-edge. Disable the heuristic so the dispatcher actually enters
    // the trace and produces the one-trip linked receipts under test (same
    // precedent as the min_trip_entry=0 tests above; `runNativeForTrace` leaves
    // pre-set config keys alone).
    native_vm.trace.config.min_trip_entry = 0;
    var native_buf: [64]u8 = undefined;
    var native = io.Writer.fixed(&native_buf);
    var native_chunk = try runNativeForTrace(&native_vm, gpa, source, &native);
    defer native_chunk.deinit();

    // Primary gate — and the load-bearing one: byte-identical output. Verified by
    // disabling the fix (`false and` on `linked_one_trip`): without it the scalar
    // zero path MISRESUMES a one-trip linked receipt — the linked snapshot already
    // committed the final iteration into regs, and the zero path re-runs it —
    // printing 2253 vs tier-0's 2252. So the fix is a *correctness* fix, not just
    // accounting; at default config only `min_trip_entry` (24) keeps the broken
    // path unreachable (the dispatcher declines <24-remaining-trip entries).
    try testing.expectEqualStrings(tier0.buffered(), native.buffered());
    // Secondary gate (accounting): no guard-failure key was charged repeatedly.
    // Without the fix every one-trip linked receipt is misclassified as a
    // zero-yield entry and `countGuardFailure` charges the loop-done exit PC once
    // per dispatcher entry — bounded by the `max_penalty` (8) gate, so assert < 4,
    // not < hotguard. With the fix the one-trip receipts are productive and the
    // key never appears.
    // (Live diagnostics for this scenario: build with `-Djit-debug=true`, set
    // `native_vm.trace.config.debug_log = true` above, and use
    // `native_vm.trace.dbgDumpGuardFailures()` / `dbgDumpCache()` here.)
    var it = native_vm.trace.guard_failures.valueIterator();
    while (it.next()) |count| {
        try testing.expect(count.* < 4);
    }
}

test "2c-F (doc 17): a fresh top-level run disarms the prior epoch's LIVE armed cycle" {
    if (comptime !@import("nativegen.zig").is_x64_linux) return error.SkipZigTest;
    // The load-bearing epoch-containment integration test (the same-VM two-phase
    // scenario the `disarmAllLinks` unit test at trace.zig can't reach). Phase A arms
    // + fuses the native `C↔I` cycle on a real VM and asserts the NEGATIVE CONTROL:
    // within a single execution epoch `disarmAllLinks` NEVER fires
    // (`native_link_disarms == 0`) even though slots are live and fused. Phase B
    // starts a FRESH top-level run of the SAME proto on the SAME VM: `Vm.run`'s
    // `beginTopLevelEpoch` (2c-F containment) tears the prior epoch's live cycle down
    // (`disarmAllLinks` resets both slots to `shared_exit`) BEFORE the first hot
    // dispatcher entry, so no armed exit left over from Phase A can fire a
    // native→native handoff into this run's fresh frame/register state. This is the
    // fix for the codex-flagged rerun blocker: the exit-slot hardening proves address
    // provenance but not dynamic-entry validity across an epoch — only the
    // fresh-run disarm restores the dispatcher boundary. The decisive facts: (1)
    // Phase B is byte-identical to tier-0 with NO observation window (the containment
    // is unconditional, not window-gated), and (2) the tear-down actually happened
    // over a non-empty registry — provable only by the counter, since a correct
    // byte-identical run looks the same whether the registry held zero or two links.
    // (The dispatcher's observation-window disarm, 2.3c-0e, remains reachable on the
    // SAME-epoch suspend/resume path, which `beginTopLevelEpoch` deliberately does
    // NOT touch; it is unit-covered by the `disarmAllLinks` test.)
    const source =
        \\local s = 0
        \\for i = 1, 400 do
        \\  for j = 1, 30 do
        \\    s = s + i
        \\  end
        \\  s = s + 1
        \\end
        \\print(s)
    ;

    var tier0_buf: [64]u8 = undefined;
    var tier0 = io.Writer.fixed(&tier0_buf);
    try runCaptured(testing.allocator, source, &tier0, false, .off);

    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();

    // Phase A — arm + fuse the cycle (negative control: no disarm within one epoch).
    var phaseA_buf: [64]u8 = undefined;
    var phaseA = io.Writer.fixed(&phaseA_buf);
    var chunk = try runNativeForTrace(&vm, gpa, source, &phaseA);
    defer chunk.deinit();
    try testing.expectEqualStrings(tier0.buffered(), phaseA.buffered());
    // The cycle is live: it was armed and fused …
    try testing.expect(vm.trace.native_loopdone_link_arms > 0);
    try testing.expect(vm.trace.native_loopdone_link_fused > 0);
    // … and nothing disarmed within the epoch (the negative control).
    try testing.expectEqual(@as(u64, 0), vm.trace.registry.native_physical.native_link_disarms);

    // Phase B — a FRESH top-level run of the same proto on the same VM, with NO
    // observation window. `beginTopLevelEpoch` must reset the still-armed Phase-A
    // cycle before any hot entry.
    var phaseB_buf: [64]u8 = undefined;
    var phaseB = io.Writer.fixed(&phaseB_buf);
    vm.out = &phaseB;
    _ = try vm.run(chunk.proto);

    // (1) Correctness across the epoch boundary: byte-identical to tier-0 with no
    // window in play — the containment is unconditional.
    try testing.expectEqualStrings(tier0.buffered(), phaseB.buffered());
    // (2) The fresh-run epoch boundary actually tore down the LIVE cycle armed in
    // Phase A — the load-bearing signal a byte-identical run alone can't provide.
    try testing.expect(vm.trace.registry.native_physical.native_link_disarms > 0);
}

test "2c-F (doc 17): a hot armed cycle inside a repeatedly-called function stays correct on re-entry" {
    if (comptime !@import("nativegen.zig").is_x64_linux) return error.SkipZigTest;
    // The supported cold-re-entry regression guard. The armed `C↔I` cycle lives
    // inside `f`, which is called 20 times: after the first call fuses and arms the
    // slots, every later call is a FRESH frame that re-enters the very anchors whose
    // slots are already live — a cold re-entry of an armed cycle. This is the common
    // real-world shape (a hot-loop helper called in a loop) and it must be
    // deterministically byte-identical to tier-0. (A live cycle re-entered from a new
    // frame is precisely the state the disarm-on-unsafe path guards for the
    // observation window; here, on the ordinary path, the fused handoff must simply
    // be correct — verified across many ASLR layouts.)
    const source =
        \\local function f(base)
        \\  local s = 0
        \\  for i = 1, 400 do
        \\    for j = 1, 30 do
        \\      s = s + i
        \\    end
        \\    s = s + base
        \\  end
        \\  return s
        \\end
        \\local total = 0
        \\for c = 1, 20 do total = total + f(c) end
        \\print(total)
    ;
    var t0_buf: [64]u8 = undefined;
    var t0 = io.Writer.fixed(&t0_buf);
    try runCaptured(testing.allocator, source, &t0, false, .off);

    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var nb: [64]u8 = undefined;
    var n = io.Writer.fixed(&nb);
    var chunk = try runNativeForTrace(&vm, gpa, source, &n);
    defer chunk.deinit();

    // Byte-identical to tier-0 …
    try testing.expectEqualStrings(t0.buffered(), n.buffered());
    // … with the cycle genuinely armed AND fused (so the re-entries above really did
    // exercise the live fused handoff, not a degraded ping-pong).
    try testing.expect(vm.trace.native_loopdone_link_arms > 0);
    try testing.expect(vm.trace.native_loopdone_link_fused > 0);
}

// Like `runNativeForTrace` but also flips on JIT coverage accounting so the
// iteration counters (`iters_traced` / `iters_tier0_covered` /
// `iters_tier0_uncovered`) are populated. Used by the self-consistency tests
// below (Phase 1 of the coverage-instrumentation arc).
fn runCoverageForTrace(vm: *Vm, gpa: std.mem.Allocator, source: [:0]const u8, sink: *io.Writer) !compiler.Chunk {
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
    vm.trace.config.coverage = true;
    vm.trace.config.hotloop = 4;
    vm.out = sink;

    var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    errdefer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    _ = try vm.run(chunk.proto);
    return chunk;
}

test "jit coverage: iteration accounting is self-consistent with the analytic trip count" {
    if (comptime !@import("nativegen.zig").is_x64_linux) return error.SkipZigTest;
    // A single hot numeric `for` loop of a known trip count. Every loop-body
    // iteration is accounted exactly once: either the trace executed it
    // (`iters_traced`, committed in `onSideExit`) or tier-0 interpreted it
    // (`iters_tier0_*`, counted at the back-edge). The two are disjoint by
    // construction — a trace's committed count excludes the deopt iteration
    // tier-0 redoes on side-exit — so the three counters must sum to the exact
    // number of loop-body iterations, which for `for i=1,N` is exactly N.
    const N = 5000;
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    var chunk = try runCoverageForTrace(&vm, gpa,
        \\local acc = 0
        \\for i = 1, 5000 do acc = acc + i end
        \\print(acc)
    , &sink);
    defer chunk.deinit();

    // Correctness first: same result tier-0 produces.
    try testing.expectEqualStrings("12502500\n", sink.buffered());

    const t = &vm.trace;
    const total = t.iters_traced + t.iters_tier0_covered + t.iters_tier0_uncovered;
    // Exhaustive + disjoint == exact analytic count (N loop-body iterations).
    try testing.expectEqual(@as(u64, N), total);
    // The loop genuinely tiered up — most iterations really ran as a trace …
    try testing.expect(t.iters_traced > 0);
    // … and this is the *clean* case: a single monotype loop, so once the
    // trace commits nothing ever falls back to tier-0. `iters_tier0_covered`
    // (interpreted-despite-a-trace) is therefore zero — the remaining tier-0
    // iterations are the pre-commit warmup, classified `uncovered` because no
    // trace existed yet when they ran. (Contrast the nested test below, which
    // deliberately produces a non-zero covered gap.)
    try testing.expectEqual(@as(u64, 0), t.iters_tier0_covered);

    // Time attribution (x86_64 TSC): the exact cycle values are nondeterministic,
    // so assert only structural invariants. The run was bracketed (`run_cycles`
    // populated), the loop really ran as a trace for a while (`cycles_traced > 0`),
    // and traced time is a subset of the whole run (its brackets nest inside the
    // run bracket, so the bound holds regardless of TSC skew).
    try testing.expect(t.run_cycles > 0);
    try testing.expect(t.cycles_traced > 0);
    try testing.expect(t.cycles_traced <= t.run_cycles);
}

test "jit coverage: the covered-but-interpreted gap is populated (fallback despite a trace)" {
    if (comptime !@import("nativegen.zig").is_x64_linux) return error.SkipZigTest;
    // The smell Bart wants exposed: an anchor that HAS a trace yet keeps
    // dropping to tier-0. An nsieve-shaped nest — an outer scan whose body
    // branches, and a nested marking loop — produces exactly this: the outer
    // header traces but its many short/branchy re-entries deopt, so
    // `iters_tier0_covered` (interpreted-despite-a-trace) is non-zero WHILE
    // `iters_traced` is also non-zero. This is the relationship the report
    // makes visible.
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    var chunk = try runCoverageForTrace(&vm, gpa,
        \\local count = 0
        \\local n = 4000
        \\local p = {}
        \\for i = 2, n do p[i] = true end
        \\for i = 2, n do
        \\  if p[i] then
        \\    count = count + 1
        \\    local k = i + i
        \\    while k <= n do
        \\      p[k] = false
        \\      k = k + i
        \\    end
        \\  end
        \\end
        \\print(count)
    , &sink);
    defer chunk.deinit();

    const t = &vm.trace;
    // Self-consistency still holds across the whole nest: every counted
    // iteration is accounted exactly once. (We don't pin the exact total here
    // — the point of this test is the *gap*, verified by the two-sided bound
    // below — but both classes must be genuinely populated.)
    try testing.expect(t.iters_traced > 0);
    // The gap: iterations that fell back to tier-0 even though a trace exists
    // at their anchor. If this were zero, "covered" would trivially equal
    // "executed natively" and there would be nothing to expose.
    try testing.expect(t.iters_tier0_covered > 0);
}

test "coherent-state chaining (doc 16, Phase 2): nsieve prime path chains, not tier-0" {
    if (comptime !@import("nativegen.zig").is_x64_linux) return error.SkipZigTest;
    // Faithful nsieve shape: an outer loop whose body branches on a boolean
    // array (`if p[i]`) and, on the taken (prime) branch, runs a nested marking
    // loop. Pre-Phase-2 the *skip* trace (composite path) runs native but every
    // prime iteration drops to tier-0 with no trace at the coherent anchor. Phase
    // 2 records a prime side-trace at the outer header and chains
    // skip → prime-side → inner → continuation, all native.
    const source =
        \\local function nsieve(m)
        \\  local p = {}
        \\  for i=2,m do p[i] = true end
        \\  local count = 0
        \\  for i=2,m do
        \\    if p[i] then
        \\      for k=i+i,m,i do p[k] = false end
        \\      count = count + 1
        \\    end
        \\  end
        \\  return count
        \\end
        \\print(nsieve(100000))
    ;
    // 9592 = π(100000), the number of primes ≤ 100000. A single call at this m
    // is what lets the *skip* trace productively exit on primes often enough to
    // cross the (default) `hotguard` arm threshold — the 3-call benchmark warms
    // it during its first (much larger) call. Runs in ~0.04s Debug, so it stays
    // fast even under the leak-checking test allocator.
    const expected = "9592\n";

    var tier0_buf: [64]u8 = undefined;
    var tier0 = io.Writer.fixed(&tier0_buf);
    try runCaptured(testing.allocator, source, &tier0, false, .off);
    try testing.expectEqualStrings(expected, tier0.buffered());

    // Inline native harness with the *default* thresholds (mirrors the CLI's
    // `--trace --jit-native`, not `runNativeForTrace`'s lowered `hotloop=4` —
    // the low hot-count records the outer header on an early prime iteration and
    // never lands on the composite-skip shape the mechanism keys off).
    const gpa = testing.allocator;
    var native_vm = try Vm.init(gpa);
    defer native_vm.deinit();
    var native_buf: [64]u8 = undefined;
    var native = io.Writer.fixed(&native_buf);
    {
        const parser = @import("parser.zig");
        const diag = @import("diag.zig");
        var diags = diag.Diagnostics.init(gpa);
        defer diags.deinit();
        var tree = try parser.parse(gpa, source, &diags);
        defer tree.deinit();
        native_vm.trace.config.enabled = true;
        native_vm.trace.config.execute = true;
        native_vm.trace.config.optimize = true;
        native_vm.trace.config.native_codegen = true;
        // Native exit adapters OFF: this pins doc 16's prime-side chain.
        // With them on (the default since doc 58 B2) the skip trace's prime
        // exit is attachable and doc 56's exit-side route serves it first —
        // that default path is `interp_exit_side_test`'s nsieve coverage.
        native_vm.trace.config.exit_side_native = false;
        native_vm.out = &native;
        var chunk = try compiler.compile(gpa, native_vm.heap, source, tree.root, &diags);
        defer chunk.deinit();
        try testing.expect(!diags.hasErrors());
        _ = try native_vm.run(chunk.proto);
    }

    // Correctness: native output byte-identical to tier-0 — the primary gate.
    try testing.expectEqualStrings(tier0.buffered(), native.buffered());

    // Phase-2-specific signals — output equality alone can't prove the chain
    // fired (full tier-0 fallback also produces the right answer):
    //  1. a prime side-trace was actually armed (2C/2D), and
    //  2. its coherent-anchor link-burst was actually *entered* (2E) — the
    //     `.ordinary_header`-only follow counter isolates it from loop-done
    //     continuation bursts.
    try testing.expect(native_vm.trace.prime_side_arms > 0);
    // B-2b's provenance arm can supersede the prime-side registry record before
    // its first firing (relaxed sibling watch arms at a productive terminal);
    // the identical native same-anchor entry then counts as a sibling-handoff
    // fuse instead of a prime-side chain follow. Either form proves the
    // coherent-anchor link-burst was entered.
    try testing.expect(native_vm.trace.prime_side_chain_follows +
        native_vm.trace.sibling_handoff_fused > 0);

    // The design's tier-0-outer-body signal: without chaining, every prime
    // iteration drops to tier-0 at the outer header (≈9592 of them). With the
    // prime chain the prime path stays native, so the chain fires far more often
    // than tier-0 runs the outer body. Self-relative so it's robust to warm-up
    // length and threshold changes.
    // B-2b may republish the same physical source slot through the shared
    // `.sibling_handoff` funnel once its commit provenance exists, so count both
    // registry-recognized forms of the native same-anchor transition.
    try testing.expect(native_vm.trace.prime_side_chain_follows +
        native_vm.trace.sibling_handoff_fused > native_vm.trace.tier0_outer_body_entries);

    // 2.3c-1 (M1 half-fusion, doc 17): the skip trace's source-branch guard slot was
    // armed → the prime-side ramp's `ordinary_entry` (arm), and on a subsequent
    // productive exit skip fused straight into the ramp under the shared frame and the
    // dispatcher's M1 fused-`.link` consumer drained the receipt (fused). Output
    // equality above already proves the fused receipt is drained byte-identically; these
    // two counters prove the arm path AND the consumer path are exercised at all (either
    // staying 0 would mean the M1 mechanism silently never fired).
    // B-2b's provenance publication can claim the physical source slot before
    // the ordinary M1 registry record ever arms (same shared `publishSiblingArm`
    // funnel); either arm counter proves a native same-anchor source-slot arm
    // was published, and either fused counter proves the consumer drained it.
    try testing.expect(native_vm.trace.native_source_link_arms +
        native_vm.trace.sibling_handoff_arms > 0);
    try testing.expect(native_vm.trace.native_source_link_fused +
        native_vm.trace.sibling_handoff_fused > 0);
}

test "coherent-state chaining (doc 16, Phase 2): TraceKind link-permission (root loops, continuation links)" {
    // The 2A `TraceKind` gate in `recForPrepLink` (trace.zig): a `.root` recording
    // that reaches an inner `for_prep` aborts LINNER and never anchors a `.link`,
    // while a `.side`/`.continuation` recording links to the inner root. Asserted
    // here at the trace-shape level: a 2-level nest produces at least one `.loop`
    // root (the inner loop header) AND at least one `.link` continuation. If the
    // gate wrongly let roots link (or wrongly blocked continuations), one of these
    // populations would vanish. (The `.side` half of the permission is exercised
    // end-to-end by the nsieve prime-chain test above; root-never-links is also
    // pinned by the 10-mode determinism matrix, which any output drift would trip.)
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    var chunk = try runExecForTrace(&vm, gpa,
        \\local s = 0
        \\for i = 1, 40 do
        \\  for j = 1, 30 do s = s + i * j end
        \\  s = s + i
        \\end
        \\print(s)
    , &sink);
    defer chunk.deinit();
    try testing.expectEqualStrings("382120\n", sink.buffered());

    var loop_traces: usize = 0;
    var link_traces: usize = 0;
    for (vm.trace.registry.cache.items) |t| {
        if (t.code.instrs.len == 0) continue;
        switch (t.code.instrs[t.code.instrs.len - 1].op) {
            .loop => loop_traces += 1,
            .link => link_traces += 1,
            else => {},
        }
    }
    try testing.expect(loop_traces > 0);
    try testing.expect(link_traces > 0);
}

test "executor: a hot numeric-for sum runs via the IR-interpreter (back-edges collapse)" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    var chunk = try runExecForTrace(&vm, gpa,
        \\local acc = 0
        \\for i = 1, 100 do acc = acc + i end
        \\print(acc)
    , &sink);
    defer chunk.deinit(); // keep the proto alive: the trace's anchor points into it

    // Correct result (sum 1..100).
    try testing.expectEqualStrings("5050\n", sink.buffered());

    // One clean trace, never blacklisted, penalty cleared by the big yield.
    try testing.expectEqual(@as(usize, 1), vm.trace.registry.cache.items.len);
    try testing.expectEqual(@as(usize, 0), vm.trace.gate.count());
    try testing.expectEqual(@as(usize, 0), vm.trace.penalty.count());

    // The decisive "it actually executed" signal: tier-0 saw back-edges only
    // until the trace was cached (== hotloop). The remaining ~95 iterations ran
    // inside the IR-interpreter, so the anchor's counter never climbed toward 100.
    const t = vm.trace.registry.cache.items[0];
    try testing.expectEqual(vm.trace.config.hotloop, vm.trace.backEdgeCount(t.code.anchor));
}

test "doc 30 c5: loopDoneSnapshotSupported — a sunk sgm_setpos below the loop-done guard declines the linked continuation" {
    const I = trace.IrInstr;
    // Sunk-store range [guard+1 .. phi): astore + sgm_setpos. The cursor
    // commit is NOT in the commit walks' closed store inventory, so the
    // range must decline (both tiers then take ordinary deopt: tier-0
    // replays the final iteration against the un-advanced cursor —
    // replay-idempotent, sound).
    var with_setpos = [_]I{
        .{ .op = .slot_load, .aux = 0 }, // 0
        .{ .op = .guard_true, .a = 0 }, // 1: the loop-done guard (position only)
        .{ .op = .astore, .a = 0, .b = 0 }, // 2
        .{ .op = .sgm_setpos, .a = 0, .b = 0 }, // 3: the gmatch cursor commit
        .{ .op = .phi, .b = 0, .aux = 0 }, // 4
        .{ .op = .loop }, // 5
    };
    var t = trace.TraceCode{ .anchor = undefined, .instrs = &with_setpos, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{} };
    try std.testing.expect(!t.loopDoneSnapshotSupported(1));
    // The scan stops at the φ block: a sgm_setpos BEFORE the guard (not in
    // the sunk range) does not decline — only the post-guard range counts.
    try std.testing.expect(t.loopDoneSnapshotSupported(3));

    // Control: the same shape with only closed-inventory stores is supported.
    var plain = [_]I{
        .{ .op = .slot_load, .aux = 0 },
        .{ .op = .guard_true, .a = 0 },
        .{ .op = .astore, .a = 0, .b = 0 },
        .{ .op = .hstore, .a = 0, .b = 0 },
        .{ .op = .phi, .b = 0, .aux = 0 },
        .{ .op = .loop },
    };
    t = trace.TraceCode{ .anchor = undefined, .instrs = &plain, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{} };
    try std.testing.expect(t.loopDoneSnapshotSupported(1));
}

test "doc 61 §5 site 5: the linked loop-done flush skips R[a+3] only on a maskable proto where it is dead after the loop" {
    const I = trace.IrInstr;
    // pc 0: `for_loop a=0`; pc 1, its fall-through. The guard exits to pc 1,
    // so its source is the `for_loop` at pc 0.
    const code = [_]Instr{ Instr.opA(.for_loop, 0), Instr.op0(.halt) };
    var instrs = [_]I{
        .{ .op = .slot_load, .aux = 0 },
        .{ .op = .guard_true, .a = 0, .aux = 1 },
        .{ .op = .phi, .b = 0, .aux = 0 },
        .{ .op = .loop },
    };
    const dead = [_]u64{ 0b1111, 0b0000 };
    const live = [_]u64{ 0b1111, 0b1000 }; // R[3] read after the loop (captured, say)
    var proto = Proto{ .code = &code, .name = "for", .num_registers = 4, .reg_live = .{ .words = 1, .bits = &dead }, .maskable = true };
    const t = trace.TraceCode{ .anchor = .{ .proto = &proto, .pc = 0, .proto_id = proto.id }, .instrs = &instrs, .consts = &.{}, .entry_slots = &.{}, .entry_guards = &.{} };
    try std.testing.expect(t.loopDoneFlushSupported(1));
    // Read after the loop: the skipped write would be observable.
    proto.reg_live.bits = &live;
    try std.testing.expect(!t.loopDoneFlushSupported(1));
    // Dead, but the collector scans the frame whole and would root the stale value.
    proto.reg_live.bits = &dead;
    proto.maskable = false;
    try std.testing.expect(!t.loopDoneFlushSupported(1));
}

// ---------------------------------------------------------------------------
// Doc 38: while-inner nested-loop linking. The doc 15/16 continuation/link
// machinery extended to `while` inners: the while-body root's loop-done exit
// (a `guard_true` mirroring the condition's `jmp_if_false`) arms a
// continuation at the POST-loop pc; the continuation records the outer body,
// re-enters the while (one recorded condition+body pass) and closes `.link`
// at the backward `jmp` to the while root. Roots reaching that `jmp` abort
// LINNER (LuaJIT `rec_loop_interp`), and a while/repeat-anchored root that
// observes its own exit direction aborts `loop_leave` (LLEAVE) instead of
// wandering into the enclosing loop.
// ---------------------------------------------------------------------------

test "doc 38: while-inner continuation links to the while-body root (.link terminal)" {
    const gpa = testing.allocator;

    const source =
        \\local s = 0
        \\for i = 1, 400 do
        \\  local j = i % 32
        \\  local k = 1
        \\  while k <= j do k = k * 2 end
        \\  s = s + k
        \\end
        \\print(s)
    ;

    var tier0_buf: [64]u8 = undefined;
    var tier0 = io.Writer.fixed(&tier0_buf);
    try runCaptured(gpa, source, &tier0, false, .off);

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var jit_buf: [64]u8 = undefined;
    var jit = io.Writer.fixed(&jit_buf);
    var chunk = try runExecForTrace(&vm, gpa, source, &jit);
    defer chunk.deinit();
    try testing.expectEqualStrings(tier0.buffered(), jit.buffered());

    // The cache holds the while-body `.loop` root AND a `.link` continuation.
    var loop_traces: usize = 0;
    var link_traces: usize = 0;
    for (vm.trace.registry.cache.items) |t| {
        try testing.expect(t.code.instrs.len >= 1);
        switch (t.code.instrs[t.code.instrs.len - 1].op) {
            .loop => loop_traces += 1,
            .link => link_traces += 1,
            else => {},
        }
    }
    try testing.expect(loop_traces >= 1);
    try testing.expect(link_traces >= 1);

    // Every `.link` terminator targets the anchor of a cached `.loop` root.
    for (vm.trace.registry.cache.items) |t| {
        const term = t.code.instrs[t.code.instrs.len - 1];
        if (term.op != .link) continue;
        const inner_pc: u32 = @intCast(term.aux);
        var found_root = false;
        for (vm.trace.registry.cache.items) |r| {
            if (r.code.anchor.proto == t.code.anchor.proto and r.code.anchor.pc == inner_pc and
                r.code.instrs[r.code.instrs.len - 1].op == .loop) found_root = true;
        }
        try testing.expect(found_root);
    }

    // The link executed, not just committed.
    try testing.expect(vm.trace.link_ir_exits > 0);
    try testing.expect(vm.trace.link_follow_count > 0);
}

test "doc 38: no trace unrolls the variable-trip while (LINNER holds)" {
    // An unrolled while pins one branch guard per unrolled condition pass, so
    // >= 2 `jmp_if_false`-sourced branch guards in one trace is the unroll
    // signature. Every legitimate doc 38 shape carries at most one: the
    // while-body root pins its own condition once; a linked continuation pins
    // the re-entry condition once before closing `.link`; a zero-trip sibling
    // pins the done direction once.
    //
    // Unroll-first revision: unrolling is now the DEFAULT root policy, so this
    // invariant only holds in decomposition mode. `unroll_fail_flip = 0` bars
    // unrolling from the start, making this a deterministic unit test of the
    // LINNER machinery (the organic unroll→flip→decompose path is covered by
    // the `.link`-terminal test above, which runs with the default policy).
    const gpa = testing.allocator;
    const source =
        \\local s = 0
        \\for i = 1, 400 do
        \\  local j = i % 32
        \\  local k = 1
        \\  while k <= j do k = k * 2 end
        \\  s = s + k
        \\end
        \\print(s)
    ;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    vm.trace.config.unroll_fail_flip = 0; // decomposition mode from the start
    var jit_buf: [64]u8 = undefined;
    var jit = io.Writer.fixed(&jit_buf);
    var chunk = try runExecForTrace(&vm, gpa, source, &jit);
    defer chunk.deinit();

    for (vm.trace.registry.cache.items) |t| {
        var branch_guards: usize = 0;
        for (t.code.instrs, 0..) |ins, i| {
            if (ins.op != .guard_true and ins.op != .guard_false) continue;
            const src_op = (t.code.anchorSourceInstr(i) orelse continue).op;
            if (src_op == .jmp_if_false or src_op == .jmp_if_true) branch_guards += 1;
        }
        try testing.expect(branch_guards <= 1);
    }
}

test "doc 58: a while-inner nest links natively through the exit-side route" {
    // Doc 38 grew this link from the `while`-done continuation arm: the inner
    // root's condition guard (then at the trace TOP) armed a continuation at
    // the post-loop pc and chained into it. Doc 58 deletes that arm — the
    // condition is an ORDINARY exit at the end of the trace now — and doc 56's
    // exit-side route provides the same fusion the way LuaJIT does: a side
    // trace recorded from the exit, patched in, entered natively.
    //
    // So this pins the new path, with the switch on. With it off the exit is a
    // coarse deopt and tier-0 replays the final pass (§4.4); B4 flips the
    // default and re-measures.
    if (comptime !@import("nativegen.zig").is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    const source =
        \\local s = 0
        \\for i = 1, 2000 do
        \\  local j = i % 64
        \\  local k = 1
        \\  while k <= j do k = k * 2 end
        \\  s = s + k
        \\end
        \\print(s)
    ;

    var tier0_buf: [64]u8 = undefined;
    var tier0 = io.Writer.fixed(&tier0_buf);
    try runCaptured(gpa, source, &tier0, false, .off);

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    vm.trace.config.exit_side_native = true;
    var native_buf: [64]u8 = undefined;
    var native = io.Writer.fixed(&native_buf);
    var chunk = try runNativeForTrace(&vm, gpa, source, &native);
    defer chunk.deinit();

    try testing.expectEqualStrings(tier0.buffered(), native.buffered());
    try testing.expect(vm.trace.native_link_exits > 0);
    try testing.expect(vm.trace.native_link_follow_count > 0);
    // The link is the exit-side one: the inner `while`'s condition exit bound a
    // continuation at the post-loop pc, armed its adapter, and the hops fused
    // into the native run instead of returning to the runtime.
    try testing.expect(vm.trace.exit_side_arms > 0);
    try testing.expect(vm.trace.exit_side_fused > 0);
}

test "doc 38: always-zero-trip while stays sound (no while root, outer traces over it)" {
    // The while back-edge never fires, so the while anchor never warms; the
    // OUTER root records the condition and its `guard_false` (the observed
    // done direction) and jumps straight over the body — no LLEAVE (the branch
    // is not the OUTER anchor's own exit) and no LINNER (the backward `jmp` is
    // never reached).
    const gpa = testing.allocator;
    const source =
        \\local s = 0
        \\for i = 1, 300 do
        \\  local k = 100
        \\  while k <= 10 do k = k + 1 end
        \\  s = s + k
        \\end
        \\print(s)
    ;
    var tier0_buf: [64]u8 = undefined;
    var tier0 = io.Writer.fixed(&tier0_buf);
    try runCaptured(gpa, source, &tier0, false, .off);
    try testing.expectEqualStrings("30000\n", tier0.buffered());

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var jit_buf: [64]u8 = undefined;
    var jit = io.Writer.fixed(&jit_buf);
    var chunk = try runExecForTrace(&vm, gpa, source, &jit);
    defer chunk.deinit();
    try testing.expectEqualStrings(tier0.buffered(), jit.buffered());

    var loop_traces: usize = 0;
    for (vm.trace.registry.cache.items) |t| {
        if (t.code.instrs[t.code.instrs.len - 1].op == .loop) loop_traces += 1;
    }
    try testing.expect(loop_traces >= 1);
}

test "doc 58: a repeat loop anchors at its marker's header and keeps cross-tier parity" {
    // `repeat` is shaped like every other loop now: its `loop` marker opens the
    // loop, the closer's backward `jmp_if_false` targets the MARKER, and the
    // anchor is `marker + 1` (the body start). Any `.link` whose target is a
    // loop header must therefore name a header whose marker exists — the old
    // doc 38 rule ("no link may close into a repeat loop", because its closer
    // was a `jmp_if_false` that `recWhileLink` ignored) is gone.
    const gpa = testing.allocator;
    const source =
        \\local s = 0
        \\for i = 1, 400 do
        \\  local j = i % 32
        \\  local k = 1
        \\  repeat k = k * 2 until k > j
        \\  s = s + k
        \\end
        \\print(s)
    ;
    var tier0_buf: [64]u8 = undefined;
    var tier0 = io.Writer.fixed(&tier0_buf);
    try runCaptured(gpa, source, &tier0, false, .off);

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var jit_buf: [64]u8 = undefined;
    var jit = io.Writer.fixed(&jit_buf);
    var chunk = try runExecForTrace(&vm, gpa, source, &jit);
    defer chunk.deinit();
    try testing.expectEqualStrings(tier0.buffered(), jit.buffered());

    // The `repeat` loop's marker exists, is of kind `repeat`, and its closer
    // targets it — so its header is `marker + 1`.
    const bc = @import("bytecode.zig");
    const code = chunk.proto.code;
    var markers: usize = 0;
    var repeat_header: u32 = 0;
    for (code, 0..) |ins, pc| {
        if (ins.op != .loop) continue;
        if (@as(bc.LoopKind, @enumFromInt(ins.b)) != .repeat_loop) continue;
        markers += 1;
        repeat_header = @intCast(pc + 1);
        try testing.expectEqual(@as(?u32, @intCast(pc + 1)), bc.loopHeaderOf(ins, pc));
        // The closer sits at `E − 1` and jumps back to the marker.
        const closer_pc = bc.loopMarkerExit(ins, pc) - 1;
        try testing.expectEqual(@as(?i64, @intCast(pc)), bc.falseBranchTargetOf(code[closer_pc], closer_pc));
    }
    try testing.expectEqual(@as(usize, 1), markers);

    // The repeat loop is a real trace root, and the outer body reaches it
    // natively: a `.link` naming the repeat header (the outer body's ramp),
    // which resolves to the repeat's own marker as its back-edge, or (doc 64
    // step 3) an exit-side exit bound straight to the root behind the marker.
    // B2 review should-fix: this used to skip every link whose target had no
    // extent, so it passed with no link into the repeat at all.
    try testing.expect(vm.trace.findLoopTrace(chunk.proto, repeat_header) != null);
    var links_into_repeat: usize = 0;
    for (vm.trace.registry.cache.items) |t| {
        for (t.exit_side_entry) |entry| {
            if (t.code.anchor.proto == chunk.proto and entry == repeat_header) links_into_repeat += 1;
        }
    }
    for (vm.trace.registry.cache.items) |t| {
        const last = t.code.instrs[t.code.instrs.len - 1];
        if (last.op != .link) continue;
        const target: u32 = @intCast(last.aux);
        if (t.code.anchor.proto != chunk.proto or target != repeat_header) continue;
        const ext = bc.loopExtentFor(chunk.proto, target) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(bc.OpCode.loop, ext.back_edge_op);
        try testing.expectEqual(repeat_header - 1, ext.back_edge_pc);
        links_into_repeat += 1;
    }
    try testing.expect(links_into_repeat >= 1);
}

test "doc 58: a low-trip while root's own condition is an ordinary exit that exit-side binds" {
    // Trips cycle 1/2/3. Doc 38 met this shape with a `.low_trip_while` yield
    // gate, because every entry was a zero-or-few-trip COMPLETION whose exit
    // paid a runtime round-trip that cost more than tier-0. Doc 58 removes the
    // premise instead of gating it: the loop is entered at its BODY, so a
    // zero-trip instance never reaches the trace at all, and the condition
    // guard now sits at the END of the trace as an ORDINARY exit whose resume pc
    // is the post-loop pc. Exit-side serves it: the exit is counted as taken,
    // goes hot, records the post-loop continuation and binds it. B2 review
    // blocker 2: the dispatcher used to drop it before `noteTakenExit`, so the
    // classification held while nothing was ever wanted — this test now
    // demands the binding itself, on the tier-1a and the native direct route.
    //
    // No zero trips: a continuation recorded on a ZERO-trip outer iteration
    // re-reaches its own (non-header) anchor through the outer `for` and
    // `maybeCloseAtAnchor` closes it `.loop`, which exit-side cannot bind
    // (it gives up). LuaJIT keeps recording there and links at the next
    // compiled loop op — that is doc 56 G6 (TODO.md), not this test.
    const gpa = testing.allocator;
    const source =
        \\local s = 0
        \\for i = 1, 600 do
        \\  local j = i % 3 + 1
        \\  local k = 0
        \\  while k < j do k = k + 1 end
        \\  s = s + k
        \\end
        \\print(s)
    ;
    var tier0_buf: [64]u8 = undefined;
    var tier0 = io.Writer.fixed(&tier0_buf);
    try runCaptured(gpa, source, &tier0, false, .off);
    try testing.expectEqualStrings("1200\n", tier0.buffered());

    inline for (.{ false, true }) |native| {
        var vm = try Vm.init(gpa);
        defer vm.deinit();
        // Decomposition mode: with the default policy this bounded 0/1/2-trip
        // `while` is simply unrolled into the outer root and never dispatches.
        vm.trace.config.unroll_fail_flip = 0;
        vm.trace.config.exit_side_native = native;
        var jit_buf: [64]u8 = undefined;
        var jit = io.Writer.fixed(&jit_buf);
        var chunk = if (native)
            try runNativeForTrace(&vm, gpa, source, &jit)
        else
            try runExecForTrace(&vm, gpa, source, &jit);
        defer chunk.deinit();
        try testing.expectEqualStrings(tier0.buffered(), jit.buffered());
        try checkWhileOwnTestBound(&vm);
    }
}

fn checkWhileOwnTestBound(vm: *Vm) !void {
    // The `while` root committed …
    const bc = @import("bytecode.zig");
    const exit_attach = @import("trace_exit_attach.zig");
    var checked: usize = 0;
    for (vm.trace.registry.cache.items) |t| {
        if (t.code.instrs[t.code.instrs.len - 1].op != .loop) continue;
        if (!bc.isWhileHeader(t.code.anchor.proto, t.code.anchor.pc)) continue;
        // … its own condition guard is the LAST guard of the trace (the body
        // ran first) …
        var own: ?usize = null;
        for (t.code.instrs, 0..) |_, i| {
            if (t.code.isOwnLoopTest(i)) own = i;
        }
        const idx = own orelse continue;
        checked += 1;
        // … it is NOT a numeric loop-done (no final-iteration flush is owed) …
        try testing.expect(!t.code.isNumericForLoopDoneGuard(idx));
        // … a source-branch consumer refuses it (no prime-side want, no
        // same-anchor sibling chase on a finished loop) …
        try testing.expect(!vm.trace.isSourceBranchGuardExit(t, @intCast(idx)));
        // … it resumes AFTER the loop and is attachable, which is what
        // exit-side needs …
        const post = bc.loopMarkerExit(
            t.code.anchor.proto.code[t.code.anchor.pc - 1],
            t.code.anchor.pc - 1,
        );
        switch (exit_attach.resumeOf(&t.code, idx)) {
            .pc => |p| try testing.expectEqual(@as(u32, @intCast(post)), p),
            .refused => return error.TestUnexpectedResult,
        }
        try testing.expect(t.code.exitAttachable(idx));
        // … and exit-side actually served it: counted, wanted, recorded and
        // bound a continuation at the post-loop pc.
        try testing.expect(idx < t.exit_side.len);
        try testing.expectEqual(exit_attach.ExitSide.attached, t.exit_side[idx]);
        try testing.expect(vm.trace.countTracesAt(.{ .proto = t.code.anchor.proto, .pc = @intCast(post), .proto_id = t.code.anchor.proto_id }) >= 1);
    }
    try testing.expect(checked >= 1);
    try testing.expect(vm.trace.exit_side_binds >= 1);
}

test "doc 58 §4.5: a while root's zero-completion own-test exits are exempt only while exit-side serves them" {
    if (comptime !@import("nativegen.zig").is_x64_linux) return error.SkipZigTest;
    // The first 40 instances run three or more trips, which records the
    // `while` root (a loop that never reaches its back-edge cannot record one
    // — LLEAVE). Every later instance runs exactly ONE trip, so its entry runs
    // the body once and fails the own test at the end with zero completions —
    // and no productive receipt follows to clear a penalty (doc 31 D2). The
    // trip count is branch-free arithmetic on purpose: a phase branch in the
    // post-loop code would make the bound child deopt at its OWN exit inside
    // the burst, which exit-side does not serve yet (doc 56 P6-Q3), and the
    // parent exit would rightly give up. Served
    // (native exit-side on, the default), the exit binds
    // a post-loop child and those receipts never strike the anchor. Not
    // served (switch off), they are the enter/exit turnstile the deleted
    // `.low_trip_while` gate stood in front of, and the legacy machine must
    // strike — and here gate — the anchor (B2 review: the policy was keyed on
    // the own test unconditionally, which left it with no protection).
    const gpa = testing.allocator;
    const source =
        \\local s = 0
        \\for i = 1, 2000 do
        \\  local j = 1 + 2 * (40 // i)
        \\  local k = 0
        \\  while k < j do k = k + 1 end
        \\  s = s + k
        \\end
        \\print(s)
    ;
    inline for (.{ true, false }) |served| {
        var vm = try Vm.init(gpa);
        defer vm.deinit();
        // Decomposition mode, as above: keep the `while` its own root.
        vm.trace.config.unroll_fail_flip = 0;
        vm.trace.config.exit_side_native = served;
        var jit_buf: [64]u8 = undefined;
        var jit = io.Writer.fixed(&jit_buf);
        var chunk = try runNativeForTrace(&vm, gpa, source, &jit);
        defer chunk.deinit();
        try testing.expectEqualStrings("2316\n", jit.buffered());

        const header: u32 = for (chunk.proto.code, 0..) |ins, pc| {
            if (ins.op == .loop) break @intCast(pc + 1);
        } else return error.TestUnexpectedResult;
        const key: @import("trace.zig").AnchorKey = .{ .proto = chunk.proto, .pc = header, .proto_id = chunk.proto.id };
        if (served) {
            try testing.expect(vm.trace.exit_side_binds >= 1);
            try testing.expect(!vm.trace.gate.contains(key));
            try testing.expectEqual(@as(u32, 0), vm.trace.penalty.get(key) orelse 0);
        } else {
            try testing.expect(vm.trace.gate.contains(key));
        }
    }
}

test "doc 66 P2: an inlined callee's branch guard is never decoded against the anchor proto" {
    // A guard's source pc lives in the proto it was recorded in: the generic-for
    // iterator below is inlined into main's loop trace, so its wrap test's guard
    // names a pc of the ITERATOR. main's own instruction at that pc is also a
    // `jmp_if_false` (the one-local prefix puts it there; P3's `add_rk` and
    // P4's compare-and-branch each moved the iterator's test up one), so
    // decoding the callee's pc against the
    // anchor proto reads a real branch: the wrap exit was routed as a source
    // branch, raised a prime-side want, and unpatched the loop entry on every
    // wrap (array3d after the field forms shortened its iterator by one op).
    // `TraceCode.anchorSourcePc` answers null for any guard at inline depth > 0.
    const gpa = testing.allocator;
    const source =
        \\local u = 3
        \\local n = 40
        \\local wrap = n and n > 0
        \\local function points(s)
        \\  local y = 0
        \\  return function(s, x)
        \\    x = x + 1
        \\    if x >= s.n then
        \\      x = 0
        \\      y = y + 1
        \\      if y >= s.n then return nil end
        \\    end
        \\    return x, y
        \\  end, s, 0
        \\end
        \\local s = { n = n, sum = 0 }
        \\for x, y in points(s) do
        \\  s.sum = s.sum + x * y
        \\end
        \\print(s.sum, wrap, u)
    ;
    inline for (.{ false, true }) |native| {
        var vm = try Vm.init(gpa);
        defer vm.deinit();
        var buf: [64]u8 = undefined;
        var out = io.Writer.fixed(&buf);
        var chunk = if (native)
            try runNativeForTrace(&vm, gpa, source, &out)
        else
            try runExecForTrace(&vm, gpa, source, &out);
        defer chunk.deinit();
        try testing.expectEqualStrings("608400\ttrue\t3\n", out.buffered());

        // The coincidence this test exists for must still be present: some
        // inlined branch guard whose raw pc decodes to a conditional branch in
        // the anchor proto. If a compiler change moves either `jmp_if_false`,
        // re-align the prefix rather than let the test go vacuous.
        var coincident: usize = 0;
        for (vm.trace.registry.cache.items) |t| {
            for (t.code.instrs, 0..) |ins, i| {
                if (ins.op != .guard_true and ins.op != .guard_false) continue;
                const gp = switch (t.code.provAt(@intCast(i)) orelse continue) {
                    .guard => |g| g,
                    .link_terminal => continue,
                };
                if (gp.inline_depth == 0) continue;
                try testing.expectEqual(@as(?u32, null), t.code.anchorSourcePc(i));
                try testing.expect(!vm.trace.isSourceBranchGuardExit(t, @intCast(i)));
                const raw = trace.guardSourcePc(ins) orelse continue;
                const code = t.code.anchor.proto.code;
                if (raw < code.len and bytecode.condBranchOf(code[raw], raw) != null) coincident += 1;
            }
        }
        try testing.expect(coincident > 0);
    }
}
