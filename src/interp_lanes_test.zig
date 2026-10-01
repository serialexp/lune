//! Tests for `interp.zig` — lanes.
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
const expectProgramTuned = util.expectProgramTuned;
const TraceMode = util.TraceMode;

// ---------------------------------------------------------------------------
// array-of-structs (.value-lane table load) — the bodies[i].x pattern
// ---------------------------------------------------------------------------

test "array-of-structs: read-only loop over .value-lane table array is byte-identical" {
    // A small array of tables with scalar fields — the canonical `bodies[i].x`
    // pattern. The hot loop reads float fields from each element. Before the
    // .value-lane table support, the recorder aborted here (nyi_opcode on
    // get_index); Phase 1 let tier-1a trace the loop, and Phase F (native codegen
    // for .value-lane table loads) now compiles it to x86-64 as well. The 10-mode
    // matrix proves byte-identical output across all tiers.
    try expectProgram(
        \\local bodies = {}
        \\for i = 1, 100 do
        \\  bodies[i] = { x = i * 1.5, y = i * 2.5 }
        \\end
        \\local sx, sy = 0.0, 0.0
        \\for i = 1, 100 do
        \\  local b = bodies[i]
        \\  sx = sx + b.x
        \\  sy = sy + b.y
        \\end
        \\print(sx, sy)
    , "7575\t12625\n");
}

test "integral-float array keys narrow on-trace; fractional keys side-exit to hash semantics" {
    // `j = (2*i)/2` is Lua float division: the key is an integral FLOAT, which
    // tier-0's `normalizeKey` folds to the int slot. The recorder mirrors that
    // with `guard_float` + `int_of_float` (`keyRefNarrowed`) instead of aborting
    // — the fft_bitreverse shape. Every 10th iteration reads a genuinely
    // FRACTIONAL key (`j + 0.5`), which must side-exit the narrow and resolve
    // via tier-0's hash-part semantics (absent → nil → `or 1`). Byte-identical
    // across the 10-mode matrix pins both the fast path and the deopt path.
    try expectProgram(
        \\local v = {}
        \\for i = 1, 128 do v[i] = i end
        \\local s = 0
        \\for i = 1, 120 do
        \\  local j = (2 * i) / 2
        \\  s = s + v[j]
        \\  v[j] = s
        \\  if i % 10 == 0 then
        \\    s = s + (v[j + 0.5] or 1)
        \\  end
        \\end
        \\print(s)
    , "7272\n");
}

test "bit-reversal store/load regions record, compile, and execute natively" {
    const Inspect = struct {
        fn run(vm: *Vm, mode: TraceMode) !void {
            if (mode != .record_execute_native) return;
            var saw_compiled = false;
            var traced: u64 = 0;
            var interpreted: u64 = 0;
            for (vm.trace.registry.cache.items) |t| {
                if (!std.mem.eql(u8, t.code.anchor.proto.name, "bitreverse")) continue;
                switch (t.native) {
                    .compiled => {
                        saw_compiled = true;
                    },
                    else => {},
                }
            }
            var it = vm.trace.coverage.iterator();
            while (it.next()) |entry| {
                if (!std.mem.eql(u8, entry.key_ptr.proto.name, "bitreverse")) continue;
                traced +|= entry.value_ptr.traced;
                interpreted +|= entry.value_ptr.interp;
            }
            // In native mode unsupported traces are declined rather than run by
            // tier-1a. Therefore compiled bitreverse nodes + bitreverse-attributed
            // traced iterations prove that this function actually entered native.
            try testing.expect(saw_compiled);
            try testing.expect(traced > 0);
            try testing.expect(interpreted > 0); // warmup/deopt remains tier-0
        }
    };

    // The recorder may begin at the short inner while and cross the outer body:
    // float-derived indices, four sunk stores, then another swap's loads/stores.
    // This pins the general virtual-store forwarding + alias guards, mixed numeric
    // compare narrowing, and write-only heap temporary boxing as one e2e shape.
    try expectProgramTuned(
        \\local v = {}
        \\local n = 32
        \\for i = 1, 2 * n do v[i] = i end
        \\local function bitreverse()
        \\  local j = 0
        \\  for i = 0, 2 * n - 4, 2 do
        \\    if i < j then
        \\      v[i+1], v[i+2], v[j+1], v[j+2] = v[j+1], v[j+2], v[i+1], v[i+2]
        \\    end
        \\    local k = n
        \\    while k <= j do j = j - k; k = k / 2 end
        \\    j = j + k
        \\  end
        \\end
        \\for rep = 1, 100 do bitreverse() end
        \\print(v[1], v[2 * n])
    , "1\t64\n", .{ .hotguard = 3, .coverage = true, .inspect = Inspect.run });
}

