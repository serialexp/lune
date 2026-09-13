//! Tests for doc 47 increment A — continuation-scoped link peeling.
//!
//! When a `.continuation` recording reaches an inner `for_prep` and the inner
//! root's entry guards mismatch the current state (e.g. inner root wants float
//! on `sum` but the continuation has int), the recorder peels one inner body
//! iteration to promote types before closing `.link`. These tests pin the peel
//! mechanism and the codex-mandated negative cases.

const std = @import("std");
const trace = @import("trace.zig");
const interp = @import("interp.zig");
const io = @import("io.zig");
const trace_code = @import("trace_code.zig");
const nativegen = @import("nativegen.zig");
const value = @import("value.zig");
const regwindow = @import("regwindow.zig");
const rec_mod = @import("trace_recorder.zig");
const testing = std.testing;
const util = @import("interp_testutil.zig");
const runNativeForTrace = util.runNativeForTrace;
const expectTier0Equiv = util.expectTier0Equiv;
const Vm = interp.Vm;
const Value = value.Value;
const RegWindow = regwindow.RegWindow;

// ---------------------------------------------------------------------------
// Positive: the peel promotes int→float and the linked entry succeeds.
// ---------------------------------------------------------------------------

test "doc 47 inc-A: continuation link-peel promotes int→float accumulator, link chain converges" {
    if (comptime !nativegen.is_x64_linux) return error.SkipZigTest;
    // Minimal sparse-mult shape: outer loop resets `sum = 0` (int), inner loop
    // does `sum = sum + x[i] * v[i]` (float multiply promotes to float). The
    // inner root's entry prologue wants float on `sum`. Without the peel the
    // link handoff has int `sum` → prologue_fail every row; with the peel the
    // continuation records through one inner iteration, `sum` becomes float,
    // and the link succeeds.
    // Short inner loop (~5 elements per row) so the dispatcher seam dominates
    // and the loop-done continuation arms → peel fires on the continuation.
    const source =
        \\local nr, nrow = 5, 1000
        \\local x, v, col, row = {}, {}, {}, {}
        \\for i = 1, nrow * nr do x[i] = i * 0.5; v[i] = i * 0.25 end
        \\row[1] = 1
        \\for r = 1, nrow do
        \\  row[r+1] = row[r] + nr
        \\  for i = 0, nr-1 do col[row[r]+i] = 1+i end
        \\end
        \\local out = {}
        \\local function f(nn, cycles, out_, v_, row_, col_, x_)
        \\  for p = 1, cycles do
        \\    for r = 1, nn do
        \\      local sum = 0
        \\      for i = row_[r], row_[r+1]-1 do sum = sum + x_[col_[i]] * v_[i] end
        \\      out_[r] = sum
        \\    end
        \\  end
        \\end
        \\f(nrow, 40, out, v, row, col, x)
        \\print(out[nrow])
    ;
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var nbuf: [64]u8 = undefined;
    var nsink = io.Writer.fixed(&nbuf);
    var chunk = try runNativeForTrace(&vm, gpa, source, &nsink);
    defer chunk.deinit();

    // The loop-done link fusion counter should be nonzero — the linked burst
    // is running, which means the link entry succeeded (no perpetual
    // prologue_fail).
    try testing.expect(vm.trace.native_loopdone_link_fused > 0);
}

// ---------------------------------------------------------------------------
// Negative: math.type(sum) must print "integer" on iteration 1.
// ---------------------------------------------------------------------------

test "doc 47 inc-A negative: math.type before promotion preserves integer semantics" {
    if (comptime !nativegen.is_x64_linux) return error.SkipZigTest;
    // The peeled inner iteration records with sum's ORIGINAL int type. If the
    // peel incorrectly eagerly converts sum to float, math.type(sum) would
    // return "float" instead of "integer" on the first inner iteration.
    const source =
        \\local results = {}
        \\local x = {}
        \\for i = 1, 50 do x[i] = i * 0.5 end
        \\local function f(n, cycles)
        \\  for p = 1, cycles do
        \\    for r = 1, n do
        \\      local sum = 0
        \\      for i = 1, n do
        \\        if i == 1 then results[r] = math.type(sum) end
        \\        sum = sum + x[i]
        \\      end
        \\    end
        \\  end
        \\end
        \\f(50, 5)
        \\-- Every first-iteration math.type must be "integer"
        \\for i = 1, 50 do
        \\  assert(results[i] == "integer", "row " .. i .. " got " .. tostring(results[i]))
        \\end
        \\print("ok")
    ;
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var nbuf: [64]u8 = undefined;
    var nsink = io.Writer.fixed(&nbuf);
    var chunk = try runNativeForTrace(&vm, gpa, source, &nsink);
    defer chunk.deinit();
    // The script asserts internally; if we get here without error, it passed.
    try testing.expectEqualStrings("ok\n", nsink.buffered());
}

// ---------------------------------------------------------------------------
// Negative: int division before promotion preserves int semantics.
// ---------------------------------------------------------------------------

