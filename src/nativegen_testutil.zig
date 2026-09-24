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
const Trace = @import("trace_code.zig").TraceCode;
const Reg = x64.Reg;
const object = @import("object.zig");
const function = @import("function.zig");
const bytecode = @import("bytecode.zig");
const testing = std.testing;
const irinterp = @import("irinterp.zig");
const trace_exec = @import("trace_exec.zig");
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
pub fn runNative(ct: CompiledTrace, regs: []Value) !trace_exec.ExecResult {
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

    // Use the production shared trampoline; compiled code dies before its arena.
    var arena = McodeArena.init(testing.allocator);
    defer arena.deinit();
    var ct = compileInto(testing.allocator, &arena, t, 0, null, null) orelse return error.NativeBailedUnexpectedly;
    defer ct.deinit();
    try testing.expect(ct.trampoline_entry != null);
    const nregs = try testing.allocator.dupe(Value, regs_init);
    defer testing.allocator.free(nregs);
    const nresult = try runNative(ct, nregs);

    try testing.expectEqual(iresult.completed, nresult.local_completed);
    switch (nresult.exit_reason) {
        .normal => {
            // Native fuses a value-lane load's tag guard into the load. The
            // oracle reports the following explicit type guard instead.
            if (iresult.exit_instr != nresult.exit_instr) {
                const load = t.instrs[nresult.exit_instr];
                const guard = t.instrs[iresult.exit_instr];
                try testing.expectEqual(trace.IrOp.aload, load.op);
                try testing.expectEqual(nativegen.VALUE_LANE, load.aux);
                try testing.expectEqual(nresult.exit_instr, @as(u32, guard.a));
                try testing.expect(guard.op == .guard_int or guard.op == .guard_float or guard.op == .guard_table);
            }
        },
        .prologue_fail => try testing.expectEqual(@as(usize, 0), iresult.completed),
        .seed_hash_decline, .seed_capacity_decline => return error.UnexpectedSeedDecline,
        // Doc 45 D6: native never runs a precise trace until its own
        // executor lands (`compileImpl` bails), so these cannot surface here.
        .precise_resume, .precise_error => return error.UnexpectedPreciseExit,
    }
    try expectRegsEqual(iregs, nregs);
}

/// Assert `compile` bails (returns null) for an unsupported trace.
pub fn expectBail(t: *const Trace) !void {
    if (compile(testing.allocator, t, 0)) |ct| {
        var c = ct;
        c.deinit();
        return error.TestExpectedBail;
    }
}

/// Doc 55 §2d: decode silent site `p`'s compiled check and pin its shape. It must
/// load exactly this exit's cell address (`mov rax, imm64` = REX.W B8), branch
/// to exactly this exit's epilogue (`jne rel32` = 0F 85), and fall through at
/// `resume_off`. The check is compile-time code that is never rewritten, so
/// this holds for the page's whole life, promoted or not.
pub fn expectSilentCheck(ct: *const CompiledTrace, p: nativegen.SilentSite) !void {
    const code = ct.page.code;
    try testing.expectEqual(@as(u8, 0x48), code[p.check_off]);
    try testing.expectEqual(@as(u8, 0xB8), code[p.check_off + 1]);
    try testing.expectEqual(@as(u64, @intFromPtr(p.metadata_cell)), std.mem.readInt(u64, code[p.check_off + 2 ..][0..8], .little));
    const jcc = p.resume_off - 6;
    try testing.expectEqual(@as(u8, 0x0F), code[jcc]);
    try testing.expectEqual(@as(u8, 0x85), code[jcc + 1]);
    const disp = std.mem.readInt(i32, code[jcc + 2 ..][0..4], .little);
    try testing.expectEqual(@as(i64, p.epilogue_off), @as(i64, p.resume_off) + disp);
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