test "array-of-structs: single-field read accumulation across element tables" {
    // A loop that reads one scalar field from each element table in an array,
    // accumulating the values. Exercises the aload(.value, ty=.heap) →
    // guard_table(aload) → href → guard_hash → hload chain — the full
    // array-of-structs read path. No field writes, so no store-sinking
    // interaction. Byte-identical across the 10-mode matrix.
    try expectProgram(
        \\local items = {}
        \\for i = 1, 50 do
        \\  items[i] = { val = i * 1.0 }
        \\end
        \\local total = 0.0
        \\for i = 1, 50 do
        \\  total = total + items[i].val
        \\end
        \\print(total)
    , "1275\n");
}

/// A-viii (doc 17 §A8 step 8): the sieve shape that closes the OUTER cycle
/// `skip → … → cont → skip` — the A-vii-c region shape, scaled until the
/// region-profit gate qualifies the region and `tryArmRegionBridge` actually
/// arms edge 4 (measured: 39 bridge arms / 156 fused bridge hops, peak 3
/// simultaneously-armed links). π(600) = 109.
const aviii_outer_cycle_source: [:0]const u8 =
    \\local count = 0
    \\local flags = {}
    \\for j = 1, 40 do
    \\  count = 0
    \\  for i = 2, 600 do flags[i] = true end
    \\  for i = 2, 600 do
    \\    if flags[i] then
    \\      count = count + 1
    \\      for k = i + i, 600, i do flags[k] = false end
    \\    end
    \\  end
    \\end
    \\print(count)
;

/// The same sieve, with a host-native probe call at the end of each outer
/// iteration. The probe is deliberately OUTSIDE every hot inner loop — it runs
/// on the tier-0 outer body, so it neither perturbs the inner traces nor the
/// region the bridge is armed against; it only observes and, once, flips the
/// observation window open. Same answer: π(600) = 109.
const aviii_mid_epoch_source: [:0]const u8 =
    \\local count = 0
    \\local flags = {}
    \\for j = 1, 40 do
    \\  count = 0
    \\  for i = 2, 600 do flags[i] = true end
    \\  for i = 2, 600 do
    \\    if flags[i] then
    \\      count = count + 1
    \\      for k = i + i, 600, i do flags[k] = false end
    \\    end
    \\    if i == 499 then aviii_probe() end
    \\  end
    \\end
    \\print(count)
;

/// What one A-viii leg observed. Counters are lifetime totals for the run
/// except `peak`, which is the simultaneous high-water mark.
const OuterCycleRun = struct {
    out: [16]u8,
    out_len: usize,
    bridge_arms: u64,
    bridge_fused: u64,
    loopdone_fused: u64,
    disarms: u64,
    peak: usize,
    entries: u64,
    fn output(self: *const OuterCycleRun) []const u8 {
        return self.out[0..self.out_len];
    }
};

/// Run the outer-cycle sieve on a fresh native-JIT VM, with the observation
/// window (`record_safepoint_lines` — the same `!safe_to_arm` predicate a
/// suspend arms) either open for the whole run or closed.
fn runOuterCycle(gpa: std.mem.Allocator, window_open: bool) !OuterCycleRun {
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, aviii_outer_cycle_source, &diags);
    defer tree.deinit();
    try testing.expect(!diags.hasErrors());

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var buf: [16]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;
    vm.source = aviii_outer_cycle_source;
    vm.trace.config.enabled = true;
    vm.trace.config.execute = true;
    vm.trace.config.optimize = true;
    vm.trace.config.native_codegen = true;
    vm.trace.config.hotloop = 4;
    vm.trace.config.hotguard = 3; // close the cross-anchor cycle inside a short run
    vm.record_safepoint_lines = window_open;

    var chunk = try compiler.compile(gpa, vm.heap, aviii_outer_cycle_source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    _ = try vm.run(chunk.proto);

    var result: OuterCycleRun = .{
        .out = undefined,
        .out_len = sink.buffered().len,
        .bridge_arms = vm.trace.native_region_bridge_arms,
        .bridge_fused = vm.trace.native_region_bridge_fused,
        .loopdone_fused = vm.trace.native_loopdone_link_fused,
        .disarms = vm.trace.registry.native_physical.native_link_disarms,
        .peak = vm.trace.registry.native_physical.native_link_peak,
        .entries = vm.trace.entries,
    };
    @memcpy(result.out[0..result.out_len], sink.buffered());
    return result;
}

