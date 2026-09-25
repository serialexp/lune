const std = @import("std");
const finalizer = @import("trace_finalize.zig");
const ir = @import("trace_ir.zig");
const types = @import("trace_types.zig");
const code = @import("trace_code.zig");

// A scratch-only fixture deliberately proves finalize needs no Recorder import.
const Scratch = struct {
    instrs: std.ArrayListUnmanaged(ir.IrInstr) = .empty,
    consts: std.ArrayListUnmanaged(@import("value.zig").Value) = .empty,
    entry_slots: std.ArrayListUnmanaged(u16) = .empty,
    input_seeds: std.ArrayListUnmanaged(code.InputSeed) = .empty,
    exit_prov: std.ArrayListUnmanaged(?types.ExitProvenance) = .empty,
    rec_path: std.ArrayListUnmanaged(types.ProgramPoint) = .empty,
    lane_pins: std.ArrayListUnmanaged(code.LanePin) = .empty,
    pending_stores: std.ArrayListUnmanaged(struct { op: ir.IrOp, aref: ir.Ref, value: ir.Ref, lane_ord: i32, ord: u16 = 0 }) = .empty,
    reg_map: []const struct { state: enum { undef, input, def }, ref: ir.Ref } = &.{},
    peel: ?struct { slots: []const struct { phi_ref: ?ir.Ref } } = null,
    guard_gc_ref: ?ir.Ref = null,
    alloc_count: u32 = 0,
    anchor_num_registers: u16 = 1,
    locals_watermark: u16 = 1,
    link_target: ?u32 = null,
    link_kind: ir.LinkKind = .inner_root,
    terminal_close: ?struct { kind: ir.TerminalKind, resume_pc: u32 } = null,
    pending_link_provenance: ?types.ExitProvenance = null,
    rec_path_ok: bool = true,
    anchor: types.AnchorKey = undefined,
    unrolled_while: bool = false,
    side_src: ?types.ExitKey = .{ .trace_id = 12, .exit_instr = 2 },
    // Doc 45 D2: finalize reads the precise flag and, when set, hands the
    // builder's snapshot arrays to the code. The fixture stays entry-replay.
    precise: bool = false,
    snap_builder: @import("trace_snapshot.zig").Builder = .{ .gpa = undefined, .budget = .{} },
    // Doc 56 §4.2: the ordinary recording's exit-snapshot state. The
    // default fixture has no body bytecodes (`cur_ord == 0`), so finalize
    // attaches no exit snapshots.
    snap_builder_init: bool = false,
    cur_ord: u16 = 0,
    exit_ord_overflow: bool = false,
    exit_snap_by_ord: std.ArrayListUnmanaged(ir.SnapIdx) = .empty,

    fn deinit(self: *Scratch, gpa: std.mem.Allocator) void {
        inline for (.{ "instrs", "consts", "entry_slots", "input_seeds", "exit_prov", "rec_path", "pending_stores", "lane_pins", "exit_snap_by_ord" }) |field|
            @field(self, field).deinit(gpa);
    }
};

test "finalize owns code independently and excludes synthetic fingerprint slots" {
    const gpa = std.testing.allocator;
    var scratch: Scratch = .{};
    defer scratch.deinit(gpa);
    try scratch.instrs.appendSlice(gpa, &.{
        .{ .op = .slot_load, .aux = 0 },
        .{ .op = .guard_int, .a = 0 },
        .{ .op = .slot_load, .aux = 1 },
        .{ .op = .guard_float, .a = 2 },
    });
    try scratch.entry_slots.append(gpa, 0);
    try scratch.input_seeds.append(gpa, .{ .kind = .global, .source = 0, .slot = 1 });
    scratch.rec_path_ok = false;
    var candidate = try finalizer.finalize(gpa, &scratch, .{ .optimize = false });
    defer candidate.deinit(gpa);
    const frozen = candidate.getCode().?;
    try std.testing.expectEqual(ir.IrOp.loop, frozen.instrs[4].op);
    try std.testing.expectEqual(@as(usize, 1), frozen.entry_guards.len);
    try std.testing.expectEqual(@as(u16, 0), frozen.entry_guards[0].slot);
    try std.testing.expect(!frozen.rec_path_complete);
    try std.testing.expect(frozen.bridge_cand_built);
    try std.testing.expectEqual(@as(u64, 12), candidate.side_src.?.trace_id);
    scratch.instrs.items[0].aux = 99;
    scratch.input_seeds.items[0].source = 99;
    try std.testing.expectEqual(@as(i32, 0), frozen.instrs[0].aux);
    try std.testing.expectEqual(@as(u32, 0), frozen.inputs[0].source);
}

