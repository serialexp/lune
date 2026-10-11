//! Tests for `trace.zig` — ir.
//!
//! Extracted verbatim from `trace.zig`; bodies are unchanged.
//! Shared harness lives in `trace_testutil.zig`.

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

const AnchorKey = trace.AnchorKey;
const IrInstr = trace.IrInstr;
const SlotStore = trace.SlotStore;
const Trace = trace.Trace;
const TraceState = trace.TraceState;
const withPhis = trace.withPhis;
const writeTrace = trace.writeTrace;

// ---------------------------------------------------------------------------
// Tests (Increment A): IR shape + disassembler + hotness counting.
// ---------------------------------------------------------------------------

test "IrInstr stays small" {
    // Cache-sensitive representation; keep it compact. Not serialised here (the
    // wire format is binschema, Phase 5b) — just guard against accidental bloat.
    try testing.expect(@sizeOf(IrInstr) <= 16);
}

test "writeTrace renders a hand-built counting-loop trace" {
    // A stand-in for `for i=lo,hi do acc = acc + i end`'s recorded body:
    //   %0 = slot_load r0   (acc)
    //   %1 = slot_load r1   (i)
    //   %2 = guard_int %0
    //   %3 = guard_int %1
    //   %4 = add %0 %1
    //   loop  (acc<-%4, i<-%1)
    const proto = Proto{ .code = &.{}, .name = "main" };
    var instrs = withPhis(&[_]IrInstr{
        .{ .op = .slot_load, .aux = 0, .ty = .int },
        .{ .op = .slot_load, .aux = 1, .ty = .int },
        .{ .op = .guard_int, .a = 0 },
        .{ .op = .guard_int, .a = 1 },
        .{ .op = .add, .a = 0, .b = 1, .ty = .int },
        .{ .op = .loop },
    }, &[_]SlotStore{ .{ .slot = 0, .ref = 4 }, .{ .slot = 1, .ref = 1 } });
    var entry = [_]u16{ 0, 1 };
    const t = Trace{
        .code = .{
            .anchor = .{ .proto = &proto, .pc = 5, .proto_id = proto.id },
            .instrs = &instrs,
            .consts = &.{},
            .entry_slots = &entry,
            .entry_guards = &.{},
        },
    };

    var buf: [512]u8 = undefined;
    var w = io.Writer.fixed(&buf);
    try writeTrace(&w, &t);
    const text = w.buffered();

    try testing.expect(std.mem.indexOf(u8, text, "trace main:5") != null);
    // Header carries the synthetic-input count against the policy cap
    // (cap-agnostic prefix match so a future cap change doesn't break here).
    try testing.expect(std.mem.indexOf(u8, text, "entry=[r0 r1]  inputs=0/") != null);
    try testing.expect(std.mem.indexOf(u8, text, "slot_load") != null);
    try testing.expect(std.mem.indexOf(u8, text, "guard_int") != null);
    try testing.expect(std.mem.indexOf(u8, text, "add") != null);
    // The two loop-carried writebacks now render as slot-bound φ rows.
    try testing.expect(std.mem.indexOf(u8, text, "update=%4 -> r0") != null);
    try testing.expect(std.mem.indexOf(u8, text, "update=%1 -> r1") != null);
}

test "onBackEdge counts back-edges per anchor" {
    var state = TraceState.init(testing.allocator);
    defer state.deinit();
    state.config.hotloop = 1000; // high enough that nothing arms — pure counting

    const proto = Proto{ .code = &.{}, .name = "t" };
    const hot = AnchorKey{ .proto = &proto, .pc = 3, .proto_id = proto.id };
    const cold = AnchorKey{ .proto = &proto, .pc = 99, .proto_id = proto.id };

    var i: u32 = 0;
    while (i < 10) : (i += 1) state.onBackEdge(&proto, 3, RegWindow.empty);
    state.onBackEdge(&proto, 99, RegWindow.empty); // a single, cold back-edge elsewhere

    try testing.expectEqual(@as(u32, 10), state.backEdgeCount(hot));
    try testing.expectEqual(@as(u32, 1), state.backEdgeCount(cold));
    try testing.expectEqual(@as(usize, 0), state.registry.cache.items.len); // never armed
}

test "crossing the hotness threshold arms a recording" {
    var state = TraceState.init(testing.allocator);
    defer state.deinit();
    state.config.hotloop = 3;

    const proto = Proto{ .code = &.{}, .name = "t", .num_registers = 2 };
    try testing.expect(!state.isRecording());
    state.onBackEdge(&proto, 7, RegWindow.empty); // 1
    state.onBackEdge(&proto, 7, RegWindow.empty); // 2 — not yet hot
    try testing.expect(!state.isRecording());
    state.onBackEdge(&proto, 7, RegWindow.empty); // 3 == hotloop → arm
    try testing.expect(state.isRecording());
    try testing.expectEqual(@as(u32, 7), state.rec.anchor.pc);
}