/// A-viii mid-epoch capture. The window-open event happens INSIDE a running
/// epoch, from a host native, so the only way to observe the registry at that
/// instant is to record it from the native itself; by the time `vm.run` returns
/// the blackout has already erased the evidence.
const AviiiMidEpoch = struct {
    /// Phase 0 → 1: the outer cycle closed and we flipped the window open.
    opened: bool = false,
    /// Snapshot taken at the window-open instant, before the flag is set.
    armed_at_open: usize = 0,
    /// Bitmask over `trace.ArmKind` ordinals present in the registry at open.
    kinds_at_open: u8 = 0,
    /// `(parent.id, child.id)` of every link live at open (capped; the cycle is 3–4).
    edges_at_open: [16][2]u32 = undefined,
    disarms_at_open: u64 = 0,
    native_entries_at_open: u64 = 0,
    /// Phase 1 observations, refreshed on every post-open probe call.
    post_calls: u64 = 0,
    armed_after: usize = 0,
    disarms_after: u64 = 0,
    native_entries_after: u64 = 0,

    fn kindBit(k: trace.ArmKind) u8 {
        return @as(u8, 1) << @intCast(@intFromEnum(k));
    }
    fn hasKind(self: *const AviiiMidEpoch, k: trace.ArmKind) bool {
        return (self.kinds_at_open & kindBit(k)) != 0;
    }
};

/// Single-threaded test state; `zig test` runs the tests in a binary in order on
/// one thread, and `threadlocal` keeps that assumption explicit.
threadlocal var aviii_mid: AviiiMidEpoch = .{};

/// Does the captured `(parent.id, child.id)` edge list contain a directed cycle?
/// Visited-set BFS from each edge's head, asking whether it can reach that
/// edge's tail. With ≤16 edges there are ≤32 distinct node ids, so a queue of 32
/// suffices — but ONLY because a node is marked visited when it is *enqueued*,
/// never when it is dequeued: marking on dequeue lets duplicate endpoints of a
/// branching graph fill the queue before every distinct node is in it, which
/// silently drops reachable nodes and reports a false negative. (Marking on
/// enqueue makes each node enter the queue at most once, so `tail` can never
/// exceed the number of distinct ids.) Neither variant can produce a false
/// positive: every enqueued node sits at the end of a real directed path.
fn capturedGraphHasCycle(edges: []const [2]u32) bool {
    for (edges) |seed| {
        var queue: [32]u32 = undefined; // doubles as the visited set: queue[0..tail]
        var head: usize = 0;
        var tail: usize = 0;
        queue[tail] = seed[1];
        tail += 1;
        while (head < tail) {
            const node = queue[head];
            head += 1;
            if (node == seed[0]) return true; // walked back to the seed's parent
            for (edges) |e| {
                if (e[0] != node) continue;
                var enqueued = false;
                for (queue[0..tail]) |q| {
                    if (q == e[1]) enqueued = true;
                }
                if (enqueued or tail == queue.len) continue;
                queue[tail] = e[1];
                tail += 1;
            }
        }
    }
    return false;
}

/// The host native the A-viii mid-epoch program calls once per outer iteration.
/// It receives `*Vm` (interp.zig's `nat.func(@ptrCast(self), args)` call site),
/// which is exactly the reachability that makes this test possible: a host
/// native CAN flip `record_safepoint_lines` while an epoch and a fully-armed
/// link registry are live. Phase 0 waits for the outer cycle to close, captures
/// it, and opens the window; phase 1 just keeps re-reading the counters so the
/// test can assert against the last post-open observation.
fn aviiiProbe(ctx: *anyopaque, args: []const Value) anyerror!Value {
    _ = args;
    const vm: *Vm = @ptrCast(@alignCast(ctx));
    const m = &aviii_mid;
    if (!m.opened) {
        const links = vm.trace.registry.native_physical.armed_links.items;
        // Wait for a multi-edge cycle to stand: ≥3 links live at once.
        if (links.len < 3 or links.len > m.edges_at_open.len) return Value.nil();
        var kinds: u8 = 0;
        for (links) |l| kinds |= AviiiMidEpoch.kindBit(l.kind);

        m.armed_at_open = links.len;
        m.kinds_at_open = kinds;
        for (links, 0..) |l, i| m.edges_at_open[i] = .{ l.parent.id, l.child.id };
        m.disarms_at_open = vm.trace.registry.native_physical.native_link_disarms;
        m.native_entries_at_open = vm.trace.native_entries;
        m.opened = true;
        // THE EVENT: open the observation window over a live armed registry.
        vm.record_safepoint_lines = true;
        return Value.nil();
    }
    m.post_calls += 1;
    m.armed_after = vm.trace.registry.native_physical.armed_links.items.len;
    m.disarms_after = vm.trace.registry.native_physical.native_link_disarms;
    m.native_entries_after = vm.trace.native_entries;
    return Value.nil();
}

