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

test "doc 56 Phase 0: fft bit-reverse is byte-identical and (today) barely runs traced" {
    const Inspect = struct {
        fn run(vm: *Vm, mode: TraceMode) !void {
            if (mode != .record_execute_native) return;
            var anchors: u32 = 0;
            var it = vm.trace.coverage.iterator();
            while (it.next()) |entry| {
                if (!std.mem.eql(u8, entry.key_ptr.proto.name, "bitreverse")) continue;
                const traced = entry.value_ptr.traced;
                const total = traced + entry.value_ptr.interp;
                if (total < 1000) continue; // not one of the two hot loop anchors
                anchors += 1;
                // TODAY (doc 55 §3): both the outer `for` and the inner
                // `while` anchor run under 10% of their iterations traced.
                // Doc 56 flips this to the §9 target once side traces attach.
                try testing.expect(traced * 10 < total);
            }
            try testing.expectEqual(@as(u32, 2), anchors);
        }
    };
    try expectProgramTuned(bitreverse_src, "0.5\t1024\n", .{ .coverage = true, .inspect = Inspect.run });
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
/// exactly when some back-edge at or after the anchor returns to the link
/// target at or before it, i.e. the loop headed at the target contains the
/// anchor. Returns how many links are `.enclosing_iteration`.
fn expectLinkKindsMatchLoops(vm: *Vm) !usize {
    var enclosing: usize = 0;
    for (vm.trace.registry.cache.items) |t| {
        const c = &t.code;
        const n = c.instrs.len;
        if (n == 0 or c.instrs[n - 1].op != .link) continue;
        const target: i64 = c.instrs[n - 1].aux;
        const a: i64 = c.anchor.pc;
        var contains = false;
        for (c.anchor.proto.code, 0..) |ins, pc| switch (ins.op) {
            .for_loop, .tfor_loop, .jmp => {
                const back: i64 = @intCast(pc);
                if (back + 1 + ins.aux == target and target <= a and back >= a) contains = true;
            },
            else => {},
        };
        try testing.expectEqual(contains, c.linkClosesIteration());
        enclosing += @intFromBool(contains);
    }
    return enclosing;
}

test "doc 56 Phase 3: a continuation that closes at its enclosing loop tags its link as an iteration" {
    // The post-`while` continuation (`j = j + k`, then the `for` back-edge)
    // links to the `for` root that CONTAINS it (LuaJIT `LJ_TRLINK_ROOT`):
    // one run to its `.link` finishes an iteration of that `for`. A ramp
    // into the inner `while` root keeps the doc 15 `.inner_root` kind.
    const Inspect = struct {
        fn run(vm: *Vm, mode: TraceMode) !void {
            const enclosing = try expectLinkKindsMatchLoops(vm);
            // Continuations only arm off executed loop-done exits.
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
    , "240\n", .{ .inspect = Inspect.run });
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
    try util.runCapturedTuned(testing.allocator, bitreverse_src, &sink, false, .record_execute, .{ .inspect = Inspect.run });
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
