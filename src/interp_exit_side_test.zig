//! Doc 56 (exit-started side traces): end-to-end shape tests.
//!
//! Phase 0 pins TODAY's behaviour on the fft bit-reverse reduction, so each
//! later phase has a measured before/after. The residency assertion below
//! states the current (bad) reading on purpose; the phase that makes the
//! loop run as traces flips it to the doc 56 §9 target (≥ 90% traced).
//! Shared harness lives in `interp_testutil.zig`.

const std = @import("std");
const interp = @import("interp.zig");
const testing = std.testing;

const Vm = interp.Vm;
const trace_ir = @import("trace_ir.zig");
const compiler = @import("compiler.zig");
const io = @import("io.zig");
const exit_attach = @import("trace_exit_attach.zig");
const nativegen = @import("nativegen.zig");
const trace_exec = @import("trace_exec.zig");
const value = @import("value.zig");
const table = @import("table.zig");
const RegWindow = @import("regwindow.zig").RegWindow;
const CompositeWalk = @import("trace_code.zig").CompositeWalk;

const util = @import("interp_testutil.zig");
const expectProgramTuned = util.expectProgramTuned;
const TraceMode = util.TraceMode;

/// The fft_bitreverse kernel (`bench/luajit/scimark_lib.lua:178`) at the
/// bench's size, n = 1024. Smaller n does NOT reproduce the fft shape: at
/// n <= 128 the outer loop still reaches ~40–50% traced, because there are
/// fewer inner trip counts, and so fewer whole-iteration sibling shapes (doc
/// 55 §3 "Finding"). The data are floats, as in fft. 30 bit-reversals is an
/// even count, so the vector ends where it started.
const bitreverse_src =
    \\local function bitreverse(v, n)
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
    \\local n = 1024
    \\local v = {}
    \\for i = 1, 2 * n do v[i] = i * 0.5 end
    \\for rep = 1, 30 do bitreverse(v, n) end
    \\print(v[1], v[2 * n])
;

test "doc 58: fft bit-reverse runs mostly traced at both hot anchors (doc 56 §9 target)" {
    // The arc's headline coverage claim, and the reason doc 58 exists. Doc 55
    // §3 measured both hot anchors of this kernel under 10% traced, and doc 56
    // Phase 0 pinned that as a baseline. What was in the way: the inner
    // `while`'s exit could not be served by a side trace, because its condition
    // guard sat at the TOP of the trace and was owned by the doc 38 while-done
    // chain instead of being an ordinary, attachable exit.
    //
    // Doc 58 moves the condition to the END of the trace (LuaJIT's `BC_LOOP`
    // shape), so exit-side serves it like any other exit. Measured here: the
    // outer `for` goes 0.2% → 83.4% traced, the inner `while` 36.8% → 75.7%.
    // Iteration counts are deterministic, so these are real thresholds, not
    // timing.
    const Inspect = struct {
        fn run(vm: *Vm, mode: TraceMode) !void {
            if (mode != .record_execute_native) return;
            // The two loop headers, named from the bytecode: the outer `for`'s
            // (its `for_loop`'s backward target) and the inner `while`'s (the
            // instruction after its `loop` marker). The exit-side continuation
            // the `while`'s exit records at the post-loop pc is also a hot
            // anchor, so counting "hot anchors" could let it stand in for
            // one of these.
            var proto: ?*const @import("bytecode.zig").Proto = null;
            var it = vm.trace.coverage.iterator();
            while (it.next()) |entry| {
                if (std.mem.eql(u8, entry.key_ptr.proto.name, "bitreverse")) proto = entry.key_ptr.proto;
            }
            const p = proto orelse return error.TestUnexpectedResult;
            var for_header: ?u32 = null;
            var while_header: ?u32 = null;
            for (p.code, 0..) |ins, pc| switch (ins.op) {
                .for_loop => {
                    try testing.expect(for_header == null);
                    for_header = @intCast(@as(i64, @intCast(pc)) + 1 + ins.aux);
                },
                .loop => {
                    try testing.expect(while_header == null);
                    while_header = @intCast(pc + 1);
                },
                else => {},
            };
            for ([_]?u32{ for_header, while_header }) |h| {
                const cov = vm.trace.coverage.get(.{ .proto = p, .pc = h.?, .proto_id = p.id }) orelse
                    return error.TestUnexpectedResult;
                const total = cov.traced + cov.interp;
                try testing.expect(total >= 1000); // genuinely hot
                try testing.expect(cov.traced * 2 > total); // majority traced
            }
        }
    };
    try expectProgramTuned(bitreverse_src, "0.5\t1024\n", .{
        .coverage = true,
        .exit_side_native = true,
        .inspect = Inspect.run,
    });
}

/// A recorded-only (no execute, optimizer on) run: the VM plus the compiled
/// chunk, which must outlive every inspection (trace anchors point into it).
const Recorded = struct {
    gpa: std.mem.Allocator,
    vm: *Vm,
    chunk: compiler.Chunk,

    fn init(gpa: std.mem.Allocator, source: [:0]const u8, expected: []const u8) !Recorded {
        const parser = @import("parser.zig");
        const diag = @import("diag.zig");
        const vm = try gpa.create(Vm);
        errdefer gpa.destroy(vm);
        vm.* = try Vm.init(gpa);
        errdefer vm.deinit();
        var diags = diag.Diagnostics.init(gpa);
        defer diags.deinit();
        var tree = try parser.parse(gpa, source, &diags);
        defer tree.deinit();
        vm.trace.config.enabled = true;
        vm.trace.config.execute = false;
        vm.trace.config.optimize = true;
        vm.trace.config.hotloop = 4;
        var buf: [256]u8 = undefined;
        var sink = io.Writer.fixed(&buf);
        vm.out = &sink;
        var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
        errdefer chunk.deinit();
        try testing.expect(!diags.hasErrors());
        _ = try vm.run(chunk.proto);
        vm.out = null;
        try testing.expectEqualStrings(expected, sink.buffered());
        return .{ .gpa = gpa, .vm = vm, .chunk = chunk };
    }

    fn deinit(self: *Recorded) void {
        self.vm.deinit();
        self.gpa.destroy(self.vm);
        self.chunk.deinit();
    }
};

test "doc 56 Phase 1: ordinary traces carry sparse exit snapshots of bytecode-LIVE slots only" {
    const gpa = testing.allocator;
    // `dead` is written every iteration and never read: bytecode liveness
    // must keep it out of every snapshot, so `tropt` still deletes its `mul`.
    // `acc` is loop-carried and read later: it must be captured once written.
    // The table read guards give the trace side exits with snapshots.
    const source =
        \\local t = {}
        \\for i = 1, 64 do t[i] = i end
        \\local acc = 0
        \\for i = 1, 64 do
        \\  local dead = i * 3
        \\  acc = acc + t[i]
        \\end
        \\print(acc)
    ;
    var rec = try Recorded.init(gpa, source, "2080\n");
    defer rec.deinit();
    const vm = rec.vm;

    var saw_snap_trace = false;
    for (vm.trace.registry.cache.items) |t| {
        const c = &t.code;
        const proto = c.anchor.proto;
        for (c.instrs) |ins| try testing.expect(ins.op != .mul); // `dead` DCE'd
        if (c.exit_snap_by_ord.len == 0) continue;
        saw_snap_trace = true;
        try testing.expect(proto.reg_live.available());
        try testing.expectEqual(@as(trace_ir.SnapIdx, 0), c.exit_snap_by_ord[0]);
        // Every captured slot is live in the bytecode at its resume pc, and
        // names a committed instruction.
        for (c.exit_snapshots) |s| {
            for (c.exit_snapshot_slots[s.slots_begin..][0..s.slots_len]) |ss| {
                try testing.expect(proto.reg_live.liveIn(s.resume_pc, ss.slot));
                try testing.expect(ss.ref < c.instrs.len);
            }
        }
        // Every side-exit guard carries an in-range ordinal, and at least one
        // guard resolves to a snapshot.
        var guards_with_snap: usize = 0;
        for (c.instrs) |ins| {
            try testing.expect(ins.ord < c.exit_snap_by_ord.len);
            if (trace_ir.isSideExitGuardOp(ins.op) and ins.ord != 0 and c.exit_snap_by_ord[ins.ord] != 0) guards_with_snap += 1;
        }
        try testing.expect(guards_with_snap > 0);
    }
    try testing.expect(saw_snap_trace);
}