test "A-viii (doc 17 §A8 step 8): opening the window MID-EPOCH over a live armed link cycle tears it down" {
    if (comptime !@import("nativegen.zig").is_x64_linux) return error.SkipZigTest;
    // The same-epoch half of §A8 step 8's oracle, and the one the two-leg test
    // below structurally cannot reach: there, the window is either open for the
    // whole run (so nothing ever arms — the teardown path is never exercised) or
    // closed for the whole run. The interesting transition is *arm the cycle,
    // THEN open the window*, and the reachable trigger for it is a host-installed
    // native: `nat.func(@ptrCast(self), args)` hands every native a `*Vm`, so
    // host code can set `record_safepoint_lines` with an epoch and a full link
    // registry live. (An earlier landing recorded that no such path existed. That
    // was wrong; codex found it, and this test is the correction.)
    //
    // What it pins, all scoped to the window-open EVENT rather than inferred
    // across two whole runs:
    //  1. the registry really did hold a multi-kind link graph containing a
    //     CYCLE at that instant — captured by kind and by `(parent.id,
    //     child.id)`, which a lifetime high-water mark cannot show;
    //  2. after further hot work under the open window the registry is EMPTY and
    //     every captured link was charged a disarm;
    //  3. the run is still trace-driven afterwards (`entries` advances) — the
    //     blackout removes the native→native handoffs, not the traces (R2-4).
    //
    // Scope boundary, stated rather than glossed: the live set captured here is
    // `.link_terminal` + `.loop_done_linked` + `.ordinary_guard`, NOT A-vii's
    // `.region_bridge`. That is measured, not assumed — the probe call is itself
    // a tier-0 effect inside the scan loop, and its presence changes the region
    // shape enough that the profit gate never qualifies the region, so edge 4
    // never arms in the probed variant (`native_region_bridge_arms == 0`), while
    // the unprobed program above arms it 39 times. Every attempted placement of
    // the probe that leaves the bridge armed also finds the registry empty at
    // the call instant — an empirical result, not a causal one: what actually
    // empties it between outer iterations is not pinned down (a region
    // activation is keyed to the frame's `call_seq`, not to one scan-loop
    // invocation, and `closeRegion` drops profitability state without itself
    // disarming a physical link). So the split is: the bridge's *arming and firing*
    // are covered by the two-leg test below, its *teardown* byte-for-byte by the
    // trace.zig unit test (which walks all four `ArmKind`s), and the mid-epoch
    // window transition over a live registry by this test.
    const gpa = testing.allocator;
    aviii_mid = .{};

    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, aviii_mid_epoch_source, &diags);
    defer tree.deinit();
    try testing.expect(!diags.hasErrors());

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var buf: [16]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;
    vm.source = aviii_mid_epoch_source;
    vm.trace.config.enabled = true;
    vm.trace.config.execute = true;
    vm.trace.config.optimize = true;
    vm.trace.config.native_codegen = true;
    vm.trace.config.hotloop = 4;
    vm.trace.config.hotguard = 3;
    // The scope boundary below was measured with native exit adapters OFF
    // (doc 17's arm kinds); with them on (the default since doc 58 B2) the
    // exit-side route reshapes the region and the bridge arms once. The
    // teardown invariant itself, (2), holds either way.
    vm.trace.config.exit_side_native = false;

    const native = try vm.heap.newNative(aviiiProbe, "aviii_probe");
    try vm.globals.set(gpa, try vm.heap.internValue("aviii_probe"), Value.heap(&native.header));

    var chunk = try compiler.compile(gpa, vm.heap, aviii_mid_epoch_source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    _ = try vm.run(chunk.proto);

    // The program computes the same answer whatever the registry did.
    try testing.expectEqualStrings("109\n", sink.buffered());

    const m = &aviii_mid;
    // The premise: the cycle DID close mid-run and we DID flip the window over
    // it. If this ever stops holding the rest of the test is vacuous, so it is
    // an assertion, not a skip.
    try testing.expect(m.opened);
    try testing.expect(m.armed_at_open >= 3);
    // …and it is a genuine multi-kind cycle, not three copies of one edge kind.
    try testing.expect(m.hasKind(.link_terminal));
    try testing.expect(m.hasKind(.loop_done_linked));
    // B-2b can republish the historical ordinary source arm as the equivalent
    // registry-recognized sibling handoff from its persistent provenance edge.
    try testing.expect(m.hasKind(.ordinary_guard) or m.hasKind(.sibling_handoff));
    // …and the captured graph CONTAINS a cycle — at least one native→native
    // handoff that would loop forever without ever returning to the dispatcher
    // if the blackout missed it. (Not every live link need be on the cycle:
    // ramp-in edges into the cycle are armed too, and the measured capture is
    // exactly that shape — a 2-cycle plus a feeder.)
    try testing.expect(capturedGraphHasCycle(m.edges_at_open[0..m.armed_at_open]));

    // Real hot work ran after the flip — the teardown is not being read off an
    // immediately-terminating program.
    try testing.expect(m.post_calls >= 2);
    // (2) the whole registry is gone, and EXACTLY the captured edges were
    // charged: once the window is open `safe_to_arm` is false forever after, so
    // nothing can re-arm and the first blackout charges the captured set and
    // nothing else. An inequality here would tolerate a re-arm/re-disarm churn
    // that the invariant forbids.
    try testing.expectEqual(@as(usize, 0), m.armed_after);
    try testing.expectEqual(@as(u64, m.armed_at_open), m.disarms_after - m.disarms_at_open);
    // (3) still running NATIVE trace bodies under the open window, entered
    // through the dispatcher every time. `entries` alone would not carry this:
    // it is bumped before the native-vs-tier-1a choice, so a run that fell back
    // to the IR interpreter for every entry would still advance it. R2-4's claim
    // is specifically that the blackout removes the native→native handoffs, not
    // the native bodies — hence `native_entries`.
    try testing.expect(m.native_entries_after > m.native_entries_at_open);
    // (4) the documented scope boundary, pinned rather than only asserted in
    // prose: the probe's presence really does keep edge 4 from arming in this
    // variant, which is why the live set above has no `.region_bridge` in it.
    // If a future change makes the bridge survive a probed region, this fails
    // and the comment above must be revisited (a good failure to get).
    try testing.expectEqual(@as(u64, 0), vm.trace.native_region_bridge_arms);
}

