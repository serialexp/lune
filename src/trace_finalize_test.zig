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
    pending_stores: std.ArrayListUnmanaged(struct { op: ir.IrOp, aref: ir.Ref, value: ir.Ref, lane_ord: i32 }) = .empty,
    reg_map: []const struct { state: enum { undef, input, def }, ref: ir.Ref } = &.{},
    peel: ?struct { slots: []const struct { phi_ref: ?ir.Ref } } = null,
    guard_gc_ref: ?ir.Ref = null,
    alloc_count: u32 = 0,
    anchor_num_registers: u16 = 1,
    locals_watermark: u16 = 1,
    link_target: ?u32 = null,
    terminal_close: ?struct { kind: ir.TerminalKind, resume_pc: u32 } = null,
    pending_link_provenance: ?types.ExitProvenance = null,
    rec_path_ok: bool = true,
    anchor: types.AnchorKey = undefined,
    unrolled_while: bool = false,
    side_src: ?types.ExitKey = .{ .trace_id = 12, .exit_instr = 2 },

    fn deinit(self: *Scratch, gpa: std.mem.Allocator) void {
        inline for (.{ "instrs", "consts", "entry_slots", "input_seeds", "exit_prov", "rec_path", "pending_stores" }) |field|
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
        }) catch continue;
        scratch.entry_slots.append(gpa, 0) catch continue;
        scratch.input_seeds.append(gpa, .{ .kind = .global, .source = 0, .slot = 1 }) catch continue;
        var candidate = finalizer.finalize(gpa, &scratch, .{ .optimize = false }) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        candidate.deinit(gpa);
    }
}