test "finalize optimizes an empty loop and preserves candidate ownership" {
    const gpa = std.testing.allocator;
    var scratch: Scratch = .{};
    defer scratch.deinit(gpa);
    var candidate = try finalizer.finalize(gpa, &scratch, .{});
    defer candidate.deinit(gpa);
    var frozen = candidate.take().?;
    defer frozen.deinit(gpa);
    try std.testing.expectEqual(ir.IrOp.loop, frozen.instrs[frozen.instrs.len - 1].op);
}

test "finalizer allocation failures clean nonempty candidate arrays" {
    // Sweep beyond all fixture/finalization allocation sites. Metadata and
    // optimizer failures may be fail-soft, so success is valid at any index.
    for (0..40) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        const gpa = failing.allocator();
        var scratch: Scratch = .{};
        defer scratch.deinit(gpa);
        scratch.instrs.appendSlice(gpa, &.{
            .{ .op = .slot_load, .aux = 0 },
            .{ .op = .guard_int, .a = 0 },
            .{ .op = .guard_lane, .a = 0, .aux = 0 },
        }) catch continue;
        scratch.entry_slots.append(gpa, 0) catch continue;
        scratch.input_seeds.append(gpa, .{ .kind = .global, .source = 0, .slot = 1 }) catch continue;
        // Doc 48: exercise the fail-soft lane-pin finalization path under
        // allocator failure (codex round-2 — the pin list's append AND
        // toOwnedSlice failure legs must not leak).
        scratch.lane_pins.append(gpa, .{ .guard_ref = 2, .table_id = 7 }) catch continue;
        var candidate = finalizer.finalize(gpa, &scratch, .{ .optimize = false }) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        candidate.deinit(gpa);
    }
}

// ---------------------------------------------------------------------------
// Doc 56 §4.2: exit snapshots through finalize
// ---------------------------------------------------------------------------

const trace_snapshot = @import("trace_snapshot.zig");
const Value = @import("value.zig").Value;
const bytecode = @import("bytecode.zig");

/// Fill `scratch` with an ordinary recording that carries two exit
/// snapshots (the tropt doc 56 fold fixture, before phis/loop):
///   ord 1: `%2 = mul r1, r1` and `%3 = add r1, r1` (snapshot-only values)
///   ord 2: `guard_int %0` — a runtime guard; its snapshot restores r2 = %2
///   ord 3: `guard_int %4` on a konst — folded by tropt; restores r3 = %3
/// Snapshot record 1 belongs to ord 2, record 2 to ord 3. The builder uses
/// `builder_gpa` (so an allocation sweep can fail only finalize's own
/// allocations).
fn exitSnapScratch(gpa: std.mem.Allocator, builder_gpa: std.mem.Allocator, scratch: anytype, proto: *const bytecode.Proto, ord3_ref: ir.Ref) !void {
    try scratch.instrs.appendSlice(gpa, &.{
        .{ .op = .slot_load, .aux = 0 }, // %0
        .{ .op = .slot_load, .aux = 1 }, // %1
        .{ .op = .mul, .a = 1, .b = 1, .ord = 1 }, // %2
        .{ .op = .add, .a = 1, .b = 1, .ord = 1 }, // %3
        .{ .op = .konst, .aux = 0, .ord = 2 }, // %4 = 5
        .{ .op = .guard_int, .a = 0, .ord = 2 }, // %5
        .{ .op = .guard_int, .a = 4, .ord = 3 }, // %6
    });
    try scratch.consts.append(gpa, Value.int(5));
    try scratch.entry_slots.append(gpa, 0);
    scratch.anchor = .{ .proto = proto, .pc = 0 };
    scratch.anchor_num_registers = 4;
    scratch.snap_builder = trace_snapshot.Builder.init(builder_gpa, .{});
    scratch.snap_builder_init = true;
    _ = try scratch.snap_builder.addSparse(1, 4, &.{.{ .slot = 2, .ref = 2 }});
    _ = try scratch.snap_builder.addSparse(2, 4, &.{.{ .slot = 3, .ref = ord3_ref }});
    scratch.cur_ord = 3;
    try scratch.exit_snap_by_ord.appendSlice(gpa, &.{ 0, 0, 1, 2 });
}

