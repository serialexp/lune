//! Shared test harness for `nativegen.zig`.
//!
//! Extracted verbatim from `nativegen.zig`; bodies are unchanged.

const nativegen = @import("nativegen.zig");
const std = @import("std");
const builtin = @import("builtin");
const x64 = @import("x64.zig");
const trace = @import("trace.zig");
const value = @import("value.zig");
const table = @import("table.zig");
const arr = @import("array.zig");
const Value = value.Value;
const RegWindow = @import("regwindow.zig").RegWindow;
const Trace = trace.Trace;
const Reg = x64.Reg;
const object = @import("object.zig");
const function = @import("function.zig");
const bytecode = @import("bytecode.zig");
const testing = std.testing;
const irinterp = @import("irinterp.zig");
const I = trace.IrInstr;
const S = trace.SlotStore;

const CompiledTrace = nativegen.CompiledTrace;
const McodeArena = nativegen.McodeArena;
const compile = nativegen.compile;
const compileInto = nativegen.compileInto;

/// Compare two register files **semantically** (tag + payload bits). The 7 padding
/// bytes of a `Value` are non-semantic and left undefined by `Value.int`/etc., so a
/// raw byte compare would spuriously fail against native code that zeroes them.
pub fn expectRegsEqual(expected: []const Value, actual: []const Value) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, ac| {
        try testing.expectEqual(@intFromEnum(e.tag), @intFromEnum(ac.tag));
        try testing.expectEqual(e.payload.bits, ac.payload.bits);
    }
}

/// Test-only adapter: split a flat `[]Value` register file into the SoA tag/payload
/// lanes the native ABI now consumes, run the trace, scatter the mutated lanes back
/// into `regs`, and return the native result. Mirrors how `Vm.frameWindow` hands the
/// two lanes to `CompiledTrace.run` in production (raw payload bits, no recanon).
pub fn runNative(ct: CompiledTrace, regs: []Value) !irinterp.ExecResult {
    const tags = try testing.allocator.alloc(u8, regs.len);
    defer testing.allocator.free(tags);
    const pays = try testing.allocator.alloc(u64, regs.len);
    defer testing.allocator.free(pays);
    for (regs, 0..) |v, i| {
        tags[i] = @intFromEnum(v.tag);
        pays[i] = v.payload.bits;
    }
    const result = ct.run(RegWindow.of(tags, pays));
    for (regs, 0..) |*v, i| v.* = .{ .tag = @enumFromInt(tags[i]), .payload = .{ .bits = pays[i] } };
    return result;
}
/// Run `t` through both the IR-interpreter (the oracle) and the native compiler on
/// identical fresh register files; assert the same `completed` and final `regs`.
pub fn expectMatch(t: *const Trace, regs_init: []const Value) !void {
    // Oracle: the tier-1a IR-interpreter.
    const iregs = try testing.allocator.dupe(Value, regs_init);
    defer testing.allocator.free(iregs);
    const values = try testing.allocator.alloc(Value, t.instrs.len);
    defer testing.allocator.free(values);
    const iresult = irinterp.executeValues(t, iregs, values);

    // Native: must compile (caller picks compilable traces) and match bit-for-bit.
    var ct = compile(testing.allocator, t) orelse return error.NativeBailedUnexpectedly;
    defer ct.deinit();
    const nregs = try testing.allocator.dupe(Value, regs_init);
    defer testing.allocator.free(nregs);
    const nresult = try runNative(ct, nregs);

    try testing.expectEqual(iresult.completed, nresult.completed);
    try expectRegsEqual(iregs, nregs);
}

/// Like `expectMatch`, but drives the FRAMELESS production path (`compileInto` an
/// `McodeArena` + the shared trampoline), not the self-framed standalone page. This is
/// the ONLY path that dispatches an ordinary guard exit through the memory-staged
/// `NativeResult.exit_target` (2.3c-0). A regression here — e.g. staging the dispatch
/// target in rax, which `flushSlot` clobbers on a spilled carried home — would jump
/// through a corrupt address and crash, so a clean match is the guard against blocker-1.
pub fn expectMatchFrameless(t: *const Trace, regs_init: []const Value) !void {
    const gpa = testing.allocator;
    // Oracle: the tier-1a IR-interpreter.
    const iregs = try gpa.dupe(Value, regs_init);
    defer gpa.free(iregs);
    const values = try gpa.alloc(Value, t.instrs.len);
    defer gpa.free(values);
    const iresult = irinterp.executeValues(t, iregs, values);

    // Native, frameless: compile into a real arena so the shared trampoline + link-slot
    // table + indirect exit dispatch are all live (arena.deinit must outlive ct, which
    // holds an arena-slot page — defer LIFO runs ct.deinit first).
    var arena = McodeArena.init(gpa);
    defer arena.deinit();
    var ct = compileInto(gpa, &arena, t, null, null) orelse return error.NativeBailedUnexpectedly;
    defer ct.deinit();
    try testing.expect(ct.trampoline_entry != null); // really the frameless path

    const nregs = try gpa.dupe(Value, regs_init);
    defer gpa.free(nregs);
    const nresult = try runNative(ct, nregs);

    try testing.expectEqual(iresult.completed, nresult.completed);
    try expectRegsEqual(iregs, nregs);
}
/// Assert `compile` bails (returns null) for an unsupported trace.
pub fn expectBail(t: *const Trace) !void {
    if (compile(testing.allocator, t)) |ct| {
        var c = ct;
        c.deinit();
        return error.TestExpectedBail;
    }
}
/// Assert two tables hold the same logical value at every dense key `1..len`.
pub fn expectTablesEqual(ta: *table.Table, tb: *table.Table, len: i64) !void {
    var k: i64 = 1;
    while (k <= len) : (k += 1) {
        const va = ta.getInt(k);
        const vb = tb.getInt(k);
        try testing.expectEqual(@intFromEnum(va.tag), @intFromEnum(vb.tag));
        try testing.expectEqual(va.payload.bits, vb.payload.bits);
    }
}
