//! Shared test harness for `trace.zig`.
//!
//! Extracted verbatim from `trace.zig`; bodies are unchanged.

const trace = @import("trace.zig");
const std = @import("std");
const bytecode = @import("bytecode.zig");
const arith = @import("arith.zig");
const value = @import("value.zig");
const function = @import("function.zig");
const regwindow = @import("regwindow.zig");
const RegWindow = regwindow.RegWindow;
const io = @import("io.zig");
const tropt = @import("tropt.zig");
const execlog = @import("execlog.zig");
const nativegen = @import("nativegen.zig");
const irinterp = @import("irinterp.zig");
const jitdbg = @import("jitdbg.zig");
const trace_ir = @import("trace_ir.zig");
const trace_snapshot = @import("trace_snapshot.zig");
const Value = value.Value;
const Proto = bytecode.Proto;
const Instr = bytecode.Instr;
const OpCode = bytecode.OpCode;
const table_mod = @import("table.zig");
const arr = @import("array.zig");
const testing = std.testing;

// Test-only register-window adapters over the SoA lanes. The unit tests build flat
// `[]Value` register fixtures; `winRO` seeds shared scratch lanes from one and hands
// back a read-only window (recorder / fingerprint sites never write `regs` back).
// `TestRegs` owns its lanes and adds `commit()` for the few sites whose callee
// mutates the window and whose test then asserts on the post-run register state.
pub var winro_tags: [64]u8 = undefined;
pub var winro_pays: [64]u64 = undefined;
pub fn winRO(regs: []const Value) RegWindow {
    std.debug.assert(regs.len <= winro_tags.len);
    for (regs, 0..) |v, i| {
        winro_tags[i] = @intFromEnum(v.tag);
        winro_pays[i] = v.payload.bits;
    }
    return RegWindow.of(winro_tags[0..regs.len], winro_pays[0..regs.len]);
}

/// Doc 58 B2 review, blocker 1: composite-bridge candidacy requires the
/// state a bridge's φs commit at a guard (`TraceCode.bridgeEmissions`) to
/// agree with that guard's exit snapshot (`bridgeMatchesExitSnapshot`). A
/// hand-built trace has no recorder, so it has no snapshots; this gives each
/// `.branch_cond` guard the snapshot a recording would carry for exactly the
/// state its φs claim — i.e. the fixture declares that it models a SOUND
/// bridge. A fixture that tests refusal must not call this. Stamps `ord` on
/// those guards; must run before the trace is compiled or its bridge memo is
/// built, and on a trace that has no exit snapshots yet.
pub fn snapshotBranchGuardsFromPhis(gpa: std.mem.Allocator, code: *trace.TraceCode) !void {
    std.debug.assert(code.exit_snapshots.len == 0 and code.exit_snap_by_ord.len == 0);
    var snaps: std.ArrayListUnmanaged(trace_snapshot.Snapshot) = .empty;
    defer snaps.deinit(gpa);
    var slots: std.ArrayListUnmanaged(trace_snapshot.SnapshotSlot) = .empty;
    defer slots.deinit(gpa);
    var by_ord: std.ArrayListUnmanaged(trace_ir.SnapIdx) = .empty;
    defer by_ord.deinit(gpa);
    try by_ord.append(gpa, 0); // ordinal 0 = none
    for (code.instrs, 0..) |*g, gi| {
        if (g.op != .guard_true and g.op != .guard_false) continue;
        const gp = switch (code.provAt(@intCast(gi)) orelse continue) {
            .guard => |x| x,
            .link_terminal => continue,
        };
        if (gp.role != .branch_cond) continue;
        const begin = slots.items.len;
        var emitted = code.bridgeEmissions(gi);
        while (emitted.next()) |p| try slots.append(gpa, .{ .slot = @intCast(p.aux), .ref = p.b });
        try snaps.append(gpa, .{
            .resume_pc = gp.source_pc,
            .slots_begin = @intCast(begin),
            .slots_len = @intCast(slots.items.len - begin),
            .register_count = code.anchor.proto.num_registers,
        });
        g.ord = @intCast(by_ord.items.len);
        try by_ord.append(gpa, @intCast(snaps.items.len));
    }
    if (snaps.items.len == 0) return;
    const owned_snaps = try snaps.toOwnedSlice(gpa);
    errdefer gpa.free(owned_snaps);
    const owned_slots = try slots.toOwnedSlice(gpa);
    errdefer gpa.free(owned_slots);
    const owned_by_ord = try by_ord.toOwnedSlice(gpa);
    code.exit_snapshots = owned_snaps;
    code.exit_snapshot_slots = owned_slots;
    code.exit_snap_by_ord = owned_by_ord;
}

pub const TestRegs = struct {
    regs: []Value,
    tags: [64]u8 = undefined,
    pays: [64]u64 = undefined,
    pub fn view(self: *TestRegs) RegWindow {
        std.debug.assert(self.regs.len <= self.tags.len);
        for (self.regs, 0..) |v, i| {
            self.tags[i] = @intFromEnum(v.tag);
            self.pays[i] = v.payload.bits;
        }
        return RegWindow.of(self.tags[0..self.regs.len], self.pays[0..self.regs.len]);
    }
    pub fn commit(self: *TestRegs) void {
        for (self.regs, 0..) |*v, i| v.* = .{ .tag = @enumFromInt(self.tags[i]), .payload = .{ .bits = self.pays[i] } };
    }
};