test "doc 47 inc-A negative: int division before float promotion stays exact" {
    if (comptime !nativegen.is_x64_linux) return error.SkipZigTest;
    // Integer floor-division (`sum // 2`) on the first inner iteration must
    // produce an integer result, not a float. The peel records with the
    // original int type on iteration 1.
    const source =
        \\local x = {}
        \\for i = 1, 50 do x[i] = i * 0.5 end
        \\local results = {}
        \\local function f(n, cycles)
        \\  for p = 1, cycles do
        \\    for r = 1, n do
        \\      local sum = 0
        \\      for i = 1, n do
        \\        local d = sum // 2
        \\        if i == 1 then results[r] = math.type(d) end
        \\        sum = sum + x[i]
        \\      end
        \\    end
        \\  end
        \\end
        \\f(50, 5)
        \\for i = 1, 50 do
        \\  assert(results[i] == "integer", "row " .. i .. " got " .. tostring(results[i]))
        \\end
        \\print("ok")
    ;
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var nbuf: [64]u8 = undefined;
    var nsink = io.Writer.fixed(&nbuf);
    var chunk = try runNativeForTrace(&vm, gpa, source, &nsink);
    defer chunk.deinit();
    try testing.expectEqualStrings("ok\n", nsink.buffered());
}

// ---------------------------------------------------------------------------
// 8-mode byte identity: the peel must produce identical output.
// ---------------------------------------------------------------------------

test "doc 47 inc-A: peeled link trace output is byte-identical across tiers" {
    if (comptime !nativegen.is_x64_linux) return error.SkipZigTest;
    const source =
        \\local n = 100
        \\local x, v = {}, {}
        \\for i = 1, n do x[i] = i * 0.5; v[i] = i * 0.25 end
        \\local out = {}
        \\local function f(nn, cycles)
        \\  for p = 1, cycles do
        \\    for r = 1, nn do
        \\      local sum = 0
        \\      for i = 1, nn do sum = sum + x[i] * v[i] end
        \\      out[r] = sum
        \\    end
        \\  end
        \\end
        \\f(n, 3)
        \\local s = 0
        \\for i = 1, n do s = s + out[i] end
        \\print(string.format("%.15g", s))
    ;
    // Use the standard tier-0 equivalence check.
    try expectTier0Equiv(source);
}

// ---------------------------------------------------------------------------
// Predicate-level tests for the helper functions.
// ---------------------------------------------------------------------------

test "entryGuardsMatch: all matching returns true" {
    const guards = [_]trace_code.EntryGuard{
        .{ .slot = 0, .ty = .int },
        .{ .slot = 1, .ty = .float },
    };
    var tags = [_]u8{ 0, 0 };
    var payloads = [_]u64{ 0, 0 };
    const regs = RegWindow.of(&tags, &payloads);
    regs.set(0, Value.int(42));
    regs.set(1, Value.float(3.14));
    try testing.expect(rec_mod.entryGuardsMatch(&guards, regs));
}

test "entryGuardsMatch: int/float mismatch returns false" {
    const guards = [_]trace_code.EntryGuard{
        .{ .slot = 0, .ty = .float },
    };
    var tags = [_]u8{0};
    var payloads = [_]u64{0};
    const regs = RegWindow.of(&tags, &payloads);
    regs.set(0, Value.int(0));
    try testing.expect(!rec_mod.entryGuardsMatch(&guards, regs));
}

test "entryGuardsMismatchPromotable: float guard on int slot is promotable" {
    const guards = [_]trace_code.EntryGuard{
        .{ .slot = 0, .ty = .int },
        .{ .slot = 1, .ty = .float },
    };
    var tags = [_]u8{ 0, 0 };
    var payloads = [_]u64{ 0, 0 };
    const regs = RegWindow.of(&tags, &payloads);
    regs.set(0, Value.int(1));
    regs.set(1, Value.int(0)); // float guard, int value → promotable
    try testing.expect(rec_mod.entryGuardsMismatchPromotable(&guards, regs));
}

test "entryGuardsMismatchPromotable: table mismatch is not promotable" {
    const guards = [_]trace_code.EntryGuard{
        .{ .slot = 0, .ty = .table },
    };
    var tags = [_]u8{0};
    var payloads = [_]u64{0};
    const regs = RegWindow.of(&tags, &payloads);
    regs.set(0, Value.int(0)); // table guard, int value → not promotable
    try testing.expect(!rec_mod.entryGuardsMismatchPromotable(&guards, regs));
}

test "entryGuardsMismatchPromotable: no mismatch returns false" {
    const guards = [_]trace_code.EntryGuard{
        .{ .slot = 0, .ty = .float },
    };
    var tags = [_]u8{0};
    var payloads = [_]u64{0};
    const regs = RegWindow.of(&tags, &payloads);
    regs.set(0, Value.float(1.0)); // already float → no mismatch
    try testing.expect(!rec_mod.entryGuardsMismatchPromotable(&guards, regs));
}
