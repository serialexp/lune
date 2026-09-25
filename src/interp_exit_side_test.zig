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
    const nativegen = @import("nativegen.zig");
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