test "doc 56 Phase 1: a compiled trace maps every exit-snapshot value, carried home and sunk-store read" {
    if (comptime !nativegen.is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    // The inner loop has side exits (the `t[i] > 32` branch, the table
    // reads) with snapshots, a carried accumulator, and a store to `u`.
    const source =
        \\local t, u = {}, {}
        \\for i = 1, 64 do t[i] = i; u[i] = 0 end
        \\local acc = 0
        \\for i = 1, 64 do
        \\  local x = t[i]
        \\  if x > 32 then acc = acc + x else acc = acc - 1 end
        \\  u[i] = acc
        \\end
        \\print(acc)
    ;
    var rec = try Recorded.init(gpa, source, "1520\n");
    defer rec.deinit();
    const vm = rec.vm;

    var saw_map = false;
    for (vm.trace.registry.cache.items) |t| {
        const c = &t.code;
        if (c.exit_snapshots.len == 0) continue;
        const ct = vm.trace.nativeFor(t) orelse continue;
        const m = &ct.exit_locs;
        saw_map = true;
        // One row per value, strictly sorted by ref.
        for (1..m.values.len) |vi| try testing.expect(m.values[vi - 1].ref < m.values[vi].ref);
        // Every value a snapshot restores has a row; a constant is always
        // recoverable.
        for (c.exit_snapshot_slots) |ss| {
            const row = m.find(ss.ref) orelse return error.SnapshotRefUnmapped;
            if (c.instrs[ss.ref].op == .konst) try testing.expectEqual(nativegen.ExitLoc.Tag.konst, row.tag);
        }
        // Every carried home names a real place for its entry load.
        for (m.carried) |h| {
            const row = m.find(h.ref) orelse return error.CarriedHomeUnmapped;
            try testing.expectEqual(trace_ir.IrOp.slot_load, c.instrs[h.ref].op);
            try testing.expect(row.tag != .none and row.tag != .konst);
            try testing.expectEqual(nativegen.ExitLoc.LIVE_WHOLE_BODY, row.live_until);
        }
        // Every sunk store below an exit has its operands mapped.
        var first_exit: ?usize = null;
        for (0..c.instrs.len) |i| if (c.exitSnapIdx(i) != null) {
            first_exit = i;
            break;
        };
        if (first_exit) |fe| for (c.instrs[fe + 1 ..], fe + 1..) |ins, i| switch (ins.op) {
            .astore, .hstore, .ustore, .gstore, .sgm_setpos => {
                try testing.expect(m.find(ins.a) != null);
                try testing.expect(m.find(ins.b) != null);
                // The value is still held at every exit above the store.
                for (fe..i) |e| {
                    if (c.exitSnapIdx(e) != null and ins.b < e) try testing.expect(m.at(ins.b, e) != null);
                }
            },
            else => {},
        };
    }
    try testing.expect(saw_map);
}

test "doc 56 Phase 2: bit-reverse's while-exit is attachable and resumes after the while" {
    const gpa = testing.allocator;
    // The fft kernel, small: only the recorded root at the `for` matters.
    const source =
        \\local function bitreverse(v, n)
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
        \\local n = 64
        \\local v = {}
        \\for i = 1, 2 * n do v[i] = i * 0.5 end
        \\for rep = 1, 2 do bitreverse(v, n) end
        \\print(v[1], v[2 * n])
    ;
    var rec = try Recorded.init(gpa, source, "0.5\t64\n");
    defer rec.deinit();
    const vm = rec.vm;

    var attachable: usize = 0;
    var after_while: usize = 0;
    for (vm.trace.registry.cache.items) |t| {
        const c = &t.code;
        const proto = c.anchor.proto;
        for (0..c.instrs.len) |e| {
            // The commit-time memo is the oracle's answer.
            try testing.expectEqual(exit_attach.classify(c, e) == .attachable, c.exitAttachable(e));
            const p = c.exitResumePc(e) orelse continue;
            attachable += 1;
            try testing.expect(p < proto.code.len);
            // No backward jump lands on `P`: it is not a loop header.
            for (proto.code, 0..) |ins, pc| switch (ins.op) {
                .jmp, .jmp_if_true, .jmp_if_false, .jmp_if_not_nil, .for_loop, .tfor_loop => {
                    const target: i64 = @as(i64, @intCast(pc)) + 1 + ins.aux;
                    try testing.expect(!(target <= pc and target == p));
                },
                else => {},
            };
            const snap = c.exit_snapshots[c.exitSnapIdx(e).? - 1];
            const b = snap.resume_pc;
            switch (proto.code[b].op) {
                .jmp_if_true, .jmp_if_false => {
                    // A branch resumes at one of its successors, and every
                    // slot live there was live at the branch, so the
                    // branch's snapshot covers it.
                    const target: i64 = @as(i64, b) + 1 + proto.code[b].aux;
                    try testing.expect(p == b + 1 or p == target);
                    for (0..proto.num_registers) |r| {
                        if (proto.reg_live.liveIn(p, @intCast(r)))
                            try testing.expect(proto.reg_live.liveIn(b, @intCast(r)));
                    }
                    // The while's exit edge: its target follows the
                    // while's backward `jmp`. That is `j = j + k`.
                    if (p == target and p >= 1 and proto.code[p - 1].op == .jmp and
                        @as(i64, p) + proto.code[p - 1].aux < p)
                        after_while += 1;
                },
                // Every other exit re-executes its own bytecode.
                else => try testing.expectEqual(b, p),
            }
        }
    }
    try testing.expect(attachable > 0);
    try testing.expect(after_while > 0);
}

fn isExecuteMode(mode: TraceMode) bool {
    return mode == .record_execute or mode == .record_execute_noopt or mode == .record_execute_native;
}

/// The oracle for a `.link` terminal's `LinkKind`: `.enclosing_iteration`
/// exactly when the loop headed at the link target CONTAINS the anchor — so
/// one run to the `.link` finishes one iteration of it.
///
/// Deliberately NOT `bytecode.loopExtentFor` (B2 review should-fix: the
/// implementation asks that, so a wrong extent would make implementation and
/// oracle agree). Containment here is the textbook natural loop of the
/// proto's CFG (`naturalLoopContains`), which knows nothing of loop shapes.
/// Returns how many links are `.enclosing_iteration`.
fn expectLinkKindsMatchLoops(vm: *Vm) !usize {
    var enclosing: usize = 0;
    for (vm.trace.registry.cache.items) |t| {
        const c = &t.code;
        const n = c.instrs.len;
        if (n == 0 or c.instrs[n - 1].op != .link) continue;
        const target: u32 = @intCast(c.instrs[n - 1].aux);
        const contains = try naturalLoopContains(testing.allocator, c.anchor.proto, target, c.anchor.pc);
        try testing.expectEqual(contains, c.linkClosesIteration());
        enclosing += @intFromBool(contains);
    }
    return enclosing;
}

/// Does the loop headed at `h` contain pc `a`? "The loop headed at `h`" is
/// the SMALLEST natural loop whose body contains `h`: every back edge
/// `t → hd` (`hd` dominates `t`) has the body `{hd}` plus every pc that
/// reaches `t` without passing `hd`. False when no loop contains `h`. Quadratic
/// in the proto's size — test protos only.
fn naturalLoopContains(gpa: std.mem.Allocator, proto: *const @import("bytecode.zig").Proto, h: u32, a: u32) !bool {
    const succOf = @import("bc_liveness.zig").successors;
    const code = proto.code;
    try testing.expect(proto.dom.available());
    var body = try std.DynamicBitSetUnmanaged.initEmpty(gpa, code.len);
    defer body.deinit(gpa);
    var work: std.ArrayListUnmanaged(u32) = .empty;
    defer work.deinit(gpa);
    var best: usize = std.math.maxInt(usize);
    var contains = false;
    for (code, 0..) |tail_ins, tail| for (succOf(tail_ins, @intCast(tail), code.len)) |s| {
        const hd = s orelse continue;
        if (!proto.dom.dominates(hd, @intCast(tail))) continue; // not a back edge
        body.unsetAll();
        body.set(hd);
        work.clearRetainingCapacity();
        if (!body.isSet(tail)) {
            body.set(tail);
            try work.append(gpa, @intCast(tail));
        }
        while (work.pop()) |x| {
            // Predecessors of `x`, by scanning every edge.
            for (code, 0..) |p_ins, p| for (succOf(p_ins, @intCast(p), code.len)) |ps| {
                if (ps != x or body.isSet(p)) continue;
                body.set(p);
                try work.append(gpa, @intCast(p));
            };
        }
        if (h >= code.len or !body.isSet(h)) continue;
        const size = body.count();
        if (size < best) {
            best = size;
            contains = a < code.len and body.isSet(a);
        }
    };
    return contains;
}

test "doc 56 Phase 3: a continuation that closes at its enclosing loop tags its link as an iteration" {
    // The post-`while` continuation (`j = j + k`, then the `for` back-edge)
    // links to the `for` root that CONTAINS it (LuaJIT `LJ_TRLINK_ROOT`):
    // one run to its `.link` finishes an iteration of that `for`. A ramp
    // into the inner `while` root keeps the doc 15 `.inner_root` kind.
    const Inspect = struct {
        fn run(vm: *Vm, mode: TraceMode) !void {
            const enclosing = try expectLinkKindsMatchLoops(vm);
            // Continuations only arm off EXECUTED exits. Doc 58: the inner
            // `while`'s exit is an ordinary exit now, so the continuation is
            // recorded by the exit-side route — which on the native leg needs
            // the adapters, hence `exit_side_native` below.
            if (isExecuteMode(mode)) try testing.expect(enclosing > 0);
        }
    };
    try expectProgramTuned(
        \\local n = 32
        \\local cnt = 0
        \\local function f()
        \\  local j = 0
        \\  for i = 0, 2 * n - 4, 2 do
        \\    if i < j then cnt = cnt + 1 end
        \\    local k = n
        \\    while k <= j do j = j - k; k = k / 2 end
        \\    j = j + k
        \\  end
        \\end
        \\for rep = 1, 20 do f() end
        \\print(cnt)
    , "240\n", .{ .exit_side_native = true, .inspect = Inspect.run });
}

test "doc 56 Phase 3: an exit materialized past a sunk store applies that store first" {
    // `t[1] = t[1] + i` is a read-modify-write, so the root sinks its
    // `astore` below every guard. The `i % 3 == 0` exit sits AFTER that
    // store's bytecode: materializing it must apply the store before the
    // resume at the then-branch, which reads `t[1]` (and the next iteration
    // adds to it). Missing it shows in both printed values. The array holds
    // floats so its lane never widens: a widened lane would evict the root
    // before the inspection sees it.
    const Inspect = struct {
        fn run(vm: *Vm, mode: TraceMode) !void {
            if (mode != .record_execute and mode != .record_execute_noopt) return;
            // The exercised shape: an attached exit with a store it applies.
            var applied: usize = 0;
            for (vm.trace.registry.cache.items) |t| {
                for (0..t.code.instrs.len) |e| {
                    if (t.exitSideAt(e) != .attached) continue;
                    for (e + 1..t.code.instrs.len) |s| applied += @intFromBool(exit_attach.appliesAtExit(&t.code, e, s));
                }
            }
            try testing.expect(applied > 0);
        }
    };
    try expectProgramTuned(
        \\local t = {0.5}
        \\local s = 0
        \\for i = 1, 300 do
        \\  t[1] = t[1] + i
        \\  if i % 3 == 0 then s = s + t[1] else s = s - 1 end
        \\end
        \\print(s, t[1])
    , "1530000\t45150.5\n", .{ .inspect = Inspect.run });
}

test "doc 56 Phase 3: an exit-side continuation reads an open upvalue without aliased_input" {
    // The exit-side recording starts at the exit's resume pc inside `work`,
    // whose `floor` upvalue is still OPEN on the caller's frame. The
    // recorder's aliasing check needs the anchor frame's absolute base (the
    // `trace_link_peel_test` regression: with a zero base every open
    // upvalue looks aliased and the recording aborts). NB: this pins the
    // end-to-end path, not the exit site's own `pending_anchor_base`
    // assignment — that one is defensive, since the back-edge that entered
    // the parent already stashed the same frame's base (mutation-checked:
    // dropping it changes nothing observable today).
    const source =
        \\local floor = math.floor
        \\local function work(n)
        \\  local count = 0
        \\  for i = 1, n do
        \\    if i % 3 == 0 then count = count + floor(i * 0.5) else count = count - 1 end
        \\  end
        \\  return count
        \\end
        \\print(work(600))
    ;
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    vm.trace.config.record_aborts = true;
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    var chunk = try util.runExecForTrace(&vm, gpa, source, &sink);
    defer chunk.deinit();
    try testing.expectEqualStrings("29700\n", sink.buffered());
    for (vm.trace.abort_log.items) |rec| try testing.expect(rec.reason != .aliased_input);
    try testing.expect(vm.trace.exit_side_binds >= 1);
}

test "doc 56 Phase 3: bit-reverse's post-while continuation also serves the root's wrong-trip exits" {
    // Doc 56 §7: the `for` root unrolls the `while` for the trips it saw,
    // so its wrong-trip-count exits resume at the post-`while` pc — where
    // the `while` root's loop-done continuation already lives. Such an exit
    // binds by CHAINING into that continuation: one trace at `P` serves
    // both arrivals, and no recording is spent. Tier-1a only (Phase 3).
    // The ten-leg output parity is the Phase 0 test's.
    //
    // Doc 58: at the CLI's own recording threshold. The `while` root's
    // continuation at `P` is now recorded by the exit-side route rather than by
    // the deleted loop-done arm, so which of the two arrivals reaches `P` first
    // depends on the threshold; at `hotloop = 4` the root's wrong-trip exit gets
    // there first and records it, and no chain bind is left to observe.
    const Inspect = struct {
        fn run(vm: *Vm, mode: TraceMode) !void {
            std.debug.assert(mode == .record_execute);
            try testing.expect(vm.trace.exit_side_chain_binds >= 1);
            var post_while: usize = 0;
            for (vm.trace.registry.cache.items) |t| {
                const proto = t.code.anchor.proto;
                for (0..t.code.instrs.len) |e| {
                    if (t.exitSideAt(e) != .attached) continue;
                    const p = t.code.exitResumePc(e) orelse continue;
                    if (p >= 1 and proto.code[p - 1].op == .jmp and proto.code[p - 1].aux < 0)
                        post_while += 1;
                }
            }
            try testing.expect(post_while > 0);
        }
    };
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    try util.runCapturedTuned(testing.allocator, bitreverse_src, &sink, false, .record_execute, .{
        .hotloop = (@import("trace.zig").TraceConfig{}).hotloop,
        .inspect = Inspect.run,
    });
    try testing.expectEqualStrings("0.5\t1024\n", sink.buffered());
}

// ---- Doc 56 Phase 4: native exit adapters ----------------------------------

/// All ten legs with `Config.exit_side_native` on print `expected`, and the
/// native leg really took the adapter path: an adapter was built, the
/// dispatcher consumed native exit-side hops, a continuation bound, and no
/// build was refused. Output parity against tier-0 is the oracle for what
/// each adapter wrote back (a missed store, home or snapshot slot shows in
/// the printed values).
fn expectNativeAdapters(source: [:0]const u8, expected: []const u8) !void {
    return expectNativeAdaptersAnd(source, expected, null);
}

/// `expectNativeAdapters` plus `extra`, run on the native leg's VM.
fn expectNativeAdaptersAnd(source: [:0]const u8, expected: []const u8, comptime extra: ?fn (*Vm) anyerror!void) !void {
    const Inspect = struct {
        fn run(vm: *Vm, mode: TraceMode) !void {
            if (mode != .record_execute_native) return;
            if (extra) |f| try f(vm);
            try testing.expect(vm.trace.exit_adapter_builds > 0);
            try testing.expect(vm.trace.exit_side_native_hops > 0);
            try testing.expect(vm.trace.exit_side_binds > 0);
            // Phase 5: the bound exit is armed and its adapter then jumps
            // straight into the child, which the ledger replay validates.
            try testing.expect(vm.trace.exit_side_arms > 0);
            try testing.expect(vm.trace.exit_side_fused > 0);
            try testing.expectEqual(@as(u64, 0), vm.trace.exit_side_disarms);
            for (vm.trace.exit_adapter_refusals) |n| try testing.expectEqual(@as(u64, 0), n);
            // Every built adapter hangs off a native page that carries the
            // exit-side cells.
            var adapters: usize = 0;
            for (vm.trace.registry.cache.items) |t| switch (t.native) {
                .compiled => |*ct| {
                    adapters += ct.exit_adapters.items.len;
                    if (ct.exit_adapters.items.len != 0)
                        try testing.expectEqual(t.code.instrs.len, ct.exit_side_cells.len);
                },
                .unattempted, .unsupported => {},
            };
            try testing.expect(adapters > 0);
        }
    };
    try expectProgramTuned(source, expected, .{ .exit_side_native = true, .inspect = Inspect.run });
}

test "doc 56 Phase 4: a native adapter applies an earlier bytecode's sunk array store" {
    // The Phase 3 sunk-store shape, natively: the adapter writes `t[1]`
    // (float lane, konst index staged above the frame) before the resume.
    try expectNativeAdapters(
        \\local t = {0.5}
        \\local s = 0
        \\for i = 1, 300 do
        \\  t[1] = t[1] + i
        \\  if i % 3 == 0 then s = s + t[1] else s = s - 1 end
        \\end
        \\print(s, t[1])
    , "1530000\t45150.5\n");
}

test "doc 56 Phase 4: a native adapter applies sunk stores on every array lane" {
    // Each lane has its own store encoding (`emitAStore`): `i64`, the `u8`
    // byte lane, `boolean` (presence in-band) and the tagged `value` lane
    // (a mixed array). Each value stays inside its lane, so no store widens
    // it and evicts the root. `t[1]` is read after the exit, so a store the
    // adapter misses shows in the output.
    try expectNativeAdapters(
        \\local t = {1000000000000}
        \\local s = 0
        \\for i = 1, 300 do
        \\  t[1] = t[1] + i
        \\  if i % 3 == 0 then s = s + t[1] else s = s - 1 end
        \\end
        \\print(s, t[1])
    , "100000001529950\t1000000045150\n");
    try expectNativeAdapters(
        \\local t = {1, 2}
        \\local s = 0
        \\for i = 1, 300 do
        \\  t[1] = i % 7
        \\  if i % 3 == 0 then s = s + t[1] else s = s - 1 end
        \\end
        \\print(s, t[1])
    , "103\t6\n");
    try expectNativeAdapters(
        \\local t = {true, false}
        \\local s = 0
        \\for i = 1, 300 do
        \\  t[1] = i % 2 == 0
        \\  if i % 3 == 0 then if t[1] then s = s + 2 else s = s + 1 end else s = s - 1 end
        \\end
        \\print(s, t[1])
    , "-50\ttrue\n");
    try expectNativeAdapters(
        \\local t = {0.5, "x"}
        \\local s = 0
        \\for i = 1, 300 do
        \\  t[1] = t[1] + i
        \\  if i % 3 == 0 then s = s + t[1] else s = s - 1 end
        \\end
        \\print(s, t[1], t[2])
    , "1530000\t45150.5\tx\n");
}

test "doc 56 Phase 4: a native adapter applies sunk hash stores, one of a constant" {
    try expectNativeAdapters(
        \\local t = {x = 0.5, y = 0}
        \\local s = 0
        \\for i = 1, 300 do
        \\  t.x = t.x + i
        \\  t.y = 7
        \\  if i % 3 == 0 then s = s + t.x + t.y else s = s - 1 end
        \\end
        \\print(s, t.x, t.y)
    , "1530700\t45150.5\t7\n");
}

test "doc 56 Phase 4: a native adapter applies a sunk closed-upvalue store" {
    // `u` is a CLOSED upvalue (its maker returned), so `u = u + i` records
    // as a sunk `ustore` through a `uref` the adapter stages from the
    // closure's upvalue array.
    try expectNativeAdapters(
        \\local function mk()
        \\  local u = 0.25
        \\  return function(n)
        \\    local s = 0
        \\    for i = 1, n do
        \\      u = u + i
        \\      if i % 3 == 0 then s = s + u else s = s - 1 end
        \\    end
        \\    return s
        \\  end, function() return u end
        \\end
        \\local f, get = mk()
        \\print(f(300), get())
    , "1529975\t45150.25\n");
}

test "doc 56 Phase 4: an exit snapshot slot overrides its carried home in the adapter" {
    // `c` and `s` are carried AND updated before the exit: the carried-home
    // flush writes their iteration-entry values, then the snapshot's slots
    // must overwrite them with the updated ones (int and float homes).
    try expectNativeAdapters(
        \\local s, c = 0, 0
        \\for i = 1, 300 do
        \\  c = c + 2
        \\  s = s + 0.5
        \\  if i % 3 == 0 then s = s + c else s = s - 1 end
        \\end
        \\print(s, c)
    , "30250\t600\n");
}

test "doc 56 Phase 4: an adapter restores many carried values at once" {
    // Twelve carried ints plus the table and a float accumulator: more
    // homes than registers, so the adapter reads spilled homes as well as
    // GP and XMM ones.
    const Places = struct {
        fn check(vm: *Vm) !void {
            var seen: [@typeInfo(nativegen.ExitLoc.Tag).@"enum".field_names.len]bool = @splat(false);
            for (vm.trace.registry.cache.items) |t| switch (t.native) {
                .compiled => |*ct| {
                    if (ct.exit_adapters.items.len == 0) continue;
                    for (ct.exit_locs.carried) |c| seen[@intFromEnum(ct.exit_locs.find(c.ref).?.tag)] = true;
                },
                .unattempted, .unsupported => {},
            };
            try testing.expect(seen[@intFromEnum(nativegen.ExitLoc.Tag.reg)]);
            try testing.expect(seen[@intFromEnum(nativegen.ExitLoc.Tag.spill)]);
            try testing.expect(seen[@intFromEnum(nativegen.ExitLoc.Tag.xmm)]);
        }
    };
    try expectNativeAdaptersAnd(
        \\local a, b, c, d, e, f, g, h, k, l, m, n2 = 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12
        \\local t = {0.5}
        \\local s = 0
        \\for i = 1, 300 do
        \\  a = a + i; b = b + a; c = c + b; d = d + c; e = e + d; f = f + e
        \\  g = g + f; h = h + g; k = k + h; l = l + k; m = m + l; n2 = n2 + m
        \\  t[1] = t[1] + a + b + c + d + e + f + g + h + k + l + m + n2
        \\  if i % 3 == 0 then s = s + t[1] + a + n2 else s = s - 1 end
        \\end
        \\print(s, t[1], a, n2)
    , "12661121433520190000000\t352480413526858700000\t45151\t-3210781427597235360\n", Places.check);
}

test "doc 56 Phase 4: an open-upvalue continuation runs behind a native adapter" {
    try expectNativeAdapters(
        \\local floor = math.floor
        \\local function work(n)
        \\  local count = 0
        \\  for i = 1, n do
        \\    if i % 3 == 0 then count = count + floor(i * 0.5) else count = count - 1 end
        \\  end
        \\  return count
        \\end
        \\print(work(600))
    , "29700\n");
}

test "doc 56 Phase 4: fft bit-reverse's exits run through native adapters" {
    try expectNativeAdapters(bitreverse_src, "0.5\t1024\n");
}

/// The `exit_side_replay_src` loop's registers at its exit's resume pc `P`
/// for i = 3, with `t[1] = 10.5` (the value once iteration 3 updated it):
/// r0 = t, r1 = s, r2..r4 = the numeric-for index/limit/step, r5 = i. The
/// traces write scratch slots up to r10.
const LoopAtP = struct {
    const t_at_p: f64 = 10.5;
    tbl: *table.Table,
    tags: [16]u8,
    pays: [16]u64,

    fn init(gpa: std.mem.Allocator) !LoopAtP {
        const tbl = try table.Table.create(gpa);
        errdefer tbl.destroy(gpa);
        try tbl.set(gpa, value.Value.int(1), value.Value.float(t_at_p));
        try testing.expectEqual(@import("array.zig").Lane.f64, tbl.array.lane);
        const Tag = value.Tag;
        var s: LoopAtP = .{ .tbl = tbl, .tags = @splat(@intFromEnum(Tag.nil)), .pays = @splat(0) };
        const tv = value.Value.heap(&tbl.header);
        s.tags[0] = @intFromEnum(tv.tag);
        s.pays[0] = tv.payload.bits;
        s.tags[1] = @intFromEnum(Tag.float);
        s.pays[1] = @bitCast(@as(f64, 0.0));
        for ([_]usize{ 2, 5 }) |r| {
            s.tags[r] = @intFromEnum(Tag.int);
            s.pays[r] = 3;
        }
        s.tags[3] = @intFromEnum(Tag.int);
        s.pays[3] = 1000;
        s.tags[4] = @intFromEnum(Tag.int);
        s.pays[4] = 1;
        return s;
    }

    fn deinit(self: *LoopAtP, gpa: std.mem.Allocator) void {
        self.tbl.destroy(gpa);
    }

    fn regs(self: *LoopAtP) RegWindow {
        return RegWindow.of(&self.tags, &self.pays);
    }

    /// The slab must be coherent at `P` of iteration `k` (a multiple of
    /// 3, reached by the child closing i = 3 and the loop running on):
    /// `t[1]` updated through `k`, `s` through `k - 1`. The same walk in
    /// plain f64 arithmetic gives the exact bits.
    fn expectAtP(self: *LoopAtP, k: i64) !void {
        var t1 = t_at_p;
        var s: f64 = 0.0;
        s += t1; // the child closes i = 3
        var i: i64 = 4;
        while (i < k) : (i += 1) {
            t1 += @floatFromInt(i);
            if (@mod(i, 3) == 0) s += t1 else s -= 1;
        }
        t1 += @floatFromInt(k);
        try testing.expectEqual(@as(u64, @intCast(k)), self.pays[2]);
        try testing.expectEqual(@as(u64, @intCast(k)), self.pays[5]);
        try testing.expectEqual(@as(u64, @bitCast(s)), self.pays[1]);
        try testing.expectEqual(@as(u64, @bitCast(t1)), self.tbl.get(value.Value.int(1)).payload.bits);
    }
};

/// Doc 56 Phase 5: the `.exit_side` replay grammar, pinned on hand-made
/// ledgers over REAL armed traces (a program that arms its exit, then the
/// ledgers each rare branch writes). The end-to-end tests above cover the
/// common fused hop; these cover the yield, the unarmed terminal, and the
/// child's own terminals after an adapter jump.
fn checkExitSideReplay(vm: *Vm, mode: TraceMode) !void {
    if (mode != .record_execute_native) return;
    const ts = &vm.trace;
    const Entry = trace_exec.LedgerEntry;
    const l = for (ts.registry.native_physical.armedLinks()) |x| {
        if (x.kind == .exit_side) break x;
    } else return error.TestNoExitSideArm;
    const parent = l.parent;
    const child = l.child;
    const ei = l.slot_index;
    const proto = parent.code.anchor.proto;
    const p = parent.code.exitResumePc(ei).?;
    // The fixture's shape: the child is the `.link` continuation at `P`,
    // closing an iteration of the parent's loop; neither takes inputs.
    try testing.expectEqual(p, child.code.anchor.pc);
    try testing.expect(child.code.linkClosesIteration());
    const link_exit: u32 = @intCast(child.code.instrs.len - 1);
    const aux: u32 = @intCast(child.code.instrs[link_exit].aux);
    try testing.expectEqual(parent.code.anchor.pc, aux);
    try testing.expectEqual(@as(usize, 0), parent.code.inputs.len);
    try testing.expectEqual(@as(usize, 0), child.code.inputs.len);
    try testing.expect(ts.hasArmedExitSide(parent, ei, child));
    const es_row = Entry{ .cum = 4, .id = parent.id, .exit = ei, .reason = .exit_side, .kind = .exit_side, .outcome = .normal };

    // (a) A fused hop, then the child's own `.link` (unarmed): 4 laps plus
    // the iteration the child closed; resume at the loop the `.link` names.
    {
        const rows = [_]Entry{ es_row, .{ .cum = 4, .id = child.id, .exit = link_exit, .reason = .normal, .kind = .link_terminal, .outcome = .normal } };
        const fused0 = ts.exit_side_fused;
        const hops0 = ts.exit_side_hops;
        var lc: usize = 0;
        var rpc: u32 = 999;
        var hops: usize = 0;
        switch (ts.replayLedger(&rows, parent, parent.code.anchor.pc, proto, &lc, &rpc, &hops, 8, .dispatcher_root, false, null)) {
            .run_inner_from => |d| try testing.expectEqual(child, d),
            else => return error.TestUnexpectedResult,
        }
        try testing.expectEqual(@as(usize, 5), lc);
        try testing.expectEqual(aux, rpc);
        try testing.expectEqual(fused0 + 1, ts.exit_side_fused);
        try testing.expectEqual(hops0 + 1, ts.exit_side_hops);
    }
    // (b) The adapter is the last row and was unarmed: the replay hands the
    // exit to the dispatcher's routing at `P`, with the row's work.
    {
        const rows = [_]Entry{es_row};
        var lc: usize = 0;
        var rpc: u32 = 999;
        var hops: usize = 0;
        const r = switch (ts.replayLedger(&rows, parent, parent.code.anchor.pc, proto, &lc, &rpc, &hops, 8, .dispatcher_root, false, null)) {
            .return_result => |r| r,
            else => return error.TestUnexpectedResult,
        };
        try testing.expectEqual(p, r.resume_pc.?);
        try testing.expectEqual(@as(usize, 4), r.completed);
        const es = r.exit_side orelse return error.TestNoExitSideTerminal;
        try testing.expectEqual(parent, es.trace);
        try testing.expectEqual(ei, es.exit);
        try testing.expectEqual(@as(usize, 5), es.done);
    }
    // (c) A full ledger whose last row is the adapter's forced yield: the
    // dispatcher entered the child at `P`, and the cycle `child.link →
    // parent.exit_side → child` runs 16 times, the last adapter yielding.
    // The walk resumes at `P` with nothing left to route.
    {
        var rows: [trace_exec.LEDGER_CAP]Entry = undefined;
        var cum: usize = 0;
        for (&rows, 0..) |*row, k| {
            if (k % 2 == 0) {
                row.* = .{ .cum = cum, .id = child.id, .exit = link_exit, .reason = .normal, .kind = .link_terminal, .outcome = .normal };
            } else {
                cum += 3;
                row.* = .{ .cum = cum, .id = parent.id, .exit = ei, .reason = .exit_side, .kind = .exit_side, .outcome = if (k + 1 == rows.len) .yielded else .normal };
            }
        }
        const fused0 = ts.exit_side_fused;
        const hops0 = ts.exit_side_hops;
        var lc: usize = 0;
        var rpc: u32 = 999;
        var hops: usize = 0;
        const r = switch (ts.replayLedger(&rows, child, child.code.anchor.pc, proto, &lc, &rpc, &hops, 8, .dispatcher_root, false, null)) {
            .return_result => |r| r,
            else => return error.TestUnexpectedResult,
        };
        try testing.expectEqual(p, r.resume_pc.?);
        try testing.expect(r.exit_side == null);
        // 16 closed iterations, plus 16 adapter rows of 3 laps each; the
        // yielded row's own iteration is left to the dispatcher.
        try testing.expectEqual(@as(usize, 16 + 16 * 3), r.completed);
        try testing.expectEqual(fused0 + 15, ts.exit_side_fused);
        try testing.expectEqual(hops0 + 16, ts.exit_side_hops);
    }
    // (c') The same full ledger, but written by the real machine code: a
    // native run entered at the child with both arms live. The rows go
    // `child.link, parent.exit_side, …`, so row 32 is the adapter's own, and
    // its forced-yield check must stamp it `.yielded`, keep
    // `exit_reason = .exit_side`, and leave the slab coherent at `P`.
    {
        var link_armed = false;
        for (ts.registry.native_physical.armedLinks()) |x| {
            if (x.kind == .link_terminal and x.parent == child and x.child == parent) link_armed = true;
        }
        if (!link_armed) try testing.expect(try ts.armNativeLink(child, link_exit, parent, .link_terminal));

        var st = try LoopAtP.init(testing.allocator);
        defer st.deinit(testing.allocator);

        var ledger: [trace_exec.LEDGER_CAP]Entry = undefined;
        const r = child.native.compiled.runCapturingLedgerEntry(st.regs(), &ledger, ts.silentStaging(), true);
        try testing.expectEqual(trace_exec.ExitReason.exit_side, r.exit_reason);
        try testing.expectEqual(@as(u32, trace_exec.LEDGER_CAP), r.ledger_len);
        for (ledger, 0..) |row, k| {
            if (k % 2 == 0) {
                try testing.expectEqual(child.id, row.id);
                try testing.expectEqual(trace_exec.LedgerKind.link_terminal, row.kind);
                // The adapter reset `exit_reason` before jumping in.
                try testing.expectEqual(trace_exec.ExitReason.normal, row.reason);
                try testing.expectEqual(trace_exec.LedgerOutcome.normal, row.outcome);
            } else {
                try testing.expectEqual(parent.id, row.id);
                try testing.expectEqual(trace_exec.LedgerKind.exit_side, row.kind);
                try testing.expectEqual(ei, row.exit);
                // Every jump into the child reset `exit_reason`, so only
                // the last row reads `.exit_side` from the adapter itself.
                try testing.expectEqual(trace_exec.ExitReason.exit_side, row.reason);
                const want: trace_exec.LedgerOutcome = if (k + 1 == ledger.len) .yielded else .normal;
                try testing.expectEqual(want, row.outcome);
            }
        }

        // The slab is coherent at `P` of i = 51 (the 16th exit: i = 6, 9,
        // …, 51), with that iteration's sunk `t[1]` store applied.
        try st.expectAtP(51);

        // Its replay: 16 closed iterations (i = 3 … 48 by the child's
        // links) plus 16 × 2 parent laps; i = 51 is left to tier-0 at `P`.
        const yields0 = ts.exit_side_yields;
        var lc: usize = 0;
        var rpc: u32 = 999;
        var hops: usize = 0;
        const rr = switch (ts.replayLedger(&ledger, child, child.code.anchor.pc, proto, &lc, &rpc, &hops, 8, .dispatcher_root, false, null)) {
            .return_result => |x| x,
            else => return error.TestUnexpectedResult,
        };
        try testing.expectEqual(p, rr.resume_pc.?);
        try testing.expect(rr.exit_side == null);
        try testing.expectEqual(@as(usize, 16 + 16 * 2), rr.completed);
        try testing.expectEqual(yields0 + 1, ts.exit_side_yields);
    }
    // (d) The child's own guard fails after the jump: it rolls back to its
    // anchor `P` (the bridged-successor contract, never `break_burst`).
    {
        const gi: u32 = for (child.code.instrs, 0..) |ins, i| {
            if (trace_ir.isSideExitGuardOp(ins.op)) break @intCast(i);
        } else return error.TestChildHasNoGuard;
        const rows = [_]Entry{ es_row, .{ .cum = 4, .id = child.id, .exit = gi, .reason = .normal, .kind = .deopt, .outcome = .normal } };
        var lc: usize = 0;
        var rpc: u32 = 999;
        var hops: usize = 0;
        const r = switch (ts.replayLedger(&rows, parent, parent.code.anchor.pc, proto, &lc, &rpc, &hops, 8, .dispatcher_root, false, null)) {
            .return_result => |r| r,
            else => return error.TestUnexpectedResult,
        };
        try testing.expectEqual(p, r.resume_pc.?);
        try testing.expectEqual(@as(usize, 4), r.completed);
        try testing.expect(r.exit_side == null);
        try testing.expect(ts.pending_exit_side_disarm == null);
    }
    // (e) The child refuses its entry: same resume, and the arm is disarmed
    // after the walk (the exit stays attached; only a new link re-arms it).
    {
        const rows = [_]Entry{ es_row, .{ .cum = 4, .id = child.id, .exit = std.math.maxInt(u32), .reason = .prologue_fail, .kind = .prologue_fail, .outcome = .normal } };
        var lc: usize = 0;
        var rpc: u32 = 999;
        var hops: usize = 0;
        const r = switch (ts.replayLedger(&rows, parent, parent.code.anchor.pc, proto, &lc, &rpc, &hops, 8, .dispatcher_root, false, null)) {
            .return_result => |r| r,
            else => return error.TestUnexpectedResult,
        };
        try testing.expectEqual(p, r.resume_pc.?);
        try testing.expectEqual(@as(usize, 4), r.completed);
        const disarms0 = ts.exit_side_disarms;
        try testing.expect(ts.pending_exit_side_disarm != null);
        ts.drainPendingExitSideDisarm();
        try testing.expectEqual(disarms0 + 1, ts.exit_side_disarms);
        try testing.expect(!ts.hasArmedExitSide(parent, ei, child));
        const pc = &parent.native.compiled;
        try testing.expectEqual(ts.registry.mcode_arena.trampoline_exit.?, pc.slots[pc.exitSideSlot(ei).?]);
        try testing.expectEqual(exit_attach.ExitSide.attached, parent.exitSideAt(ei));
    }
}

// Doc 56 Phase 5 regression: fft bit-reverse at the CLI's own recording
// threshold. There the continuation serving an exit has its `.link` armed
// back to the parent before the exit is armed, so the exit's chain runs as
// a multi-row native ledger (continuation `.link`, then the parent, then a
// sibling handoff) and ends away from `P`. `driveChain` used to report that
// span as "not linked", so the exit never bound, and the router asserted
// the chain had stopped at `P`. It crashed the CLI; the harness's short
// threshold arms things in another order and never reached it.
test "doc 56 Phase 5: fft bit-reverse at the CLI's hot threshold binds and arms its exits" {
    const Inspect = struct {
        fn run(vm: *Vm, mode: TraceMode) !void {
            if (mode != .record_execute_native) return;
            const ts = &vm.trace;
            try testing.expect(ts.exit_side_binds > 0);
            try testing.expect(ts.exit_side_arms > 0);
            try testing.expect(ts.exit_side_fused > 0);
            try testing.expectEqual(@as(u64, 0), ts.exit_side_disarms);
            for (ts.exit_adapter_refusals) |n| try testing.expectEqual(@as(u64, 0), n);
        }
    };
    try expectProgramTuned(bitreverse_src, "0.5\t1024\n", .{
        .exit_side_native = true,
        .hotloop = (@import("trace.zig").TraceConfig{}).hotloop,
        .inspect = Inspect.run,
    });
}

// Doc 56 §4.8.3 R2 (G1): bit-reverse's zero-trip `while` exit arrives at
// the post-`while` pc with `k` still an int, but the canonical pick there
// (`resolveLoopDoneCont`: hit count, then id) is the float-`k` twin, which
// refuses the entry. The chain now tries the next continuation, and the
// exit arms the one that linked. At the CLI threshold (the order the board
// sees) at least one exit-side arm must target a non-canonical child.
test "doc 56 §4.8.3 R2: an exit-side exit arms the continuation that fits, not the canonical one" {
    const Inspect = struct {
        fn run(vm: *Vm, mode: TraceMode) !void {
            if (mode != .record_execute_native) return;
            const ts = &vm.trace;
            try testing.expect(ts.exit_side_retries > 0);
            var off_canonical: u32 = 0;
            for (ts.registry.native_physical.armedLinks()) |l| {
                if (l.kind != .exit_side) continue;
                const p = l.parent.code.exitResumePc(l.slot_index).?;
                try testing.expectEqual(p, l.child.code.anchor.pc);
                const pick = ts.resolveLoopDoneCont(l.parent.code.anchor.proto, p, null).arm orelse continue;
                if (pick != l.child) off_canonical += 1;
            }
            try testing.expect(off_canonical > 0);
        }
    };
    try expectProgramTuned(bitreverse_src, "0.5\t1024\n", .{
        .exit_side_native = true,
        .hotloop = (@import("trace.zig").TraceConfig{}).hotloop,
        .inspect = Inspect.run,
    });
}

// Doc 56 Phase 5 regression: nsieve called several times. Its prime-path
// exit gets an exit-side child anchored at `P` (the `for k` setup, which is
// also the `if p[i]` branch's fall-through pc). Region discovery used to take
// a branch guard's `guardExitPc` — that fall-through pc, whichever way the
// recording went — as the exit's successor once a trace anchored there, so
// the continuation's COMPOSITE exit got a region bridge onto the prime path:
// every later call counted composites as primes (the table stayed right,
// only `count` was wrong). Both recording thresholds, since the arm order
// differs.
const nsieve_calls_src =
    \\local function nsieve(p, m)
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
    \\local primes = {}
    \\for _, m in ipairs({400, 200, 100, 50}) do
    \\  print(m, nsieve(primes, m))
    \\end
;
test "doc 56 Phase 5: repeated nsieve calls keep their prime count with exit-side arms" {
    const out = "400\t78\n200\t46\n100\t25\n50\t15\n";
    try expectProgramTuned(nsieve_calls_src, out, .{ .exit_side_native = true });
    try expectProgramTuned(nsieve_calls_src, out, .{
        .exit_side_native = true,
        .hotloop = (@import("trace.zig").TraceConfig{}).hotloop,
    });
}

const exit_side_replay_src =
    \\local t = {0.5}
    \\local s = 0
    \\for i = 1, 300 do
    \\  t[1] = t[1] + i
    \\  if i % 3 == 0 then s = s + t[1] else s = s - 1 end
    \\end
    \\print(s, t[1])
;

test "doc 56 Phase 5: the .exit_side replay grammar on real armed traces" {
    try expectProgramTuned(exit_side_replay_src, "1530000\t45150.5\n", .{ .exit_side_native = true, .inspect = checkExitSideReplay });
}

/// Doc 56 §4.8.3 R1, in machine code: an exit whose ORDINARY cell is armed
/// takes that arm even though its adapter is published and armed too. The
/// fixture's exit gets an `.ordinary_guard` arm back into its own parent
/// (same anchor; the coarse deopt re-runs the failing iteration), so every
/// firing after the first is the parent re-entering itself until the ledger
/// cap yields. Before R1 the stub branched to the adapter first.
fn checkOrdinaryArmFirst(vm: *Vm, mode: TraceMode) !void {
    if (mode != .record_execute_native) return;
    const ts = &vm.trace;
    const Entry = trace_exec.LedgerEntry;
    const l = for (ts.registry.native_physical.armedLinks()) |x| {
        if (x.kind == .exit_side) break x;
    } else return error.TestNoExitSideArm;
    const parent = l.parent;
    const child = l.child;
    const ei = l.slot_index;
    const link_exit: u32 = @intCast(child.code.instrs.len - 1);
    var link_armed = false;
    for (ts.registry.native_physical.armedLinks()) |x| {
        if (x.kind == .link_terminal and x.parent == child and x.child == parent) link_armed = true;
    }
    if (!link_armed) try testing.expect(try ts.armNativeLink(child, link_exit, parent, .link_terminal));

    // No ordinary arm yet: the exit's router may want it. With one, it may not.
    try testing.expect(!ts.ordinaryArmLive(parent, ei));
    try testing.expect(try ts.armNativeLink(parent, ei, parent, .ordinary_guard));
    try testing.expect(ts.ordinaryArmLive(parent, ei));
    try testing.expect(ts.hasArmedExitSide(parent, ei, child));

    var st = try LoopAtP.init(testing.allocator);
    defer st.deinit(testing.allocator);

    var ledger: [trace_exec.LEDGER_CAP]Entry = undefined;
    const r = child.native.compiled.runCapturingLedgerEntry(st.regs(), &ledger, ts.silentStaging(), true);
    try testing.expectEqual(@as(u32, trace_exec.LEDGER_CAP), r.ledger_len);
    try testing.expect(r.exit_reason != .exit_side);
    // The child closes i = 3; the parent runs i = 4, 5 and fails at i = 6,
    // then re-enters itself through the ordinary arm on every later row.
    try testing.expectEqual(child.id, ledger[0].id);
    try testing.expectEqual(trace_exec.LedgerKind.link_terminal, ledger[0].kind);
    for (ledger[1..], 1..) |row, k| {
        try testing.expectEqual(parent.id, row.id);
        try testing.expectEqual(ei, row.exit);
        try testing.expectEqual(trace_exec.LedgerKind.deopt, row.kind);
        const want: trace_exec.LedgerOutcome = if (k + 1 == ledger.len) .yielded else .normal;
        try testing.expectEqual(want, row.outcome);
    }
    // Every row re-ran i = 6 from the anchor: the slab still holds it, and
    // the iteration's sunk `t[1]` store was never applied twice.
    try testing.expectEqual(@as(f64, 10.5 + 4 + 5), @as(f64, @bitCast(st.tbl.get(value.Value.int(1)).payload.bits)));

    // Disarming the ordinary cell hands the exit back to its adapter.
    for (ts.registry.native_physical.armedLinks(), 0..) |x, i| {
        if (x.kind == .ordinary_guard and x.parent == parent and x.slot_index == ei) {
            ts.disarmLinkAt(i);
            break;
        }
    }
    try testing.expect(!ts.ordinaryArmLive(parent, ei));
}

/// Doc 56 Phase 6 (§4.8.2), in machine code on the replay fixture's real
/// traces: the exit-side cycle `child.link → parent … adapter → child` as a
/// promoted set. Promotion is physical and resident (no activation), so the
/// drain runs without a region; the region half is pinned by the bit-reverse
/// test below.
fn checkSilentExitSide(vm: *Vm, mode: TraceMode) !void {
    if (mode != .record_execute_native) return;
    const ts = &vm.trace;
    const gpa = testing.allocator;
    const Entry = trace_exec.LedgerEntry;
    const trace_mod = @import("trace.zig");
    const l = for (ts.registry.native_physical.armedLinks()) |x| {
        if (x.kind == .exit_side) break x;
    } else return error.TestNoExitSideArm;
    const parent = l.parent;
    const child = l.child;
    const ei = l.slot_index;
    const proto = parent.code.anchor.proto;
    const p = parent.code.exitResumePc(ei).?;
    const pc = &parent.native.compiled;
    const es_cell = pc.exitSideSlot(ei).?;
    const link_exit: u32 = @intCast(child.code.instrs.len - 1);
    var link_armed = false;
    for (ts.registry.native_physical.armedLinks()) |x| {
        if (x.kind == .link_terminal and x.parent == child and x.child == parent) link_armed = true;
    }
    if (!link_armed) try testing.expect(try ts.armNativeLink(child, link_exit, parent, .link_terminal));
    ts.demoteAllSets();
    const key: trace_mod.RegionKey = .{ .region_id = @enumFromInt(0xfeed_0000), .activation = trace_mod.RESIDENT_ACTIVATION };

    // The adapter carries its own silent site, on its own page, testing
    // its own data cell (not the ordinary deopt site's).
    const ad = pc.exitAdapter(ei).?;
    const site = ad.site.?;
    try testing.expectEqual(nativegen.SilentSiteKind.exit_side, site.kind);
    try testing.expectEqual(&pc.exit_side_metadata_cells[ei], site.metadata_cell);
    try testing.expect(site.metadata_cell != &pc.metadata_cells[ei]);

    const es_edge = ts.promotedEdgeFromLink(.{ .parent = parent, .slot_index = ei, .child = child, .kind = .exit_side }) orelse
        return error.TestExitSideEdgeRefused;
    try testing.expectEqual(nativegen.SilentSiteKind.exit_side, es_edge.kind);
    try testing.expectEqual(es_cell, es_edge.cell);
    try testing.expectEqual(ei, es_edge.exit);
    try testing.expectEqual(p, es_edge.resume_pc);
    const link_edge = ts.promotedEdgeFromLink(.{ .parent = child, .slot_index = link_exit, .child = parent, .kind = .link_terminal }) orelse
        return error.TestLinkEdgeRefused;
    try testing.expectEqual(link_exit, link_edge.cell);
    const min_useful = ts.config.min_useful;

    // (a) Both edges promoted: the cycle runs rowless until the budget. The
    // eighth transition is the fourth adapter firing (exits at i = 6, 9,
    // 12, 15), so the run stops at `P` of i = 15 with no row written.
    {
        try ts.registry.native_physical.promoteSet(&.{ link_edge, es_edge }, key, min_useful);
        try testing.expect(pc.exit_side_metadata_cells[ei] != 0);
        try testing.expectEqual(@as(usize, 0), pc.metadata_cells[ei]);
        try testing.expect(ts.registry.native_physical.cellIsPromoted(parent.id, es_cell));
        try testing.expect(!ts.registry.native_physical.cellIsPromoted(parent.id, ei));
        // The metadata jumps through the exit-side cell, and falls back to
        // the adapter's reporting tail, not the parent page.
        const md: *const nativegen.SilentExitMetadata = @ptrFromInt(pc.exit_side_metadata_cells[ei]);
        try testing.expectEqual(&pc.slots[es_cell], md.slot);
        try testing.expectEqual(@intFromPtr(ad.page.code.ptr) + site.resume_off, md.reporting_target);

        var st = try LoopAtP.init(gpa);
        defer st.deinit(gpa);
        var ledger: [trace_exec.LEDGER_CAP]Entry = undefined;
        const staging: nativegen.SilentStaging = .{ .silent_budget = 8, .barren_budget = ts.config.max_barren_run, .cur_zero_run = 0 };
        const r = child.native.compiled.runCapturingLedgerEntry(st.regs(), &ledger, staging, true);
        try testing.expectEqual(@as(u32, 0), r.ledger_len);
        try testing.expect(r.silent_active != 0);
        try testing.expectEqual(@as(u64, 8), r.silent_transitions);
        try testing.expectEqual(trace_exec.ExitReason.normal, r.exit_reason);
        try st.expectAtP(15);

        // The summary image, as the epilogues wrote it: four firings each;
        // the adapter's carries the replay row's `local + 1` = 3 per firing.
        const set = ts.registry.native_physical.promotedSets()[0];
        try testing.expectEqual(@as(u64, 4), set.summary[0].firings);
        try testing.expectEqual(@as(u64, 0), set.summary[0].region_work);
        try testing.expectEqual(@as(u64, 4), set.summary[1].firings);
        try testing.expectEqual(@as(u64, 12), set.summary[1].region_work);
        try testing.expectEqual(@as(u64, 12), set.summary[1].selection_work);
        try testing.expectEqual(@as(u64, 2), set.summary[1].last_local);
        try testing.expectEqual(@as(u64, 4), set.summary[1].productive_firings);

        // The drain: rowless at `P`, and the count a rowed ledger of the
        // same eight rows reports (`checkExitSideReplay` (c)): four closed
        // iterations plus four adapter rows of two laps each.
        const hops0 = ts.exit_side_hops;
        const fused0 = ts.exit_side_fused;
        var lc: usize = 0;
        var rpc: u32 = 999;
        var hops: usize = 0;
        const d = ts.drainSilentResult(r, .dispatcher_root, proto, &lc, &rpc, &hops, 8, false, st.regs()) orelse
            return error.TestNotDrained;
        const rr = switch (d) {
            .return_result => |x| x,
            else => return error.TestUnexpectedResult,
        };
        try testing.expectEqual(p, rr.resume_pc.?);
        try testing.expect(rr.exit_side == null);
        try testing.expectEqual(@as(usize, 4 + 4 * 2), rr.completed);
        try testing.expectEqual(hops0 + 4, ts.exit_side_hops);
        try testing.expectEqual(fused0 + 3, ts.exit_side_fused);
        ts.demoteAllSets();
        try testing.expectEqual(@as(usize, 0), pc.exit_side_metadata_cells[ei]);
        try testing.expect(!ts.registry.native_physical.cellIsPromoted(parent.id, es_cell));
    }

    // (b) Only the `.link` promoted: silence starts at the child's `.link`,
    // and the unpromoted adapter takes its reporting path — the suffix
    // starts with its `.exit_side` row and runs to the ledger cap.
    {
        try ts.registry.native_physical.promoteSet(&.{link_edge}, key, min_useful);
        var st = try LoopAtP.init(gpa);
        defer st.deinit(gpa);
        var ledger: [trace_exec.LEDGER_CAP]Entry = undefined;
        const r = child.native.compiled.runCapturingLedgerEntry(st.regs(), &ledger, ts.silentStaging(), true);
        try testing.expect(r.silent_active != 0);
        try testing.expectEqual(@as(u64, 1), r.silent_transitions);
        try testing.expectEqual(@as(u32, trace_exec.LEDGER_CAP), r.ledger_len);
        try testing.expectEqual(parent.id, ledger[0].id);
        try testing.expectEqual(trace_exec.LedgerKind.exit_side, ledger[0].kind);
        try testing.expectEqual(ei, ledger[0].exit);
        try testing.expectEqual(trace_exec.LedgerKind.link_terminal, ledger[1].kind);
        @memcpy(ts.ledger_scratch[0..r.ledger_len], ledger[0..r.ledger_len]);
        var lc: usize = 0;
        var rpc: u32 = 999;
        var hops: usize = 0;
        const d = ts.drainSilentResult(r, .dispatcher_root, proto, &lc, &rpc, &hops, 8, false, st.regs()) orelse
            return error.TestNotDrained;
        switch (d) {
            .return_result => |x| try testing.expect(x.exit_side == null),
            .run_inner_from, .run_continuation => {},
            .break_burst => return error.TestUnexpectedResult,
        }
        ts.demoteAllSets();
    }

    // (c) The same, with the exit-side arm gone: the suffix is the unarmed
    // adapter's one row, and the drain hands the exit to the dispatcher's
    // routing (`ChainResult.exit_side`) at `P`.
    {
        for (ts.registry.native_physical.armedLinks(), 0..) |x, i| {
            if (x.kind == .exit_side and x.parent == parent and x.slot_index == ei) {
                ts.disarmLinkAt(i);
                break;
            }
        }
        try testing.expect(!ts.hasArmedExitSide(parent, ei, child));
        try ts.registry.native_physical.promoteSet(&.{link_edge}, key, min_useful);
        var st = try LoopAtP.init(gpa);
        defer st.deinit(gpa);
        var ledger: [trace_exec.LEDGER_CAP]Entry = undefined;
        const r = child.native.compiled.runCapturingLedgerEntry(st.regs(), &ledger, ts.silentStaging(), true);
        try testing.expect(r.silent_active != 0);
        try testing.expectEqual(@as(u32, 1), r.ledger_len);
        try testing.expectEqual(trace_exec.ExitReason.exit_side, r.exit_reason);
        try st.expectAtP(6);
        @memcpy(ts.ledger_scratch[0..r.ledger_len], ledger[0..r.ledger_len]);
        var lc: usize = 0;
        var rpc: u32 = 999;
        var hops: usize = 0;
        const d = ts.drainSilentResult(r, .dispatcher_root, proto, &lc, &rpc, &hops, 8, false, st.regs()) orelse
            return error.TestNotDrained;
        const rr = switch (d) {
            .return_result => |x| x,
            else => return error.TestUnexpectedResult,
        };
        try testing.expectEqual(p, rr.resume_pc.?);
        const es = rr.exit_side orelse return error.TestNoExitSideTerminal;
        try testing.expectEqual(parent, es.trace);
        try testing.expectEqual(ei, es.exit);
        try testing.expectEqual(@as(usize, 3), es.done);
        ts.demoteAllSets();
        try testing.expect(try ts.armNativeLink(parent, ei, child, .exit_side));
    }

    // (d) Keying by cell: one exit with an ordinary arm AND an exit-side
    // arm is two cells, two data cells, one set.
    {
        try testing.expect(try ts.armNativeLink(parent, ei, parent, .ordinary_guard));
        const og_edge = ts.promotedEdgeFromLink(.{ .parent = parent, .slot_index = ei, .child = parent, .kind = .ordinary_guard }) orelse
            return error.TestOrdinaryEdgeRefused;
        try testing.expectEqual(ei, og_edge.cell);
        const es2 = ts.promotedEdgeFromLink(.{ .parent = parent, .slot_index = ei, .child = child, .kind = .exit_side }).?;
        try ts.registry.native_physical.promoteSet(&.{ og_edge, es2 }, key, min_useful);
        try testing.expect(ts.registry.native_physical.cellIsPromoted(parent.id, ei));
        try testing.expect(ts.registry.native_physical.cellIsPromoted(parent.id, es_cell));
        try testing.expect(pc.metadata_cells[ei] != 0);
        try testing.expect(pc.exit_side_metadata_cells[ei] != 0);
        try testing.expect(pc.metadata_cells[ei] != pc.exit_side_metadata_cells[ei]);
        // A set naming one cell twice is refused.
        ts.demoteAllSets();
        try testing.expectError(error.InvalidPromotionSet, ts.registry.native_physical.promoteSet(&.{ es2, es2 }, key, min_useful));
        try testing.expectEqual(@as(usize, 0), pc.metadata_cells[ei]);
        try testing.expectEqual(@as(usize, 0), pc.exit_side_metadata_cells[ei]);
        for (ts.registry.native_physical.armedLinks(), 0..) |x, i| {
            if (x.kind == .ordinary_guard and x.parent == parent and x.slot_index == ei) {
                ts.disarmLinkAt(i);
                break;
            }
        }
    }

    // (d') Disarming a PROMOTED exit-side link demotes its set through
    // `prepareSlotMutation` on the exit-side cell (not the ordinary one)
    // and zeroes the adapter's data cell.
    {
        const es4 = ts.promotedEdgeFromLink(.{ .parent = parent, .slot_index = ei, .child = child, .kind = .exit_side }).?;
        try ts.registry.native_physical.promoteSet(&.{ link_edge, es4 }, key, min_useful);
        try testing.expect(pc.exit_side_metadata_cells[ei] != 0);
        const demotions0 = ts.registry.native_physical.silent_demotions;
        const disarmed = for (ts.registry.native_physical.armedLinks(), 0..) |x, i| {
            if (x.kind == .exit_side and x.parent == parent and x.slot_index == ei) {
                ts.disarmLinkAt(i);
                break true;
            }
        } else false;
        try testing.expect(disarmed);
        try testing.expectEqual(demotions0 + 1, ts.registry.native_physical.silent_demotions);
        try testing.expectEqual(@as(usize, 0), ts.registry.native_physical.promotedSets().len);
        try testing.expectEqual(@as(usize, 0), pc.exit_side_metadata_cells[ei]);
        try testing.expect(!ts.registry.native_physical.cellIsPromoted(parent.id, es_cell));
        try testing.expect(try ts.armNativeLink(parent, ei, child, .exit_side));
    }

    // (e) Retiring the child demotes the set through `resetLinksTouching`
    // and zeroes the adapter's data cell.
    {
        const es3 = ts.promotedEdgeFromLink(.{ .parent = parent, .slot_index = ei, .child = child, .kind = .exit_side }).?;
        try ts.registry.native_physical.promoteSet(&.{ link_edge, es3 }, key, min_useful);
        const demotions0 = ts.registry.native_physical.silent_demotions;
        ts.resetLinksTouching(child);
        try testing.expectEqual(demotions0 + 1, ts.registry.native_physical.silent_demotions);
        try testing.expectEqual(@as(usize, 0), ts.registry.native_physical.promotedSets().len);
        try testing.expectEqual(@as(usize, 0), pc.exit_side_metadata_cells[ei]);
        try testing.expect(!ts.registry.native_physical.cellIsPromoted(parent.id, es_cell));
    }
}

test "doc 56 Phase 6: an exit-side cycle runs silent, keyed by cell" {
    try expectProgramTuned(exit_side_replay_src, "1530000\t45150.5\n", .{ .exit_side_native = true, .inspect = checkSilentExitSide });
}

// Doc 56 Phase 6: a branch that flips for good (`boolC`, TODO.md). After
// i = 500 every iteration leaves the loop trace through its exit adapter
// into the continuation at `P`, whose `.link` closes the iteration: the
// one exit-side cycle that needed silence (70% seam before). Rowed and
// silent must account the same work: traced iterations and adapter hops.
const flip_src =
    \\local N = 20000
    \\local c = 0
    \\for i = 1, N do local lt = i < 500; if lt then c = c + 1 end end
    \\print(c)
;
test "doc 56 Phase 6: a flipped branch's exit-side cycle promotes, and accounts like the rowed one" {
    const Seen = struct {
        var traced: [2]u64 = .{ 0, 0 };
        var total: [2]u64 = .{ 0, 0 };
        var hops: [2]u64 = .{ 0, 0 };
        var promotions: [2]u64 = .{ 0, 0 };
        var transitions: [2]u64 = .{ 0, 0 };
        fn record(vm: *Vm, mode: TraceMode, leg: usize) void {
            if (mode != .record_execute_native) return;
            const ts = &vm.trace;
            traced[leg] = ts.iters_traced;
            total[leg] = ts.iters_traced + ts.iters_tier0_covered + ts.iters_tier0_uncovered;
            hops[leg] = ts.exit_side_hops;
            promotions[leg] = ts.registry.native_physical.silent_promotions;
            transitions[leg] = ts.silent_transitions_total;
        }
        fn rowed(vm: *Vm, mode: TraceMode) !void {
            record(vm, mode, 0);
        }
        fn silent(vm: *Vm, mode: TraceMode) !void {
            record(vm, mode, 1);
        }
    };
    const base: @import("interp_testutil.zig").CapturedOpts = .{ .exit_side_native = true, .coverage = true };
    var opts = base;
    opts.silent_promotion = false;
    opts.inspect = Seen.rowed;
    try expectProgramTuned(flip_src, "499\n", opts);
    opts = base;
    opts.inspect = Seen.silent;
    try expectProgramTuned(flip_src, "499\n", opts);

    try testing.expectEqual(@as(u64, 0), Seen.promotions[0]);
    try testing.expect(Seen.promotions[1] > 0);
    // Most of the cycle's hops ran silent.
    try testing.expect(Seen.transitions[1] > Seen.hops[1] / 2);
    try testing.expect(Seen.hops[0] > 0);
    // The two runs take different paths — a rowed ledger yields every 16
    // hops and tier-0 finishes the interrupted iteration; silence yields
    // only at its budget — so their per-path totals differ, but every
    // iteration is counted exactly once either way, and silence runs more
    // of them as a trace.
    try testing.expectEqual(Seen.total[0], Seen.total[1]);
    try testing.expect(Seen.traced[1] > Seen.traced[0]);
    try testing.expect(Seen.hops[1] > Seen.hops[0]);
}

// Doc 56 Phase 6 / Rule Z-8 layer 2: an armed exit-side cycle only stops
// paying per-row ledger costs once its region is ARMABLE and the set is
// promoted. Bit-reverse at the CLI threshold must mint an armable
// cross-trace cycle. It does not promote yet: every burst ends at the
// inner `while` root's loop-done `.deopt` (G5, §4.8.2 — `while` loops
// have no native loop-done link), so no ledger ever fills to the forced
// yield that promotion needs. When G5 lands, add the promotion checks.
test "doc 56 Phase 6: fft bit-reverse's exit-side cycle mints armable" {
    const Inspect = struct {
        fn run(vm: *Vm, mode: TraceMode) !void {
            if (mode != .record_execute_native) return;
            const ts = &vm.trace;
            var armable_cycle = false;
            var it = ts.region_policy.region_defs.valueIterator();
            while (it.next()) |def| {
                if (def.classifier.kind == .cross_trace_cycle and def.armable) armable_cycle = true;
            }
            try testing.expect(armable_cycle);
            try testing.expect(ts.exit_side_hops > 0);
        }
    };
    try expectProgramTuned(bitreverse_src, "0.5\t1024\n", .{
        .exit_side_native = true,
        .hotloop = (@import("trace.zig").TraceConfig{}).hotloop,
        .inspect = Inspect.run,
    });
}

test "doc 56 §4.8.3 R1: a live ordinary arm wins over a published exit adapter" {
    try expectProgramTuned(exit_side_replay_src, "1530000\t45150.5\n", .{ .exit_side_native = true, .inspect = checkOrdinaryArmFirst });
}

/// Doc 58 B2 review, blocker 1 (`bench/while_shortcircuit_probe.lua`). The
/// `and` makes the `while` test a two-branch chain whose second test reads a
/// condition temp the first one wrote, and `b = not b` unrolls the body
/// twice, so the second copy's guard sits BEFORE the copy's `loadk true`
/// into that temp — whose φ update is the interned `konst true` defined at
/// the top of the trace. A composite bridge that flushed that φ committed
/// `cr = true` where the guest had `cr = false`, and the `while` ran one
/// trip past its bound (215 instead of 76).
const while_shortcircuit_src =
    \\local s = 0
    \\for r = 1, 120 do
    \\  local b = false
    \\  local i = 0
    \\  while i < (r % 9 + 3) and true do
    \\    b = not b
    \\    i = i + 1
    \\    if b then s = s + i else s = s - i end
    \\  end
    \\end
    \\print(s)
;

/// Every branch guard whose emitted φ set disagrees with its exit snapshot on
/// a slot live where the bridge would land (the branch edge the recording did
/// not take) must be refused bridge candidacy; returns how many such guards
/// the registry holds, so the caller can demand the hazard occurred.
fn countRefusedSnapshotDisagreements(vm: *Vm) !usize {
    var hazards: usize = 0;
    for (vm.trace.registry.cache.items) |t| {
        const c = &t.code;
        const proto = c.anchor.proto;
        if (!proto.reg_live.available()) continue;
        for (c.instrs, 0..) |g, gi| {
            if (g.op != .guard_true and g.op != .guard_false) continue;
            const si = c.exitSnapIdx(gi) orelse continue;
            const gp = switch (c.provAt(@intCast(gi)) orelse continue) {
                .guard => |x| x,
                .link_terminal => continue,
            };
            if (gp.role != .branch_cond or gp.polarity == .neutral) continue;
            const src = proto.code[gp.source_pc];
            if (src.op != .jmp_if_true and src.op != .jmp_if_false) continue;
            const landing: usize = if (gp.polarity == .fallthrough)
                @intCast(@as(i64, gp.source_pc) + 1 + src.aux)
            else
                gp.source_pc + 1;
            const s = c.exit_snapshots[si - 1];
            const snap = c.exit_snapshot_slots[s.slots_begin..][0..s.slots_len];
            const live_row = proto.reg_live.row(@intCast(landing));
            var disagrees = false;
            var emitted = c.bridgeEmissions(gi);
            while (emitted.next()) |p| {
                const slot: usize = @intCast(p.aux);
                if ((live_row[slot / 64] >> @intCast(slot % 64)) & 1 == 0) continue;
                var ref: ?u16 = null;
                for (snap) |ss| if (ss.slot == slot) {
                    ref = ss.ref;
                };
                if (ref == null or ref.? != p.b) disagrees = true;
            }
            if (!disagrees) continue;
            hazards += 1;
            try testing.expect(!c.isBridgeCandidate(gi));
        }
    }
    return hazards;
}

test "doc 58 B2: a composite bridge never commits a φ the exit snapshot contradicts" {
    const Inspect = struct {
        fn run(vm: *Vm, mode: TraceMode) !void {
            const hazards = try countRefusedSnapshotDisagreements(vm);
            if (isExecuteMode(mode)) try testing.expect(hazards > 0);
        }
    };
    // The CLI's tiering order is the one that arms the bad bridge.
    try expectProgramTuned(while_shortcircuit_src, "76\n", .{
        .exit_side_native = true,
        .hotloop = (@import("trace.zig").TraceConfig{}).hotloop,
        .inspect = Inspect.run,
    });
}

/// Doc 58 §4.8 (B2 blocker 3): fft_transform's shape (`bench/luajit/
/// scimark_lib.lua:190`, n = 256, normalised round trips so the data stay
/// bounded). B2 makes the `repeat` back-path traceable, so the whole
/// `repeat` body becomes ONE closed cycle — first `for i` root → its
/// continuation → the inner `for i` root → the `for a` continuation → back
/// to the first root — with two link-fed loop roots. Increment B refused
/// that tie, the cycle minted `armable=false`, and every burst drained at
/// the ledger cap (fft +50% with the switch on). Gate dominance elects the
/// first loop's root, and the region is admitted and promotes.
const fft_transform_src =
    \\local sin, pi = math.sin, math.pi
    \\local function transform(v, n, dir)
    \\  local dual = 1
    \\  repeat
    \\    local dual2 = 2 * dual
    \\    for i = 1, 2 * n - 1, 2 * dual2 do
    \\      local j = i + dual2
    \\      local ir, ii = v[i], v[i + 1]
    \\      local jr, ji = v[j], v[j + 1]
    \\      v[j], v[j + 1] = ir - jr, ii - ji
    \\      v[i], v[i + 1] = ir + jr, ii + ji
    \\    end
    \\    local theta = dir * pi / dual
    \\    local s, s2 = sin(theta), 2.0 * sin(theta * 0.5) ^ 2
    \\    local wr, wi = 1.0, 0.0
    \\    for a = 3, dual2 - 1, 2 do
    \\      wr, wi = wr - s * wi - s2 * wr, wi + s * wr - s2 * wi
    \\      for i = a, a + 2 * (n - dual2), 2 * dual2 do
    \\        local j = i + dual2
    \\        local jr, ji = v[j], v[j + 1]
    \\        local dr, di = wr * jr - wi * ji, wr * ji + wi * jr
    \\        local ir, ii = v[i], v[i + 1]
    \\        v[j], v[j + 1] = ir - dr, ii - di
    \\        v[i], v[i + 1] = ir + dr, ii + di
    \\      end
    \\    end
    \\    dual = dual2
    \\  until dual >= n
    \\end
    \\local n = 256
    \\local v = {}
    \\for i = 1, 2 * n do v[i] = (i % 7) * 0.25 end
    \\for rep = 1, 20 do
    \\  transform(v, n, -1)
    \\  transform(v, n, 1)
    \\  for i = 1, 2 * n do v[i] = v[i] / n end
    \\end
    \\print(v[1], v[2 * n])
;

test "doc 58 §4.8: fft_transform's multi-root repeat cycle elects its first loop, admits and promotes" {
    const Inspect = struct {
        fn run(vm: *Vm, mode: TraceMode) !void {
            if (mode != .record_execute_native) return;
            const bc = @import("bytecode.zig");
            const ts = &vm.trace;
            var found = false;
            var it = ts.region_policy.region_defs.valueIterator();
            while (it.next()) |def| {
                if (def.classifier.kind != .cross_trace_cycle or def.classifier.member_count != 4) continue;
                found = true;
                try testing.expect(def.armable);
                try testing.expect(def.fallback_owner);
                try testing.expect(!def.dormant); // admitted
                // The owner is the root of the repeat body's FIRST loop.
                const first = for (def.owner.proto.code, 0..) |ins, pc| {
                    if (ins.op == .for_loop) break bc.loopHeaderOf(ins, pc).?;
                } else unreachable;
                try testing.expectEqual(first, def.owner.pc);
            }
            try testing.expect(found);
            try testing.expect(ts.registry.native_physical.silent_promotions > 0);
            try testing.expect(ts.silent_parked_reuses > 0);
        }
    };
    try expectProgramTuned(fft_transform_src, "0.2500000000000003\t0.5998951286759093\n", .{
        .exit_side_native = true,
        .hotloop = (@import("trace.zig").TraceConfig{}).hotloop,
        .inspect = Inspect.run,
    });
}

/// The nsieve kernel (LuaJIT `bench/nsieve.lua`) at test size. With exit-side
/// on, its steady cycle is four rows — the outer root's prime exit (exit-side)
/// → the `for_prep` child (link) → the inner `for k` root (loop-done linked) →
/// the post-loop continuation, whose "next i is composite" exit bridges back to
/// the outer root (region bridge). Every 32-row ledger therefore fills on the
/// bridge.
const nsieve_src =
    \\local function nsieve(p, m)
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
    \\local primes = {}
    \\local s = 0
    \\for i=0,2 do s = s + nsieve(primes, 20000 >> i) end
    \\print(s)
;

test "doc 56 G6 follow-up: a cycle whose ledger cap lands on its region bridge yields there and goes silent" {
    // The bridge stub's ledger-full case used to take a plain `.normal` deopt,
    // which is not silent-promotion evidence: the sieves sat in rows mode with
    // a coarse deopt + tier-0 replay + ledger walk every 32 rows (3× slower
    // than with exit-side off). Now the cap is a `.yielded` deopt that names
    // the suppressed bridge, and detection accepts it as that bridge's row.
    const Inspect = struct {
        fn run(vm: *Vm, mode: TraceMode) !void {
            if (mode != .record_execute_native) return;
            const ts = &vm.trace;
            try testing.expect(ts.native_region_bridge_fused > 0);
            // Native half: the cap at the bridge is reported as a yield.
            try testing.expect(ts.native_region_bridge_cap_yields > 0);
            // Detection half: no such yield is rejected as a kind mismatch.
            try testing.expectEqual(@as(u64, 0), ts.silent_rejects.no_silent_site);
            try testing.expect(ts.registry.native_physical.silent_promotions > 0);
        }
    };
    try expectProgramTuned(nsieve_src, "4160\n", .{
        .hotloop = (@import("trace.zig").TraceConfig{}).hotloop,
        .inspect = Inspect.run,
    });
}

test "doc 61 §5 site 2: the dead-φ filter keeps the φs a composite bridge's continue proof needs" {
    // The sieve's `if p[i]` exit, recorded on the prime path, bridges across
    // the outer `for_loop` to the outer loop's body. The bridge stands in for
    // that `for_loop`, so the continue proof demands φs for the index AND
    // the loop variable `i`, which is dead where the trace closes (the inner
    // loop reads its own copy of the step). A filter that dropped `i` failed
    // the proof closed: no edge, and the exit grew an exit-side child instead.
    const Inspect = struct {
        fn run(vm: *Vm, mode: TraceMode) !void {
            if (mode != .record_execute_native) return;
            const link = @import("trace_link.zig");
            var crossing: usize = 0;
            for (vm.trace.registry.cache.items) |t| {
                for (t.code.exit_prov) |e| {
                    if (!t.code.isBridgeCandidate(e.index)) continue;
                    const gp = switch (e.prov) {
                        .guard => |g| g,
                        .link_terminal => continue,
                    };
                    var walk = CompositeWalk.init(t.code.anchor.proto.code, gp.source_pc, gp.polarity) orelse continue;
                    while (walk.current()) |pc| {
                        if (pc == t.code.anchor.pc or !walk.step()) break;
                    }
                    const flp = walk.crossed_for_loop orelse continue;
                    crossing += 1;
                    try testing.expect(link.compositeContinueProof(t, e.index, flp));
                }
            }
            try testing.expect(crossing > 0);
        }
    };
    try expectProgramTuned(nsieve_src, "4160\n", .{
        .hotloop = (@import("trace.zig").TraceConfig{}).hotloop,
        .inspect = Inspect.run,
    });
}
