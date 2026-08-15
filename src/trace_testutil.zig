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