fn exitProto() bytecode.Proto {
    return .{ .code = &exit_proto_code, .name = "exit-snap-finalize", .id = 56 };
}
var exit_proto_code = [_]bytecode.Instr{ bytecode.Instr.op0(.halt), bytecode.Instr.op0(.halt), bytecode.Instr.op0(.halt) };

test "doc 56 finalize: an unoptimized recording keeps every exit snapshot as recorded" {
    const gpa = std.testing.allocator;
    const proto = exitProto();
    var scratch: Scratch = .{};
    defer scratch.deinit(gpa);
    try exitSnapScratch(gpa, gpa, &scratch, &proto, 3);
    defer scratch.snap_builder.deinit();
    var candidate = try finalizer.finalize(gpa, &scratch, .{ .optimize = false });
    defer candidate.deinit(gpa);
    const c = candidate.getCode().?;
    try std.testing.expectEqual(@as(usize, 2), c.exit_snapshots.len);
    try std.testing.expectEqualSlices(ir.SnapIdx, &.{ 0, 0, 1, 2 }, c.exit_snap_by_ord);
    try std.testing.expectEqual(@as(?ir.SnapIdx, 1), c.exitSnapIdx(5));
    try std.testing.expectEqual(@as(?ir.SnapIdx, 2), c.exitSnapIdx(6));
    try std.testing.expectEqual(@as(?ir.SnapIdx, null), c.exitSnapIdx(2)); // not a side exit
    // The code owns its copy: the builder is reusable.
    scratch.snap_builder.reset();
    try std.testing.expectEqual(@as(u32, 3), c.exit_snapshot_slots[1].ref);
}

test "doc 56 finalize: tropt drops a folded guard's snapshot and finalize compacts the store" {
    const gpa = std.testing.allocator;
    const proto = exitProto();
    var scratch: Scratch = .{};
    defer scratch.deinit(gpa);
    try exitSnapScratch(gpa, gpa, &scratch, &proto, 3);
    defer scratch.snap_builder.deinit();
    var candidate = try finalizer.finalize(gpa, &scratch, .{});
    defer candidate.deinit(gpa);
    const c = candidate.getCode().?;
    // Ord 3's only exit folded away: its record is gone, ord 2's record is
    // renumbered to 1, and its ref names the committed `mul`.
    try std.testing.expectEqual(@as(usize, 1), c.exit_snapshots.len);
    try std.testing.expectEqualSlices(ir.SnapIdx, &.{ 0, 0, 1, 0 }, c.exit_snap_by_ord);
    try std.testing.expectEqual(@as(usize, 1), c.exit_snapshot_slots.len);
    try std.testing.expectEqual(@as(u32, 1), c.exit_snapshots[0].resume_pc);
    const ss = c.exit_snapshot_slots[0];
    try std.testing.expectEqual(@as(u16, 2), ss.slot);
    try std.testing.expectEqual(ir.IrOp.mul, c.instrs[ss.ref].op);
    var add_kept = false;
    for (c.instrs) |ins| add_kept = add_kept or ins.op == .add;
    try std.testing.expect(!add_kept);
    // The kept guard still finds it.
    var found = false;
    for (0..c.instrs.len) |i| if (c.exitSnapIdx(i)) |si| {
        try std.testing.expectEqual(ir.IrOp.guard_int, c.instrs[i].op);
        try std.testing.expectEqual(@as(ir.SnapIdx, 1), si);
        found = true;
    };
    try std.testing.expect(found);
}

test "doc 56 finalize: a snapshot naming a ref at or after its exit drops them all" {
    const gpa = std.testing.allocator;
    const proto = exitProto();
    var scratch: Scratch = .{};
    defer scratch.deinit(gpa);
    // Ord 3's exit is instr 6; a snapshot ref of 6 is not defined there.
    try exitSnapScratch(gpa, gpa, &scratch, &proto, 6);
    defer scratch.snap_builder.deinit();
    var candidate = try finalizer.finalize(gpa, &scratch, .{ .optimize = false });
    defer candidate.deinit(gpa);
    const c = candidate.getCode().?;
    try std.testing.expectEqual(@as(usize, 0), c.exit_snapshots.len);
    try std.testing.expectEqual(@as(usize, 0), c.exit_snapshot_slots.len);
    try std.testing.expectEqual(@as(usize, 0), c.exit_snap_by_ord.len);
    // The trace itself is unaffected.
    try std.testing.expectEqual(ir.IrOp.loop, c.instrs[c.instrs.len - 1].op);
}