test "A-viii (doc 17 §A8 step 8): the OUTER cycle arms as a closed cycle and fires; an open observation window contains it" {
    if (comptime !@import("nativegen.zig").is_x64_linux) return error.SkipZigTest;
    // §A8 step 8's oracle (round-3 review finding 4), in the terms the tree can
    // actually observe. The 2c-F test covers the INNER cycle (`C↔I`) across an
    // epoch boundary; this covers the OUTER cycle `skip → … → cont → skip`,
    // whose closing edge is A-vii's composite bridge (edge 4).
    //
    // The pair of legs is the test:
    //  * **Window closed (the positive leg):** the outer cycle must actually
    //    close and fire — a `.region_bridge` arm, fused bridge hops, and fused
    //    loop-done hops. (These are lifetime totals and cannot by themselves
    //    tell a standing closed cycle from edges armed and torn down in turn;
    //    the mid-epoch test above is what pins simultaneity, by capturing the
    //    live registry's kinds and `(parent, child)` ids at one instant.)
    //  * **Window open (the containment leg / negative control):** with
    //    `!safe_to_arm` the dispatcher must leave the whole registry empty —
    //    NOTHING arms (peak 0, zero bridge arms) — so no native→native handoff
    //    can fire through a patched slot and skip the dispatcher's
    //    safepoint/GC boundary. Per R2-4 that is NOT a collapse to tier-0
    //    bodies: traces still run, reached through the dispatcher every time,
    //    which is what `entries > 0` on this leg pins.
    // Both legs print the same answer, so containment is output-transparent.
    const gpa = testing.allocator;
    const armed = try runOuterCycle(gpa, false);
    const contained = try runOuterCycle(gpa, true);

    // (1) Output identity: containment cannot change what the program computes.
    try testing.expectEqualStrings("109\n", armed.output());
    try testing.expectEqualStrings("109\n", contained.output());

    // (2) Positive leg: the outer cycle is real, closed, and hot.
    try testing.expect(armed.bridge_arms > 0); // edge 4 armed at least once
    try testing.expect(armed.bridge_fused > 0); // …and a fused bridge hop ran
    try testing.expect(armed.loopdone_fused > 0); // …as did the inner loop-done edge
    try testing.expect(armed.peak >= 3); // …and ≥3 links were live at once at some point
    try testing.expect(armed.entries > 0);

    // (3) Containment leg: an open window keeps the registry empty for the whole
    // run — nothing armed, so nothing could fire through a stale slot.
    try testing.expectEqual(@as(u64, 0), contained.bridge_arms);
    try testing.expectEqual(@as(u64, 0), contained.bridge_fused);
    try testing.expectEqual(@as(u64, 0), contained.loopdone_fused);
    try testing.expectEqual(@as(usize, 0), contained.peak);
    // Nothing to tear down, so the disarm path never charges a slot either.
    try testing.expectEqual(@as(u64, 0), contained.disarms);

    // (4) …and the contained run is still trace-driven, NOT collapsed to tier-0
    // bodies (R2-4): traces still run, reached through the dispatcher every time.
    // Only the *existence* of dispatcher-mediated trace entries is asserted here.
    // Comparing the two legs' `entries` totals would NOT be sound — the legs
    // select different traces (the armed leg's fused hops change which exits are
    // ever taken, hence which side traces get recorded at all), so neither
    // direction of the inequality is a law. The event-scoped version of this
    // claim — `entries` advancing *after* a mid-run blackout within one run — is
    // in the mid-epoch test above, where both sides of the comparison come from
    // the same selection history.
    try testing.expect(contained.entries > 0);
}

