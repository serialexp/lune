//! Ownership and dependency-boundary tests for `trace_code.zig`.

const std = @import("std");
const trace_code = @import("trace_code.zig");
const trace_ir = @import("trace_ir.zig");
const trace_types = @import("trace_types.zig");
const value = @import("value.zig");
const RegWindow = @import("regwindow.zig").RegWindow;

const testing = std.testing;
const TraceCode = trace_code.TraceCode;
const Value = value.Value;

test "TraceCode deinit releases every owned artifact array" {
    const gpa = testing.allocator;
    var code = TraceCode{
        .anchor = undefined,
        .instrs = &.{},
        .consts = &.{},
        .entry_slots = &.{},
        .entry_guards = &.{},
    };
    defer code.deinit(gpa);
    code.instrs = try gpa.alloc(trace_ir.IrInstr, 1);
    code.consts = try gpa.alloc(Value, 1);
    code.entry_slots = try gpa.alloc(u16, 1);
    code.inputs = try gpa.alloc(trace_code.InputSeed, 1);
    code.entry_guards = try gpa.alloc(trace_code.EntryGuard, 1);
    code.exit_prov = try gpa.alloc(trace_types.ExitProvEntry, 1);
    code.rec_path = try gpa.alloc(trace_types.ProgramPoint, 1);
    code.bridge_cand = try gpa.alloc(u8, 1);
    code.bridge_cand_built = true;
    // `testing.allocator` checks that all eight independent allocations were freed.
}

test "embedded TraceCode is borrowed at a stable address while runtime metadata changes" {
    const RuntimeRecord = struct {
        code: TraceCode,
        hit_count: u64 = 0,
        native_attempted: bool = false,

        fn borrowedCode(self: *const @This()) *const TraceCode {
            return &self.code;
        }
    };

    var record = RuntimeRecord{ .code = .{
        .anchor = undefined,
        .instrs = &.{},
        .consts = &.{},
        .entry_slots = &.{},
        .entry_guards = &.{},
    } };
    const borrowed = record.borrowedCode();
    record.hit_count += 1;
    record.native_attempted = true;

    try testing.expectEqual(@intFromPtr(borrowed), @intFromPtr(record.borrowedCode()));
    try testing.expectEqual(@as(u64, 1), record.hit_count);
    try testing.expect(record.native_attempted);
}

test "TraceCode const consumer boundary excludes runtime and native state" {
    comptime {
        const FingerprintConsumer = *const fn (*const TraceCode, RegWindow) bool;
        const ProvenanceConsumer = *const fn (*const TraceCode, u32) ?trace_types.ExitProvenance;
        const fingerprint: FingerprintConsumer = TraceCode.matchesFingerprint;
        const provenance: ProvenanceConsumer = TraceCode.provAt;
        _ = fingerprint;
        _ = provenance;

        if (@hasField(TraceCode, "id") or
            @hasField(TraceCode, "native") or
            @hasField(TraceCode, "hit_count") or
            @hasField(TraceCode, "consec_refusals") or
            @hasField(TraceCode, "entry_patch") or
            @hasField(TraceCode, "bridge_decline_exit") or
            @hasField(TraceCode, "anchor_pop") or
            @hasField(TraceCode, "ldl_memo"))
        {
            @compileError("TraceCode crossed the immutable code/runtime ownership boundary");
        }
    }
}

fn codeWithGuards(guards: []trace_code.EntryGuard) TraceCode {
    return .{
        .anchor = undefined,
        .instrs = &.{},
        .consts = &.{},
        .entry_slots = &.{},
        .entry_guards = guards,
    };
}

test "fingerprint boundaries use initialized RegWindow lanes" {
    var tags = [_]u8{ 0, 0, 0 };
    var payloads = [_]u64{ 0, 0, 0 };
    const regs = RegWindow.of(&tags, &payloads);

    var no_guards = [_]trace_code.EntryGuard{};
    const empty = codeWithGuards(&no_guards);
    try testing.expect(empty.matchesFingerprint(regs));

    var int_guard = [_]trace_code.EntryGuard{.{ .slot = 0, .ty = .int }};
    const wants_int = codeWithGuards(&int_guard);
    regs.setInt(0, -9);
    try testing.expect(wants_int.matchesFingerprint(regs));
    regs.setFloat(0, -9.0);
    try testing.expect(!wants_int.matchesFingerprint(regs));

    var float_guard = [_]trace_code.EntryGuard{.{ .slot = 1, .ty = .float }};
    const wants_float = codeWithGuards(&float_guard);
    regs.setFloat(1, 2.5);
    try testing.expect(wants_float.matchesFingerprint(regs));
    regs.setInt(1, 2);
    try testing.expect(!wants_float.matchesFingerprint(regs));

    var number_guards = [_]trace_code.EntryGuard{
        .{ .slot = 0, .ty = .number },
        .{ .slot = 1, .ty = .number },
    };
    const wants_mixed_numbers = codeWithGuards(&number_guards);
    regs.setInt(0, 4);
    regs.setFloat(1, 4.5);
    try testing.expect(wants_mixed_numbers.matchesFingerprint(regs));

    // The number boundary refuses nonnumeric tags regardless of payload bits.
    regs.setBool(0, true);
    try testing.expect(!wants_mixed_numbers.matchesFingerprint(regs));
    regs.setInt(0, 4);
    regs.setNil(1);
    try testing.expect(!wants_mixed_numbers.matchesFingerprint(regs));
}

test "anchor identity (doc 44 D12b): anchorKind/entryPc/contAnchorPc decode every class, head sentinel first" {
    const tc = @import("trace_code.zig");
    // Loop pcs: bit 31 clear, not the sentinel.
    try testing.expectEqual(tc.AnchorPcKind.loop, tc.anchorKind(0));
    try testing.expectEqual(tc.AnchorPcKind.loop, tc.anchorKind(7));
    try testing.expectEqual(tc.AnchorPcKind.loop, tc.anchorKind((1 << 31) - 1));
    try testing.expectEqual(@as(u32, 7), tc.entryPc(7));
    // Head: the maxInt sentinel — it HAS bit 31 set, so the decoder must
    // classify it head BEFORE the cont bit test.
    try testing.expectEqual(tc.AnchorPcKind.head, tc.anchorKind(tc.FUNC_HEAD_PC));
    try testing.expectEqual(@as(u32, 0), tc.entryPc(tc.FUNC_HEAD_PC));
    // Cont: tagged resume pcs round-trip.
    const tagged = tc.contAnchorPc(42);
    try testing.expectEqual(tc.AnchorPcKind.cont, tc.anchorKind(tagged));
    try testing.expectEqual(@as(u32, 42), tc.entryPc(tagged));
    try testing.expectEqual(tc.AnchorPcKind.cont, tc.anchorKind(tc.contAnchorPc(1)));
    // The largest resume pc the compiler contract permits ((1<<31)-2; -1 would
    // alias FUNC_HEAD_PC and is excluded by the code-length hard-fail).
    const top = tc.contAnchorPc((1 << 31) - 2);
    try testing.expectEqual(tc.AnchorPcKind.cont, tc.anchorKind(top));
    try testing.expectEqual(@as(u32, (1 << 31) - 2), tc.entryPc(top));
    try testing.expect(top != tc.FUNC_HEAD_PC);
}
