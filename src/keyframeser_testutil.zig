//! Shared test harness for `keyframeser.zig`.
//!
//! Extracted verbatim from `keyframeser.zig`; bodies are unchanged.

const keyframeser = @import("keyframeser.zig");
const std = @import("std");
const value = @import("value.zig");
const object = @import("object.zig");
const string = @import("string.zig");
const table = @import("table.zig");
const arr = @import("array.zig");
const function = @import("function.zig");
const bytecode = @import("bytecode.zig");
const interp = @import("interp.zig");
const gc = @import("gc.zig");
const key_order = @import("key_order.zig");
const parser = @import("parser.zig");
const compiler = @import("compiler.zig");
const diag = @import("diag.zig");
const trace = @import("trace.zig");
const Value = value.Value;
const GcHeader = object.GcHeader;
const Proto = bytecode.Proto;
const Vm = interp.Vm;
pub const schema = @import("gen/trace_schema.zig");
const testing = std.testing;
const mahina_parser = @import("parser.zig");
const mahina_compiler = @import("compiler.zig");
const Diagnostics = @import("diag.zig").Diagnostics;
const io = @import("io.zig");

const NativeRegistry = keyframeser.NativeRegistry;
const RestoreError = keyframeser.RestoreError;
const encodeSnapshot = keyframeser.encodeSnapshot;
const restoreSnapshot = keyframeser.restoreSnapshot;

// Small SnapValue constructors for the hand-built corpus.
pub fn sNil() schema.SnapValue {
    return .{ .tag = 0, .body = .{ .ConstNil = .{ .pad = 0 } } };
}
pub fn sBool(b: bool) schema.SnapValue {
    return .{ .tag = 1, .body = .{ .ConstBool = .{ .v = @intFromBool(b) } } };
}
pub fn sInt(v: i64) schema.SnapValue {
    return .{ .tag = 2, .body = .{ .ConstInt = .{ .v = v } } };
}
pub fn sFloat(v: f64) schema.SnapValue {
    return .{ .tag = 3, .body = .{ .ConstFloat = .{ .v = v } } };
}
pub fn sRef(id: u32) schema.SnapValue {
    return .{ .tag = 4, .body = .{ .HeapRef = .{ .id = id } } };
}
/// A register (`Keyframe.stack` entry) holding `sv`.
pub const reg = keyframeser.stackValueOf;
/// A register tombstone (doc 61 Phase K).
pub const regDead = keyframeser.dead_slot;
/// Restore the given file and assert it fails with exactly `want`.
pub fn expectRestoreError(file: schema.SnapshotFile, program: keyframeser.Program, want: RestoreError) !void {
    const gpa = testing.allocator;
    if (restoreSnapshot(gpa, file, program, NativeRegistry.base())) |vm| {
        vm.deinit();
        gpa.destroy(vm);
        return error.TestUnexpectedSuccess;
    } else |err| {
        try testing.expectEqual(want, err);
    }
}
/// A reference (uninterrupted) run of `source`: its full output `F`, its
/// final-state snapshot `Sf`, and the total safepoint count (to place a mid-run
/// suspend). Owns the two byte buffers.
pub const RefRun = struct {
    full_out: []u8,
    final_snap: []u8,
    total_safepoints: u64,

    pub fn deinit(self: RefRun, gpa: std.mem.Allocator) void {
        gpa.free(self.full_out);
        gpa.free(self.final_snap);
    }
};

pub fn referenceRun(gpa: std.mem.Allocator, source: [:0]const u8) !RefRun {
    return referenceRunWith(gpa, source, null);
}

/// Prepares a VM for a program before it starts (`referenceRunWith`):
/// installs globals the program uses, given its compiled root.
pub const Setup = *const fn (*Vm, *const bytecode.Proto) anyerror!void;

/// `referenceRun` with `setup` run on the VM before the program starts.
pub fn referenceRunWith(gpa: std.mem.Allocator, source: [:0]const u8, setup: ?Setup) !RefRun {
    var diags = Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try mahina_parser.parse(gpa, source, &diags);
    defer tree.deinit();

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var buf: [512]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;

    var chunk = try mahina_compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    if (setup) |s| try s(&vm, chunk.proto);

    _ = try vm.run(chunk.proto);

    return .{
        .full_out = try gpa.dupe(u8, sink.buffered()),
        .final_snap = try encodeSnapshot(gpa, &vm),
        .total_safepoints = vm.safepoint_seq,
    };
}

/// The backing allocator for a `checkAllAllocationFailures` run whose code
/// grows blocks: no block changes size in place (`resize`/`remap` refuse), so
/// every growth is a fresh allocation. On the plain testing allocator a block
/// grows in place or not by the address layout earlier work left (a restore
/// re-parses, and the parser's arena grows), so the allocations a run makes
/// are not a function of the code alone, and the check reports
/// `NondeterministicMemoryUsage` for a run that is fine.
pub const NoResizeInPlace = struct {
    child: std.mem.Allocator,

    pub fn allocator(self: *NoResizeInPlace) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *NoResizeInPlace = @ptrCast(@alignCast(ctx));
        return self.child.rawAlloc(len, alignment, ra);
    }

    fn resize(_: *anyopaque, memory: []u8, _: std.mem.Alignment, new_len: usize, _: usize) bool {
        return new_len == memory.len;
    }

    fn remap(_: *anyopaque, memory: []u8, _: std.mem.Alignment, new_len: usize, _: usize) ?[*]u8 {
        return if (new_len == memory.len) memory.ptr else null;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *NoResizeInPlace = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ra);
    }
};

/// Expect two snapshots to hold the same state, as a run under one tier and
/// the same program under another must. The one field that may differ is
/// `vm_state.safepoint_seq` (doc 86 §6.1): it counts tier-0 steps, and a
/// native trace runs its iterations without passing a safepoint. Every other
/// byte, the rest of the VM state included, must match.
pub fn expectSameStateAcrossTiers(want: []const u8, got: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var w = try schema.SnapshotFile.decode(a, want);
    var g = try schema.SnapshotFile.decode(a, got);
    w.keyframe.vm_state.safepoint_seq = 0;
    g.keyframe.vm_state.safepoint_seq = 0;
    try testing.expectEqualSlices(u8, try w.encode(a), try g.encode(a));
}