test "doc 20 §T (Phase 1 e2e): a qualified hot loop actually installs and binds an entry patch; output byte-identical to tier-0" {
    // The Phase-0b substrate tests exercise `installEntryPatch` by hand; this
    // is the pin that THE FLIP flips in production: a plain hot numeric-`for`
    // under native codegen qualifies through the `accountTraceRun` funnel,
    // the epilogue drain installs, and the patch stays bound at run end —
    // with output identical to a tier-0 run of the same program.
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    const gpa = testing.allocator;
    const source: [:0]const u8 =
        \\local s = 0
        \\for r = 1, 200 do
        \\  for i = 1, 100 do s = s + i end
        \\end
        \\print(s)
    ;

    var out_jit: [16]u8 = undefined;
    var out_len: usize = 0;
    {
        var diags = diag.Diagnostics.init(gpa);
        defer diags.deinit();
        var tree = try parser.parse(gpa, source, &diags);
        defer tree.deinit();
        var vm = try Vm.init(gpa);
        defer vm.deinit();
        var sink = io.Writer.fixed(&out_jit);
        vm.out = &sink;
        vm.trace.config.enabled = true;
        vm.trace.config.execute = true;
        vm.trace.config.optimize = true;
        vm.trace.config.native_codegen = @import("nativegen.zig").is_x64_linux;
        vm.trace.config.hotloop = 4;
        var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
        defer chunk.deinit();
        try testing.expect(!diags.hasErrors());
        _ = try vm.run(chunk.proto);
        out_len = sink.buffered().len;

        if (@import("nativegen.zig").is_x64_linux) {
            // The flip flipped: at least one slot was created and is still a
            // live binding whose trace reached `.bound`.
            try testing.expect(vm.trace.registry.entry_registry.entry_patches.items.len > 0);
            var bound: usize = 0;
            for (vm.trace.registry.entry_registry.entry_patches.items) |p| {
                if (p.tombstone or !p.live) continue;
                const t = vm.trace.traceById(p.trace_id) orelse continue;
                if (t.entry_patch == .bound) bound += 1;
            }
            try testing.expect(bound > 0);
        }
    }

    // Tier-0 reference: byte-identical output.
    var out_t0: [16]u8 = undefined;
    {
        var diags = diag.Diagnostics.init(gpa);
        defer diags.deinit();
        var tree = try parser.parse(gpa, source, &diags);
        defer tree.deinit();
        var vm = try Vm.init(gpa);
        defer vm.deinit();
        var sink = io.Writer.fixed(&out_t0);
        vm.out = &sink;
        var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
        defer chunk.deinit();
        try testing.expect(!diags.hasErrors());
        _ = try vm.run(chunk.proto);
        try testing.expectEqualStrings(sink.buffered(), out_jit[0..out_len]);
        try testing.expectEqualStrings("1010000\n", sink.buffered());
    }
}