test "doc 56 finalize: precise, peeled and ordinal-overflowed recordings attach no exit snapshots" {
    const gpa = std.testing.allocator;
    const proto = exitProto();
    for (0..2) |case| {
        var scratch: Scratch = .{};
        defer scratch.deinit(gpa);
        try exitSnapScratch(gpa, gpa, &scratch, &proto, 3);
        defer scratch.snap_builder.deinit();
        switch (case) {
            0 => scratch.exit_ord_overflow = true,
            1 => scratch.snap_builder_init = false,
            else => unreachable,
        }
        var candidate = try finalizer.finalize(gpa, &scratch, .{ .optimize = false });
        defer candidate.deinit(gpa);
        const c = candidate.getCode().?;
        try std.testing.expectEqual(@as(usize, 0), c.exit_snapshots.len);
        try std.testing.expectEqual(@as(usize, 0), c.exit_snap_by_ord.len);
    }
}

test "doc 56 finalize: allocation failures with exit snapshots never leak" {
    // Every finalize allocation fails in turn, on both the optimize and the
    // dupe paths; the exit snapshots are fail-soft, so success is fine too.
    for ([_]bool{ false, true }) |optimize| {
        for (0..60) |fail_index| {
            var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
            const gpa = failing.allocator();
            const proto = exitProto();
            var scratch: Scratch = .{};
            defer scratch.deinit(std.testing.allocator);
            try exitSnapScratch(std.testing.allocator, std.testing.allocator, &scratch, &proto, 3);
            defer scratch.snap_builder.deinit();
            var candidate = finalizer.finalize(gpa, &scratch, .{ .optimize = optimize }) catch |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
                continue;
            };
            candidate.deinit(gpa);
        }
    }
}

test "doc 56 exitSnapshotsValid rejects each malformed shape" {
    var instrs = [_]ir.IrInstr{
        .{ .op = .slot_load, .aux = 0 }, // 0
        .{ .op = .mul, .a = 0, .b = 0, .ord = 1 }, // 1
        .{ .op = .guard_int, .a = 0, .ord = 1 }, // 2
        .{ .op = .loop }, // 3
    };
    const Case = struct { snaps: [1]trace_snapshot.Snapshot, slots: [1]trace_snapshot.SnapshotSlot, by_ord: [2]ir.SnapIdx, regs: u16 = 4, code_len: u32 = 3 };
    const good: Case = .{
        .snaps = .{.{ .resume_pc = 1, .slots_begin = 0, .slots_len = 1, .register_count = 4 }},
        .slots = .{.{ .slot = 2, .ref = 1 }},
        .by_ord = .{ 0, 1 },
    };
    const S = struct {
        fn check(ins: []const ir.IrInstr, cs: Case) bool {
            var c = cs;
            return finalizer.exitSnapshotsValid(ins, .{ .snapshots = &c.snaps, .snapshot_slots = &c.slots }, &c.by_ord, c.regs, c.code_len);
        }
    };
    try std.testing.expect(S.check(&instrs, good));

    var bad = good;
    bad.snaps[0].resume_pc = 3; // outside the anchor proto's code
    try std.testing.expect(!S.check(&instrs, bad));
    bad = good;
    bad.snaps[0].register_count = 5; // not the anchor window width
    bad.regs = 4;
    try std.testing.expect(!S.check(&instrs, bad));
    bad = good;
    bad.slots[0].slot = 4; // slot outside the window
    try std.testing.expect(!S.check(&instrs, bad));
    bad = good;
    bad.slots[0].ref = 9; // ref outside the stream
    try std.testing.expect(!S.check(&instrs, bad));
    bad = good;
    bad.slots[0].ref = 2; // ref is the guard itself: not defined at its exit
    try std.testing.expect(!S.check(&instrs, bad));
    bad = good;
    bad.by_ord[0] = 1; // ordinal 0 must mean "none"
    try std.testing.expect(!S.check(&instrs, bad));
    bad = good;
    bad.by_ord[1] = 2; // names a record that does not exist
    try std.testing.expect(!S.check(&instrs, bad));
    bad = good;
    bad.snaps[0].slots_len = 2; // vector runs past the flat array
    try std.testing.expect(!S.check(&instrs, bad));

    // An instruction whose ordinal is past the table.
    instrs[1].ord = 2;
    try std.testing.expect(!S.check(&instrs, good));
    instrs[1].ord = 1;
    // An empty ordinal table is invalid (it always holds ordinal 0).
    try std.testing.expect(!finalizer.exitSnapshotsValid(&instrs, .{ .snapshots = &.{}, .snapshot_slots = &.{} }, &.{}, 4, 3));
}
