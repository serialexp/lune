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
const lune_parser = @import("parser.zig");
const lune_compiler = @import("compiler.zig");
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
/// Restore the given file and assert it fails with exactly `want`.
pub fn expectRestoreError(file: schema.SnapshotFile, root: *const Proto, want: RestoreError) !void {
    const gpa = testing.allocator;
    if (restoreSnapshot(gpa, file, root, NativeRegistry.base())) |vm| {
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
    var diags = Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try lune_parser.parse(gpa, source, &diags);
    defer tree.deinit();

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var buf: [512]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;

    var chunk = try lune_compiler.compile(gpa, &vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());

    _ = try vm.run(chunk.proto);

    return .{
        .full_out = try gpa.dupe(u8, sink.buffered()),
        .final_snap = try encodeSnapshot(gpa, &vm),
        .total_safepoints = vm.safepoint_seq,
    };
}