test "doc 20 Phase 3: while/repeat jloop patches bind and stay byte-identical across all 10 modes" {
    const Inspect = struct {
        fn run(vm: *Vm, mode: TraceMode) !void {
            if (mode != .record_execute_native or !@import("nativegen.zig").is_x64_linux) {
                // Qualification is native-only; all other matrix legs keep the
                // canonical code image and registry untouched.
                try testing.expectEqual(@as(usize, 0), vm.trace.registry.entry_registry.entry_patches.items.len);
                return;
            }
            // Doc 58: both loops are patched at their `loop` MARKER, so the
            // canonical op under every live patch is `.loop`; the kind in `.b`
            // says which loop it is.
            var saw_while = false;
            var saw_repeat = false;
            for (vm.trace.registry.entry_registry.entry_patches.items) |p| {
                if (p.tombstone or !p.live) continue;
                try testing.expectEqual(bytecode.OpCode.jloop, vm.trace.codeFor(p.proto)[p.patch_pc].op);
                if (p.orig.op != .loop) continue;
                // The marker's header is the trace's anchor.
                try testing.expectEqual(
                    @as(?u32, @intCast(p.patch_pc + 1)),
                    bytecode.loopHeaderOf(p.orig, p.patch_pc),
                );
                switch (@as(bytecode.LoopKind, @enumFromInt(p.orig.b))) {
                    .while_loop => saw_while = true,
                    .repeat_loop => saw_repeat = true,
                }
            }
            try testing.expect(saw_while);
            try testing.expect(saw_repeat);
        }
    };

    // Long, general integer loops ensure each compiler-emitted closer records,
    // compiles, qualifies, and remains bound long enough for inspection. The
    // ten-mode matrix is the determinism/GC gate; the callback pins THE flip.
    try expectProgramTuned(
        \\local i = 0
        \\local a = 0
        \\while i < 300 do
        \\  i = i + 1
        \\  a = a + i
        \\end
        \\local j = 0
        \\local b = 0
        \\repeat
        \\  j = j + 1
        \\  b = b + j
        \\until j >= 300
        \\print(a, b)
    , "45150\t45150\n", .{ .inspect = Inspect.run });
}

test "doc 20 Phase 3: a recording crossing a jloop pc mirrors the canonical jump" {
    var code: [4]Instr = @splat(Instr.op0(.ret));
    code[2] = .{ .op = .jmp_if_false, .a = 7, .aux = -3 };
    const proto = bytecode.Proto{ .code = &code, .id = 77, .name = "mirror", .num_registers = 8 };
    var fetched = code[2];
    fetched.op = .jloop;
    fetched.b = 42;

    const mirrored = interp.recordingMirrorInstr(&proto, 2, fetched);
    try testing.expect(std.meta.eql(code[2], mirrored));
    try testing.expectEqual(bytecode.OpCode.jmp_if_false, mirrored.op);
    // Ordinary instructions stay zero-copy/value-identical through the helper.
    try testing.expect(std.meta.eql(code[0], interp.recordingMirrorInstr(&proto, 0, code[0])));
}

test "doc 20 Phase 3: jloop prologue strike exhaustion unpatches same-turn" {
    if (comptime !@import("nativegen.zig").is_x64_linux) return error.SkipZigTest;
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    const gpa = testing.allocator;
    const source: [:0]const u8 =
        \\local function f(x, n)
        \\  local i = 0
        \\  while i < n do
        \\    i = i + 1
        \\    x = x + i
        \\  end
        \\  return x
        \\end
        \\print(f(0, 200))
        \\print(f(0.5, 1))
    ;

    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var out: [32]u8 = undefined;
    var sink = io.Writer.fixed(&out);
    vm.out = &sink;
    vm.trace.config.enabled = true;
    vm.trace.config.execute = true;
    vm.trace.config.optimize = true;
    vm.trace.config.native_codegen = true;
    vm.trace.config.hotloop = 4;
    vm.trace.config.patch_strikes = 1;
    var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    _ = try vm.run(chunk.proto);
    try testing.expectEqualStrings("20100\n1.5\n", sink.buffered());

    // The int-specialized binding installed during the first call. The float
    // second call fails its native prologue at the patched while MARKER (doc
    // 58); with a one-strike budget the common patched-entry tail must restore
    // `.loop` and tombstone the slot before the terminal condition exits.
    var saw_exhausted_while = false;
    for (vm.trace.registry.entry_registry.entry_patches.items) |p| {
        if (p.orig.op != .loop or !p.tombstone) continue;
        if (@as(bytecode.LoopKind, @enumFromInt(p.orig.b)) != .while_loop) continue;
        try testing.expect(std.meta.eql(p.orig, vm.trace.codeFor(p.proto)[p.patch_pc]));
        saw_exhausted_while = true;
    }
    try testing.expect(saw_exhausted_while);
}

// ---------------------------------------------------------------------------
// doc 32: `.value`-lane SCALAR access (int/float elements)
// ---------------------------------------------------------------------------

/// Doc 32 harness: the full 10-leg parity matrix via `expectProgram`, PLUS one
/// dedicated record+execute leg that pins the loop actually committed a trace.
///
/// The regression risk this arc carries is precisely a *silent* return to the
/// old behaviour: if `arrayGetShape`/`arraySetShape` went back to aborting on
/// `.value` elements, every program below would still print the right answer
/// (tier-0 handles them fine) and parity alone would stay green. `entries > 0`
/// is what makes the coverage claim testable rather than assumed.
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

test "doc 32: a read loop over an int/float-mixed array records and stays byte-identical" {
    // `a` is built as a pure int array (the `.i32`-ish narrow lane), then one
    // float store erases it to `.value` — `array.zig widenFor` has no int->f64
    // rung, and cannot grow one without destroying mahina's observable int/float
    // distinction. Before doc 32 the read loop then aborted `.nyi_opcode` on
    // every element and the whole loop fell back to tier-0 for the run.
    //
    // The sum mixes an int accumulator path with the one float element, so a
    // codegen bug that loaded the float's payload as an int (or vice versa)
    // changes the printed value rather than merely running slower.
    try expectRecordedProgram(
        \\local a = {}
        \\for i = 1, 200 do a[i] = i end
        \\a[7] = 0.5
        \\local s = 0.0
        \\for i = 1, 200 do s = s + a[i] end
        \\print(s)
    , "20093.5\n");
}

test "doc 32: a read-modify-write loop over a `.value` array records both directions" {
    // Exercises the *store* half against the same array the load half reads:
    // `a[i] = a[i] + 1` is an `aload` feeding an `astore` on a `.value` lane.
    // The stored value alternates int (for the 99 int elements) and float (for
    // the one seeded float), so the `astore` must write the correct tag byte
    // per iteration rather than assuming the lane's element kind is uniform.
    // A stale tag would make the next read reinterpret the payload and skew
    // the total.
    try expectRecordedProgram(
        \\local a = {}
        \\for i = 1, 100 do a[i] = i end
        \\a[3] = 1.5
        \\for r = 1, 20 do
        \\  for i = 1, 100 do a[i] = a[i] + 1 end
        \\end
        \\local s = 0.0
        \\for i = 1, 100 do s = s + a[i] end
        \\print(s)
    , "7048.5\n");
}

test "doc 32: the spectral-norm shape — int-initialised array later written as float" {
    // The exact shape that motivated the arc, minimised. `u` is initialised
    // with integer 1s and subsequently only ever holds floats; the array is
    // `.value` from the first float store onward and `narrow => frozen` means
    // it can never re-narrow. Every later loop touching `u` therefore depends
    // on `.value` scalar access being recordable.
    try expectRecordedProgram(
        \\local u = {}
        \\for i = 1, 100 do u[i] = 1 end
        \\for i = 1, 100 do u[i] = u[i] * 1.0 + 0.5 end
        \\local s = 0.0
        \\for i = 1, 100 do s = s + u[i] end
        \\print(s)
    , "150\n");
}

test "doc 33: alternating value and f64 lanes refuse a candidate without gating the anchor" {
    const source: [:0]const u8 =
        \\local value_lane = {}
        \\local f64_lane = {}
        \\for i = 1, 64 do
        \\  value_lane[i] = i
        \\  f64_lane[i] = i * 2.0
        \\end
        \\value_lane[1] = 0.5
        \\local function lane_sum(a)
        \\  local s = 0.0
        \\  for i = 1, 64 do s = s + a[i] end
        \\  return s
        \\end
        \\local x, y = 0.0, 0.0
        \\for r = 1, 48 do
        \\  x = lane_sum(value_lane)
        \\  y = lane_sum(f64_lane)
        \\end
        \\print(x, y)
    ;
    const expected = "2079.5\t4160\n";

    // Full ten-leg byte-equivalence matrix plus the helper's trace-recording
    // proof, then a native leg where hoisted lane guards can actually refuse.
    try expectRecordedProgram(source, expected);

    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var buf: [256]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    var chunk = try util.runNativeForTrace(&vm, gpa, source, &sink);
    defer chunk.deinit();
    try testing.expectEqualStrings(expected, sink.buffered());

    var saw_lane_anchor = false;
    for (vm.trace.registry.cache.items) |t| {
        if (!std.mem.eql(u8, t.code.anchor.proto.name, "lane_sum")) continue;
        saw_lane_anchor = true;
        try testing.expect(!vm.trace.isGated(t.code.anchor));
    }
    try testing.expect(saw_lane_anchor);
}
