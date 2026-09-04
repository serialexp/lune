//! Tests for `interp.zig` — native.
//!
//! Extracted verbatim from `interp.zig`; bodies are unchanged.
//! Shared harness lives in `interp_testutil.zig`.

const interp = @import("interp.zig");
const std = @import("std");
const bytecode = @import("bytecode.zig");
const arith = @import("arith.zig");
const value = @import("value.zig");
const regwindow = @import("regwindow.zig");
const gc = @import("gc.zig");
const object = @import("object.zig");
const string = @import("string.zig");
const table = @import("table.zig");
const array = @import("array.zig");
const function = @import("function.zig");
const trace = @import("trace.zig");
const irinterp = @import("irinterp.zig");
const execlog = @import("execlog.zig");
const compiler = @import("compiler.zig");
const io = @import("io.zig");
const stdmath = @import("stdlib/math.zig");
const stdtable = @import("stdlib/table.zig");
const stdbase = @import("stdlib/base.zig");
const stdbasic = @import("stdlib/basic.zig");
const stdstring = @import("stdlib/string.zig");
const stderrors = @import("stdlib/errors.zig");
const stddebug = @import("stdlib/debug.zig");
const stdload = @import("stdlib/load.zig");
const stdpackage = @import("stdlib/package.zig");
const unicode_case = @import("gen/unicode_case.zig");
const Value = value.Value;
const Proto = bytecode.Proto;
const Instr = bytecode.Instr;
const Closure = function.Closure;
const RegWindow = regwindow.RegWindow;
const testing = std.testing;

const Error = interp.Error;
const Vm = interp.Vm;
const lenOf = interp.lenOf;

const util = @import("interp_testutil.zig");
const TraceMode = util.TraceMode;
const expectProgram = util.expectProgram;
const expectProgramTuned = util.expectProgramTuned;
const expectTier0Equiv = util.expectTier0Equiv;
const runCaptured = util.runCaptured;
const runExecForTrace = util.runExecForTrace;
const runNativeForTrace = util.runNativeForTrace;

// ---------------------------------------------------------------------------
// Tier-1b (native codegen) integration — the compiled trace must be *invisible*:
// identical output to tier-0 / tier-1a, plus the same deopt behaviour. The broad
// `expectProgram` matrix already exercises `.record_execute_native` across every
// program test (silent tier-1a fallback where a trace leaves the int/bool subset);
// these focused tests assert the decisive internal signal — that a supported loop
// was *actually lowered to machine code* (`.compiled`), and an unsupported one is
// terminally `.unsupported`.
// ---------------------------------------------------------------------------

test "native: a hot integer for-loop is lowered to machine code and matches tier-0" {
    if (comptime !@import("nativegen.zig").is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    var chunk = try runNativeForTrace(&vm, gpa,
        \\local acc = 0
        \\for i = 1, 100 do acc = acc + i end
        \\print(acc)
    , &sink);
    defer chunk.deinit();

    // Same result tier-0 produces — and the decisive signal that it ran natively.
    try testing.expectEqualStrings("5050\n", sink.buffered());
    try testing.expectEqual(@as(usize, 1), vm.trace.cache.items.len);
    try testing.expect(vm.trace.cache.items[0].native == .compiled);
}

test "native: a multi-op for-loop with dropped temporaries lowers and matches tier-0 (task A)" {
    if (comptime !@import("nativegen.zig").is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    // The body computes `(i + 7) * (i + 7)` through write-only expression
    // temporaries that the recorder now drops from the exit snapshot. The trace
    // must still lower to machine code, and — the decisive soundness check — its
    // result must be bit-identical to the tier-0 oracle (413950). If dropping a
    // live value were unsound, native and tier-0 would diverge here.
    var chunk = try runNativeForTrace(&vm, gpa,
        \\local acc = 0
        \\for i = 1, 100 do acc = acc + (i + 7) * (i + 7) end
        \\print(acc)
    , &sink);
    defer chunk.deinit();

    try testing.expectEqualStrings("413950\n", sink.buffered());
    try testing.expectEqual(@as(usize, 1), vm.trace.cache.items.len);
    try testing.expect(vm.trace.cache.items[0].native == .compiled);
}

test "native: a float-accumulate loop compiles to the XMM path (Phase D / F1)" {
    if (comptime !@import("nativegen.zig").is_x64_linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    const source =
        \\local acc = 0.0
        \\for i = 1, 100 do acc = acc + 1.5 end
        \\print(acc)
    ;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var nbuf: [64]u8 = undefined;
    var nsink = io.Writer.fixed(&nbuf);
    var chunk = try runNativeForTrace(&vm, gpa, source, &nsink);
    defer chunk.deinit();

    // Phase D: the float add (carried float accumulator + int-controlled for loop)
    // is now inside the native subset — the compiler lowers it to the SSE2/XMM path
    // (cvtsi2sd-free here: both add operands are float) and memoizes `.compiled`.
    try testing.expectEqual(@as(usize, 1), vm.trace.cache.items.len);
    try testing.expect(vm.trace.cache.items[0].native == .compiled);

    // Decisive soundness check: native output is byte-identical to a plain tier-0 run
    // (strict-FP addsd matches the oracle bit-for-bit — 150.0).
    var obuf: [64]u8 = undefined;
    var osink = io.Writer.fixed(&obuf);
    try runCaptured(gpa, source, &osink, false, .off);
    try testing.expectEqualStrings(osink.buffered(), nsink.buffered());
}

test "native: a compiled int loop that flips to float mid-run deopts and matches tier-0" {
    if (comptime !@import("nativegen.zig").is_x64_linux) return error.SkipZigTest;
    // Recorded all-int (the `i == 50` branch isn't taken when it goes hot), so it
    // compiles to native code. At runtime the branch *is* taken: the native trace's
    // `guard_false` on `i == 50` fires, side-exits, and tier-0 turns `acc` into a
    // float — every later re-entry then fails `guard_int` on `acc`. The result must
    // still match tier-0 to the last decimal, proving native deopt is sound.
    const source =
        \\local acc = 0
        \\for i = 1, 100 do
        \\  if i == 50 then acc = acc + 0.5 end
        \\  acc = acc + i
        \\end
        \\print(acc)
    ;
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var nbuf: [64]u8 = undefined;
    var nsink = io.Writer.fixed(&nbuf);
    var chunk = try runNativeForTrace(&vm, gpa, source, &nsink);
    defer chunk.deinit();

    // The pre-flip trace did compile to machine code...
    try testing.expect(vm.trace.cache.items[0].native == .compiled);
    // ...and the native run's output equals a plain tier-0 run, deopt and all.
    var obuf: [64]u8 = undefined;
    var osink = io.Writer.fixed(&obuf);
    try runCaptured(gpa, source, &osink, false, .off);
    try testing.expectEqualStrings(osink.buffered(), nsink.buffered());
}

test "native: int_of_float — a float-limit loop compiles native, then deopts on a non-integral limit, matching tier-0" {
    if (comptime !@import("nativegen.zig").is_x64_linux) return error.SkipZigTest;
    // The numeric-for limit is a FLOAT that is integral (`100.0`), so the recorder
    // emits `int_of_float` to convert it to an exact i64 once (LICM-hoisted into the
    // preheader), making the body compare int-vs-int — the whole reason `proveKinds`
    // accepts the trace and it lowers to machine code. The function is called first
    // with an integral float limit (compiles native + runs it), then with a
    // *non-integral* limit (`100.5`): the native trace's `int_of_float` round-trip
    // check (cvttsd2si;cvtsi2sd;ucomisd;jne/jp) fails and side-exits to tier-0, which
    // runs the loop with the exact mixed int-vs-float compare. The result must equal a
    // plain tier-0 run to the last unit — proving the convert-or-deopt is sound.
    const source =
        \\local function f(m)
        \\  local acc = 0
        \\  for i = 1, m do acc = acc + i end
        \\  return acc
        \\end
        \\local s = 0
        \\for _ = 1, 8 do s = s + f(100.0) end
        \\s = s + f(100.0)
        \\s = s + f(100.5)
        \\print(s)
    ;
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var nbuf: [64]u8 = undefined;
    var nsink = io.Writer.fixed(&nbuf);
    var chunk = try runNativeForTrace(&vm, gpa, source, &nsink);
    defer chunk.deinit();

    // The float-limit loop did lower to machine code (int_of_float made it native-able)...
    try testing.expect(vm.trace.cache.items[0].native == .compiled);
    // ...and the native run (deopt on 100.5 included) is byte-identical to tier-0.
    var obuf: [64]u8 = undefined;
    var osink = io.Writer.fixed(&obuf);
    try runCaptured(gpa, source, &osink, false, .off);
    try testing.expectEqualStrings(osink.buffered(), nsink.buffered());
}

test "int_of_float: float-limit loop is byte-identical across all 8 modes (deopt on non-integral limit)" {
    // Same convert-then-deopt shape, but pinned through the full mode matrix
    // (off / record_only / record_execute_noopt / record_execute / native) × GC
    // stress. record_execute_noopt keeps `int_of_float` in-body (one extra idempotent
    // convert per iteration); record_execute / native hoist it into the preheader —
    // all five must agree to the byte. The non-integral final call exercises the
    // side-exit in every mode that runs the op.
    try expectProgram(
        \\local function f(m)
        \\  local acc = 0
        \\  for i = 1, m do acc = acc + i end
        \\  return acc
        \\end
        \\local s = 0
        \\for _ = 1, 8 do s = s + f(100.0) end
        \\s = s + f(100.5)
        \\print(s)
    , "45450\n");
}

test "native: a bool-lane growth loop compiles native (astore_append) and matches tier-0" {
    if (comptime !@import("nativegen.zig").is_x64_linux) return error.SkipZigTest;
    // `for i=2,N do t[i]=true end` grows the boolean array part. After the first
    // rehash narrows to the bool lane and drains the hash, every iteration is an
    // append (idx == len+1): the recorder emits guard_append + astore_append, and
    // proveKinds accepts the bool-lane grow store so it lowers to machine code (a
    // byte store + an in-place `inc qword [tbl+len]`; the realloc on a cap-doubling
    // boundary is peeled to a guard_append side-exit, never on-trace).
    const source =
        \\local t = {}
        \\for i = 2, 5000 do t[i] = true end
        \\local c = 0
        \\for i = 1, 5000 do if t[i] then c = c + 1 end end
        \\print(c)
    ;
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var nbuf: [64]u8 = undefined;
    var nsink = io.Writer.fixed(&nbuf);
    var chunk = try runNativeForTrace(&vm, gpa, source, &nsink);
    defer chunk.deinit();

    // Some cached trace is the grow loop and carries an astore_append — and that
    // trace lowered to machine code (proveKinds admitted the bool-lane grow store).
    var saw_append = false;
    var compiled_append = false;
    for (vm.trace.cache.items) |tr| {
        for (tr.instrs) |ins| {
            if (ins.op == .astore_append) {
                saw_append = true;
                if (tr.native == .compiled) compiled_append = true;
            }
        }
    }
    try testing.expect(saw_append);
    try testing.expect(compiled_append);
    // The native run (grow loop + read loop) is byte-identical to pure tier-0.
    var obuf: [64]u8 = undefined;
    var osink = io.Writer.fixed(&obuf);
    try runCaptured(gpa, source, &osink, false, .off);
    try testing.expectEqualStrings(osink.buffered(), nsink.buffered());
}

test "astore_append: a bool-lane growth loop is byte-identical across all 8 modes" {
    // The grow store through the full matrix (off / record_only / record_execute_noopt
    // / record_execute / native) × GC stress. The realloc-as-side-exit design is sound
    // only if `len`/`cap`/`data` land identically in tier-0, tier-1a, and native — a
    // divergence (a missed len bump, a wrong byte, a realloc leaking on-trace) prints a
    // different count here. The read loop afterward observes the grown array, so a
    // mis-sized grow would change the printed total.
    try expectProgram(
        \\local t = {}
        \\for i = 2, 5000 do t[i] = true end
        \\local c = 0
        \\for i = 1, 5000 do if t[i] then c = c + 1 end end
        \\print(c)
    , "4999\n");
}

test "eager commit: a dense-from-1 bool fill traces + compiles native (no hole, no rehash detour)" {
    if (comptime !@import("nativegen.zig").is_x64_linux) return error.SkipZigTest;
    // `for i=1,N do t[i]=true end` — the common array-fill idiom, dense from index
    // 1. Without eager lane commitment this stays on the `.value` lane forever (the
    // append fast path keeps the hash empty so Table.rehash never fires) and the
    // recorder aborts on every store. Eager commit narrows to the boolean lane on
    // the FIRST append, so the steady-state append loop records guard_append +
    // astore_append and lowers to native — exactly like the hole-at-1 shape, but
    // for real dense-from-1 code.
    const source =
        \\local t = {}
        \\for i = 1, 5000 do t[i] = true end
        \\local c = 0
        \\for i = 1, 5000 do if t[i] then c = c + 1 end end
        \\print(c)
    ;
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var nbuf: [64]u8 = undefined;
    var nsink = io.Writer.fixed(&nbuf);
    var chunk = try runNativeForTrace(&vm, gpa, source, &nsink);
    defer chunk.deinit();

    var saw_append = false;
    var compiled_append = false;
    for (vm.trace.cache.items) |tr| {
        for (tr.instrs) |ins| {
            if (ins.op == .astore_append) {
                saw_append = true;
                if (tr.native == .compiled) compiled_append = true;
            }
        }
    }
    try testing.expect(saw_append);
    try testing.expect(compiled_append);
    var obuf: [64]u8 = undefined;
    var osink = io.Writer.fixed(&obuf);
    try runCaptured(gpa, source, &osink, false, .off);
    try testing.expectEqualStrings(osink.buffered(), nsink.buffered());
}

test "eager commit: a dense-from-1 bool fill is byte-identical across all 8 modes" {
    // The eager-commit representation change is determinism-adjacent: it changes
    // *when* the lane narrows (append-time vs rehash-time). The lane is never
    // serialized and keyframe restore re-derives it by replaying these same
    // appends, so every mode must evolve it identically. A mis-timed commit, a
    // wrong byte, or an on-trace realloc would change the printed count here.
    try expectProgram(
        \\local t = {}
        \\for i = 1, 5000 do t[i] = true end
        \\local c = 0
        \\for i = 1, 5000 do if t[i] then c = c + 1 end end
        \\print(c)
    , "5000\n");
}

test "astore_append (int lane): a dense-from-1 fill (t[i]=i) compiles native and matches tier-0" {
    if (comptime !@import("nativegen.zig").is_x64_linux) return error.SkipZigTest;
    // `for i=1,N do t[i]=i end` — the int analogue of the bool fill, storing the loop
    // counter. Eager commit narrows to `.i8` on the first append; the value then
    // outgrows the lane (i==128) and `guard_fits` side-exits to tier-0, which WIDENS
    // (i8→i16) and re-enters, so the steady-state append trace records on the i16 lane.
    // The recorder emits guard_append + guard_fits + astore_append and proveKinds now
    // admits the int grow store, so it lowers to a width store + `bts [present]` +
    // `inc [len]` (Phase B). The read loop sums the values, exercising int aload too.
    // (A *constant* fill like `t[i]=7` stays tier-1a today: the optimizer folds the
    // provably-in-range guard_fits, leaving no fits proof — a pre-existing gap shared
    // with the in-bounds int astore, tracked separately. A dynamic value is the case
    // Phase B targets.)
    const source =
        \\local t = {}
        \\for i = 1, 5000 do t[i] = i end
        \\local c = 0
        \\for i = 1, 5000 do c = c + t[i] end
        \\print(c)
    ;
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var nbuf: [64]u8 = undefined;
    var nsink = io.Writer.fixed(&nbuf);
    var chunk = try runNativeForTrace(&vm, gpa, source, &nsink);
    defer chunk.deinit();

    var saw_append = false;
    var compiled_append = false;
    for (vm.trace.cache.items) |tr| {
        for (tr.instrs) |ins| {
            if (ins.op == .astore_append) {
                saw_append = true;
                if (tr.native == .compiled) compiled_append = true;
            }
        }
    }
    try testing.expect(saw_append);
    try testing.expect(compiled_append);
    var obuf: [64]u8 = undefined;
    var osink = io.Writer.fixed(&obuf);
    try runCaptured(gpa, source, &osink, false, .off);
    try testing.expectEqualStrings(osink.buffered(), nsink.buffered());
}

test "widen-eviction: a lane-crossing fill retires the narrow trace and stabilises on the wider one" {
    if (comptime !@import("nativegen.zig").is_x64_linux) return error.SkipZigTest;
    // `for i=1,5000 do t[i]=i end` eager-commits `.u8` (the byte lane — values
    // start in [0,255]), records a u8 append trace, then crosses u8→i16 at i=256
    // (value 256 escapes the byte range). Pre-eviction the dead u8 trace lingered
    // (consuming a per-anchor slot) and the loop ran the i16 tail under a
    // permanently-failing guard. Widen-eviction retires the u8 trace the first time
    // its `guard_lane` fails against the now-wider live array, and reopens the
    // anchor so the *stable* i16 lane records + compiles. We assert the surviving
    // append trace guards i16, NOT u8, proving the dead narrow trace was evicted and
    // the wider one took its place.
    const arr = @import("array.zig");
    const u8_ord = @intFromEnum(arr.Lane.u8);
    const i16_ord = @intFromEnum(arr.Lane.i16);
    const source =
        \\local t = {}
        \\for i = 1, 5000 do t[i] = i end
        \\print(t[5000])
    ;
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var nbuf: [64]u8 = undefined;
    var nsink = io.Writer.fixed(&nbuf);
    var chunk = try runNativeForTrace(&vm, gpa, source, &nsink);
    defer chunk.deinit();

    var saw_i16_append = false;
    var saw_u8_append = false;
    for (vm.trace.cache.items) |tr| {
        for (tr.instrs) |ins| {
            if (ins.op != .astore_append) continue;
            // The append's lane lives in its own `aux`; the leading guard_lane
            // carries the same ordinal. Read the op directly.
            if (ins.aux == i16_ord and tr.native == .compiled) saw_i16_append = true;
            if (ins.aux == u8_ord) saw_u8_append = true;
        }
    }
    try testing.expect(saw_i16_append); // the stable wider lane records + compiles
    try testing.expect(!saw_u8_append); // the dead narrow trace was evicted
    try testing.expectEqualStrings("5000\n", nsink.buffered());
}

test "astore_append (int lane): a widening int fill is byte-identical across all 8 modes" {
    // The full matrix for an int grow store that crosses a lane boundary. The grow
    // store, its guard_fits side-exit, the tier-0 widen, and the separate presence
    // bitmap must all land identically in tier-0, tier-1a, and native — a missed len
    // bump, a wrong width store, or an unset presence bit would change the printed sum.
    try expectProgram(
        \\local t = {}
        \\for i = 1, 5000 do t[i] = i end
        \\local c = 0
        \\for i = 1, 5000 do c = c + t[i] end
        \\print(c)
    , "12502500\n");
}

// ---- doc 18 §T: slot-0 array part, cross-tier ----

test "slot-0: a 0-indexed fill + read loop is byte-identical across all 8 modes" {
    // The headline doc-18 behaviour: `t[0]` is a first-class array key and a
    // 0-based loop appends/reads through the same guarded fast paths as a
    // 1-based one — bounds (idx0 == key, no sub), append (key == asize), and
    // the unsigned admit of key 0 must land identically in tier-0, tier-1a,
    // and native. Boundary probes: key -1 (hash), one past the extent (nil),
    // and `#t` (1-based border, unchanged by t[0]).
    try expectProgram(
        \\local t = {}
        \\for i = 0, 5000 do t[i] = i end
        \\local c = 0
        \\for i = 0, 5000 do c = c + t[i] end
        \\print(c)
        \\print(#t)
        \\print(t[-1] == nil)
        \\print(t[5001] == nil)
        \\t[-1] = 7
        \\print(t[-1])
        \\print(#t)
    ,
        \\12502500
        \\5000
        \\true
        \\true
        \\7
        \\5000
        \\
    );
}

test "slot-0: pairs iterates key 0 first, then the 1-based run (all 8 modes)" {
    // The one signed-off observable change: with key 0 array-resident, `pairs`
    // yields it at the FRONT of the array walk (it used to come from the hash,
    // after the array part).
    try expectProgram(
        \\local t = {}
        \\t[2] = "b"
        \\t[1] = "a"
        \\t[0] = "z"
        \\local out = ""
        \\for k, v in pairs(t) do out = out .. tostring(k) .. "=" .. v .. ";" end
        \\print(out)
    , "0=z;1=a;2=b;\n");
}

test "slot-0: deleting key 0 mid-iteration resumes at key 1 (all 8 modes)" {
    // Lua's `next` contract allows deleting the CURRENT key during traversal;
    // key 0's slot becomes a hole and the walk resumes at 1 without re-yielding
    // or crashing.
    try expectProgram(
        \\local t = {}
        \\t[0] = 10
        \\t[1] = 20
        \\local k1 = next(t)
        \\t[k1] = nil
        \\local k2 = next(t, k1)
        \\print(k1)
        \\print(k2)
        \\print(t[0] == nil)
    , "0\n1\ntrue\n");
}

test "slot-0: next() folds a float-spelled integer control key (all 8 modes)" {
    // Table keys identity-normalize (`0.0`, `-0.0`, and `0` are one key), so
    // `next`'s control argument must fold the same way before classification —
    // a float-spelled array-resident control used to fall into the hash arm
    // and yield nothing (codex post-landing review, blocker 2).
    try expectProgram(
        \\local t = {}
        \\t[0] = "z"
        \\t[1] = "one"
        \\local a = next(t, 0.0)
        \\local b = next(t, -0.0)
        \\local c = next(t, 0)
        \\print(a == 1 and b == 1 and c == 1)
    , "true\n");
}

test "slot-0: fresh seeds at key 0 and key 1 read back exactly (all 8 modes)" {
    // D2a's two seed shapes: `t[0] = v` (asize 1, no hole) and `t[1] = v`
    // (asize 2, slot-0 hole). Back-filling the hole is an in-place store.
    try expectProgram(
        \\local a = {}
        \\a[1] = 15
        \\a[0] = 5
        \\local b = {}
        \\b[0] = true
        \\print(a[0] + a[1])
        \\print(b[0])
        \\print(#a)
        \\print(#b)
    , "20\ntrue\n1\n0\n");
}

test "slot-0: grid-shaped matrix — bare key-0 access deflates and proceeds (all 8 modes)" {
    // D6's key-0 policy, script-observable half: a bare `m[0]` read/write on a
    // (possibly grid-flattened) matrix deflates first and then behaves like any
    // nested table whose outer part covers key 0. Row values, `#m`, and the
    // key-0 slot must agree across every tier and GC mode.
    try expectProgram(
        \\local m = {}
        \\for i = 1, 3 do
        \\  m[i] = {}
        \\  for j = 1, 3 do m[i][j] = i * 10 + j end
        \\end
        \\local s = 0
        \\for i = 1, 3 do for j = 1, 3 do s = s + m[i][j] end end
        \\print(s)
        \\print(m[0] == nil)
        \\m[0] = 99
        \\print(m[0])
        \\print(m[1][1])
        \\print(#m)
    , "198\ntrue\n99\n11\n3\n");
}

test "executor: integer //-by-zero inside a hot loop side-exits; tier-0 re-raises identically" {
    const source =
        \\local x = 0
        \\for i = 1, 100 do x = x + (100 // (50 - i)) end
        \\print(x)
    ;
    // The divisor `50 - i` is 0 at i == 50 — long after the loop has gone hot and
    // is running through the executor. `arith.floorDiv` returns `DivisionByZero`,
    // the executor side-exits, and tier-0 re-runs the partial iteration and raises
    // the *same* error. Tier-0 (execute off) raises it identically — same error,
    // same place — which is the whole point of re-running rather than reconstructing.
    inline for (.{ TraceMode.off, TraceMode.record_execute }) |mode| {
        const gpa = testing.allocator;
        const parser = @import("parser.zig");
        const diag = @import("diag.zig");
        var diags = diag.Diagnostics.init(gpa);
        defer diags.deinit();
        var tree = try parser.parse(gpa, source, &diags);
        defer tree.deinit();
        var buf: [64]u8 = undefined;
        var sink = io.Writer.fixed(&buf);
        var vm = try Vm.init(gpa);
        defer vm.deinit();
        vm.out = &sink;
        vm.trace.config.enabled = mode != .off;
        vm.trace.config.execute = mode == .record_execute;
        vm.trace.config.hotloop = 4;
        var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
        defer chunk.deinit();
        try testing.expect(!diags.hasErrors());
        try testing.expectError(Error.DivisionByZero, vm.run(chunk.proto));
    }
}

test "executor: a variable that flips int->float mid-loop deopts to tier-0 and still matches tier-0" {
    // Recorded as an integer loop (the `i == 20` branch is not taken when it goes
    // hot). At i == 20 tier-0 takes the branch and `x` becomes a float; every later
    // back-edge is a fingerprint mismatch — the trace is skipped, tier-0 runs the
    // tail directly. No failed entries, no blacklisting. The result must still
    // equal tier-0's to the last decimal.
    const source =
        \\local x = 0
        \\for i = 1, 200 do
        \\  if i == 20 then x = x + 0.5 end
        \\  x = x + 1
        \\end
        \\print(x)
    ;
    try expectTier0Equiv(source);

    // Introspect: the type flip causes fingerprint mismatches, not blacklisting.
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    var chunk = try runExecForTrace(&vm, gpa, source, &sink);
    defer chunk.deinit();
    // The anchor is NOT blacklisted — fingerprinting skips the trace after the
    // type change instead of trial-entering and failing.
    try testing.expectEqual(@as(usize, 0), vm.trace.gate.count());
}

test "executor: a branchy low-yield loop stays UNGATED under clear-on-productive yet prints correctly" {
    // Doc 31 D2 inverts this test's original expectation, deliberately. The trace
    // records one parity of `if i % 2 == 0`; the opposite parity fails its branch
    // guard after ~1 committed iteration *every* entry. Under the old
    // `completed >= min_useful` clear this ratcheted the penalty and blacklisted
    // the anchor; under clear-on-productive every `completed=1` receipt resets the
    // strike, so the anchor NEVER gates — the "accepted give" of doc 31 §4 (the
    // same rule that fixes the str_gmatch ratchet, where fixed-length productive
    // instances below min_useful were being gated into 3% native residency).
    // Escalation path, if a bench ever demonstrates this shape's cost: a
    // deterministic saturating work-credit score — not a return to the ratchet.
    // Output stays exact (100 evens × 1 + 100 odds × 2 == 300).
    const source =
        \\local s = 0
        \\for i = 1, 200 do
        \\  if i % 2 == 0 then s = s + 1 else s = s + 2 end
        \\end
        \\print(s)
    ;
    try expectTier0Equiv(source);

    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    var chunk = try runExecForTrace(&vm, gpa, source, &sink);
    defer chunk.deinit();
    try testing.expectEqualStrings("300\n", sink.buffered());
    // Pin the new steady state: no gate, no residual penalty, and dispatch keeps
    // re-entering the cached trace once per even iteration (~98 entries at
    // n=200 after warmup) instead of being ratcheted out.
    try testing.expectEqual(@as(usize, 0), vm.trace.gate.count());
    try testing.expectEqual(@as(usize, 0), vm.trace.penalty.count());
    try testing.expect(vm.trace.entries > 80);
}

test "executor: a thrashing anchor that later stabilizes recovers from the gate" {
    // The gate is not a death sentence — an anchor that thrashes transiently must
    // come back. The branch `i % 100 < 90` is a SINGLE guard that oscillates in
    // phases: 90 iterations true (the trace, recorded on the true arm at i=5, runs
    // one long useful entry) then 10 iterations false (the trace is entered and the
    // guard fails immediately → < min_useful → the penalty climbs and, at
    // max_penalty, gates the anchor with backoff). Crucially the next true-phase
    // re-enters the SAME cached trace on the SAME guard and commits a long useful
    // run, which CLEARS the gate. The loop ends deep in a true-phase (i=389,
    // i%100=89) well past the last gate's cooldown, so recovery has completed and
    // the gate is empty. A permanent blacklist would have abandoned the anchor on
    // the first low-yield burst and left it gated forever.
    const gpa = testing.allocator;
    const source =
        \\local s = 0
        \\for i = 1, 389 do
        \\  if i % 100 < 90 then s = s + 1 else s = s + 2 end
        \\end
        \\print(s)
    ;
    try expectTier0Equiv(source);

    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();
    try testing.expect(!diags.hasErrors());

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    vm.trace.config.enabled = true;
    vm.trace.config.execute = true;
    vm.trace.config.hotloop = 4;
    vm.trace.config.max_penalty = 8; // gate after 8 low-yield entries
    vm.trace.config.backoff_base = 16; // short cooldown so recovery fits in 400 iters

    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;
    var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    _ = try vm.run(chunk.proto);

    // `else` (s+2) taken when i%100 ∈ {90..99}: i ∈ {90..99,190..199,290..299} = 30.
    // `then` (s+1) the other 359. s = 359×1 + 30×2 = 419.
    try testing.expectEqualStrings("419\n", sink.buffered());
    // Recovered: the long stable tail committed a useful entry which removed the
    // gate. If recovery were broken (permanent abandonment) the gate would persist.
    try testing.expectEqual(@as(usize, 0), vm.trace.gate.count());
}

/// Post-run oracle for the A-vii-c matrix: the EXERCISED form the A-vii-c review
/// asked for. Every execute leg must prove the flipped gate really ran — a live
/// armable region, physical members indexed against it, and at least one
/// authoritative window flush — so a discovery/armability regression cannot
/// quietly degrade this into an ordinary output test.
///
/// History (kept because the sequence is the load-bearing insight): the A-vii-c
/// landing found this shape's cycle minted with `armable = false` and asserted
/// that dormancy as a tripwire. A-vii-d.0 then established WHY: a cycle is
/// necessarily minted before its external-entry side trace records (the internal
/// cycle triggers minting; the entry is a guard-hot side trace recorded later),
/// so first sight is always owner-not-unique — and armability was frozen
/// monotone-decreasing at first sight, making it unreachable for every recorded
/// shape (measured on nsieve: `both_count` evolves 0→0→1 across rebuilds while
/// the frozen bit stayed false). Discovery now recomputes armability on every
/// rebind (only `tombstoned` is sticky), the tripwire fired exactly as designed,
/// and this is its mandated upgrade.
fn assertRegionGateExercised(vm: *Vm, mode: TraceMode) anyerror!void {
    // Only the executing legs can form the region at all: the cross-anchor cycle
    // closes through SIDE traces, and side-trace recording is driven by guard
    // failures during trace EXECUTION. With `.off` there is no recorder, and with
    // `.record_only` the roots are recorded but never entered, so no guard fails
    // and discovery sees no cycle (measured: `region_defs.count() == 0`). Those
    // legs still carry the output oracle.
    if (mode == .off or mode == .record_only) return;

    try testing.expect(vm.trace.region_defs.count() >= 1);

    var armable: usize = 0;
    var defs = vm.trace.region_defs.valueIterator();
    while (defs.next()) |def| {
        if (def.armable) armable += 1;
    }
    var live_members: usize = 0;
    var members = vm.trace.dest_entry_regions.iterator();
    while (members.next()) |entry| {
        for (entry.value_ptr.*) |id| {
            const def = vm.trace.region_defs.get(id) orelse continue;
            if (def.armable) {
                live_members += 1;
                break;
            }
        }
    }
    try testing.expect(armable >= 1);
    try testing.expect(live_members >= 1);
    try testing.expect(vm.trace.region_profit_flushes >= 1);
}

test "A-vii-c: a region-forming sieve shape stays byte-identical across all 10 modes" {
    // The gate-consumption flip (doc 17 §A8-iii, A-vii.1) is the FIRST
    // selection-diverging change: region-member traces' penalty/gate now comes
    // from region window flushes keyed on the OWNER anchor, so trace selection
    // for genuine cross-anchor cycles may differ from the pre-flip machine. The
    // contract is output identity, not selection identity (P-EBP-1) — so pin the
    // 10-mode matrix on a program SHAPED to mint a cross-trace-cycle region
    // (branchy outer scan whose taken arm runs an inner numeric-for: the
    // skip/ramp/inner/cont shape; a `while` inner does NOT close the cycle).
    // π(80) = 22 primes.
    //
    // A-vii-d.0: every execute leg additionally proves it really exercised the
    // flipped gate (`assertRegionGateExercised`) — live armable region, indexed
    // members, at least one authoritative window flush — so a discovery or
    // armability regression cannot quietly turn this into an ordinary output
    // test. `hotguard = 3` records side traces early enough for the cross-anchor
    // cycle to close inside the matrix's short loops.
    try expectProgramTuned(
        \\local count = 0
        \\local flags = {}
        \\for j = 1, 5 do
        \\  count = 0
        \\  for i = 2, 80 do flags[i] = true end
        \\  for i = 2, 80 do
        \\    if flags[i] then
        \\      count = count + 1
        \\      for k = i + i, 80, i do flags[k] = false end
        \\    end
        \\  end
        \\end
        \\print(count)
    , "22\n", .{ .hotguard = 3, .inspect = &assertRegionGateExercised });
}

test "e2e (executor): a long hot loop stays correct across every trace + gc mode" {
    // Long enough to record, execute, side-exit at the loop close, and clear its
    // penalty — run under gc_stress too (record_execute × stress is in the matrix).
    try expectProgram(
        \\local acc = 0
        \\for i = 1, 64 do acc = acc + i end
        \\print(acc)
    , "2080\n"); // sum 1..64 == 2080
}

test "tropt: every loop-carried variable survives DCE (exit-store observability)" {
    // Three chained loop-carried variables, all read after the loop. The optimizer
    // must root *every* exit_store during dead-code elimination — drop any one and
    // tier-0 would resume with a stale register and the printed value would differ.
    // The 8-way matrix proves opt == noopt == tier-0 for all three.
    try expectProgram(
        \\local a = 0
        \\local b = 1
        \\local c = 2
        \\for i = 1, 50 do
        \\  a = a + i
        \\  b = b + a
        \\  c = c + b
        \\end
        \\print(a)
        \\print(b)
        \\print(c)
    , "1275\n22101\n292877\n");
}

test "tropt: seeded differential fuzz — tier-0 == execute-noopt == execute-opt" {
    // A fixed-seed PRNG generates small all-integer arithmetic loops. For each, the
    // three modes (tier-0, record+execute unoptimized, record+execute optimized)
    // must print byte-identically — the optimizer is output-invariant. Operands are
    // kept non-zero (b ∈ [1,9], the loop index i ∈ [1,k]) so `//`/`%` never divide
    // by zero; everything stays int so there are no type errors, only wrapping.
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xA11CE);
    const rnd = prng.random();
    const ops = [_][]const u8{ "+", "-", "*", "//", "%", "&", "|" };

    var iter: usize = 0;
    while (iter < 64) : (iter += 1) {
        const a0 = rnd.intRangeAtMost(i64, -20, 20);
        const b0 = rnd.intRangeAtMost(i64, 1, 9); // non-zero divisor
        const k = rnd.intRangeAtMost(i64, 5, 40);
        const op1 = ops[rnd.uintLessThan(usize, ops.len)];
        const op2 = ops[rnd.uintLessThan(usize, ops.len)];

        var src_buf: [256]u8 = undefined;
        const source = try std.fmt.bufPrintSentinel(&src_buf,
            \\local a = {d}
            \\local b = {d}
            \\for i = 1, {d} do a = (a {s} b) {s} i end
            \\print(a)
        , .{ a0, b0, k, op1, op2 }, 0);

        var b_off: [64]u8 = undefined;
        var s_off = io.Writer.fixed(&b_off);
        try runCaptured(gpa, source, &s_off, false, .off);
        var b_no: [64]u8 = undefined;
        var s_no = io.Writer.fixed(&b_no);
        try runCaptured(gpa, source, &s_no, false, .record_execute_noopt);
        var b_op: [64]u8 = undefined;
        var s_op = io.Writer.fixed(&b_op);
        try runCaptured(gpa, source, &s_op, false, .record_execute);

        try testing.expectEqualStrings(s_off.buffered(), s_no.buffered());
        try testing.expectEqualStrings(s_off.buffered(), s_op.buffered());
    }
}

// --- the grid gate: bare index access deflates (Phase 4c, doc 14) ------------
//
// Row forwarding through a live `row_view` (Phase 3) is exercised directly in
// table.zig ("grid row_view: get/set forward …"). At the *interpreter* boundary
// the escape model forbids ever handing a bare `row_view` to user code: any
// ordinary `indexGet`/`indexSet` on a grid table deflates it back to real row
// Tables first, so no stale-alias hazard can arise. These tests pin that gate.

test "grid gate: a bare indexGet on a grid deflates it and returns a real row table" {
    const arr = @import("array.zig");
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();

    // Hand-built grid, off the GC list (plain create/destroy). deflateGrid mints
    // the row Tables via the heap, so those land on the GC list and free at deinit.
    const t = try table.Table.create(gpa);
    defer t.destroy(gpa);
    t.array = try arr.ArrayPart.initGrid(gpa, 2, 3, .i32); // 2 rows × 3 i32 cells
    t.array.gridSet(0, 0, Value.int(10));
    t.array.gridSet(0, 1, Value.int(20));
    t.array.gridSet(1, 0, Value.int(70));
    const g = Value.heap(&t.header);

    // A bare outer `g[1]` deflates the grid and yields a *real* heap Table — never
    // a row_view. The parent is now nested and flagged so it won't re-inflate.
    const r1 = try vm.indexGet(g, Value.int(1));
    try testing.expect(!r1.isRowView());
    try testing.expect(r1.isHeap() and r1.heapType() == .table);
    try testing.expect(!t.array.isGrid());
    try testing.expect(t.no_grid);

    // The rebuilt row reproduces the cells (cols 0,1 set ⇒ keys 1,2; col 2 a hole).
    try testing.expectEqual(@as(i64, 10), (try vm.indexGet(r1, Value.int(1))).asInt());
    try testing.expectEqual(@as(i64, 20), (try vm.indexGet(r1, Value.int(2))).asInt());
    try testing.expect((try vm.indexGet(r1, Value.int(3))).isNil());
    try testing.expectEqual(@as(i64, 2), (try lenOf(r1)).asInt());

    // `#g` is still the row count; the second row is an independent table.
    try testing.expectEqual(@as(i64, 2), (try lenOf(g)).asInt());
    const r2 = try vm.indexGet(g, Value.int(2));
    try testing.expect(r2.isHeap() and r2.heapType() == .table);
    try testing.expect(!r1.eql(r2));
    try testing.expectEqual(@as(i64, 70), (try vm.indexGet(r2, Value.int(1))).asInt());
}

test "grid gate: a bare indexSet on a grid deflates it, then stores the whole row" {
    const arr = @import("array.zig");
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();

    const t = try table.Table.create(gpa);
    defer t.destroy(gpa);
    t.array = try arr.ArrayPart.initGrid(gpa, 2, 3, .i32);
    t.array.gridSet(0, 0, Value.int(10));
    t.array.gridSet(1, 0, Value.int(70));
    const g = Value.heap(&t.header);

    // A bare outer store replaces the whole slot — that is only meaningful on a
    // nested table, so the grid deflates first, then the store lands as a scalar.
    try vm.indexSet(g, Value.int(1), Value.int(9));
    try testing.expect(!t.array.isGrid());
    try testing.expect(t.no_grid);
    try testing.expectEqual(@as(i64, 9), (try vm.indexGet(g, Value.int(1))).asInt());

    // Row 2 survived the deflation as a real row table.
    const r2 = try vm.indexGet(g, Value.int(2));
    try testing.expectEqual(@as(i64, 70), (try vm.indexGet(r2, Value.int(1))).asInt());
}

// --- Phase 4b: inflation + reshape through the fused store path (doc 14) ------

test "fused store: a homogeneous-numeric matrix inflates, reshapes, then deflates on type change" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();

    // Build nested `{ {1,2}, {3,4} }` on the heap (everything GC-linked; freed at
    // deinit whether or not it's rooted, so no globals dance is needed).
    const a = try vm.heap.newTable();
    const r0 = try vm.heap.newTable();
    const r1 = try vm.heap.newTable();
    try r0.set(gpa, Value.int(1), Value.int(1));
    try r0.set(gpa, Value.int(2), Value.int(2));
    try r1.set(gpa, Value.int(1), Value.int(3));
    try r1.set(gpa, Value.int(2), Value.int(4));
    try a.set(gpa, Value.int(1), Value.heap(&r0.header));
    try a.set(gpa, Value.int(2), Value.heap(&r1.header));
    const av = Value.heap(&a.header);

    // First fused store inflates `a` into a grid and writes the cell in-grid.
    try vm.fusedStore(av, Value.int(1), Value.int(1), Value.int(9));
    try testing.expect(a.array.isGrid());
    try testing.expectEqual(@as(i64, 9), (try vm.fusedGet(av, Value.int(1), Value.int(1))).asInt());
    try testing.expectEqual(@as(i64, 4), (try vm.fusedGet(av, Value.int(2), Value.int(2))).asInt());

    // Reshape on stride overflow: column 3 outruns the stride-2 grid → geometric
    // grow (stays a grid, never deflates — Bart's reshape-on-overflow rule).
    try vm.fusedStore(av, Value.int(1), Value.int(3), Value.int(7));
    try testing.expect(a.array.isGrid());
    try testing.expect(a.array.stride >= 3);
    try testing.expectEqual(@as(i64, 7), (try vm.fusedGet(av, Value.int(1), Value.int(3))).asInt());

    // Lane widen: a value past the current int lane climbs the cell-lane ladder
    // in place, still a grid.
    try vm.fusedStore(av, Value.int(2), Value.int(1), Value.int(100000));
    try testing.expect(a.array.isGrid());
    try testing.expectEqual(@as(i64, 100000), (try vm.fusedGet(av, Value.int(2), Value.int(1))).asInt());

    // Type change (float into an int grid) is the one trigger that deflates; the
    // store still lands, now nested, and the earlier cells survive intact.
    try vm.fusedStore(av, Value.int(1), Value.int(1), Value.float(1.5));
    try testing.expect(!a.array.isGrid());
    try testing.expect(a.no_grid);
    try testing.expectEqual(@as(f64, 1.5), (try vm.fusedGet(av, Value.int(1), Value.int(1))).asFloat());
    try testing.expectEqual(@as(i64, 7), (try vm.fusedGet(av, Value.int(1), Value.int(3))).asInt());
    try testing.expectEqual(@as(i64, 100000), (try vm.fusedGet(av, Value.int(2), Value.int(1))).asInt());

    // Hysteresis: a deflated matrix does not re-inflate on the next fused store.
    try vm.fusedStore(av, Value.int(2), Value.int(2), Value.int(8));
    try testing.expect(!a.array.isGrid());
    try testing.expectEqual(@as(i64, 8), (try vm.fusedGet(av, Value.int(2), Value.int(2))).asInt());
}

// --- Phase 4a: fused two-level index (get_index2 / set_index2) ---------------

test "fused index: chained get/set on nested tables is byte-identical across 8 modes" {
    try expectProgram(
        \\local a = { {10,20,30}, {40,50,60} }
        \\a[1][2] = 99
        \\print(a[1][2], a[2][3], a[1][1])
        \\local b = { { {7,8} } }
        \\b[1][1][2] = 88
        \\print(b[1][1][2], b[1][1][1])
        \\
    ,
        "99\t60\t10\n88\t7\n",
    );
}

test "fused index: __index / __newindex on the inner level still dispatch" {
    try expectProgram(
        \\local proto = { z = 42 }
        \\local row = setmetatable({}, { __index = proto })
        \\local outer = { row }
        \\print(outer[1]["z"])
        \\local log = {}
        \\local mrow = setmetatable({}, { __newindex = function(t,k,v) log[k]=v end })
        \\local o2 = { mrow }
        \\o2[1]["hit"] = 7
        \\print(log["hit"], rawget(mrow, "hit"))
        \\
    ,
        "42\n7\tnil\n",
    );
}

test "fused index: evaluation order matches the unfused RHS-first convention" {
    // Single-level store is RHS-first (`g[k(1)]=k(2)` ⇒ 2 then 1); the fused
    // two-level store must keep the same order: value, then the two keys L→R.
    try expectProgram(
        \\local order = {}
        \\local function k(n) order[#order+1] = n; return n end
        \\local g = { {0,0,0} }
        \\g[k(1)][k(2)] = k(3)
        \\print(order[1], order[2], order[3])
        \\local rd = {}
        \\local function r(n) rd[#rd+1] = n; return n end
        \\local a = { {5} }
        \\local _ = a[r(1)][r(2)]
        \\print(rd[1], rd[2])
        \\
    ,
        "3\t1\t2\n1\t2\n",
    );
}

// --- Phase 4b/4c: grids end-to-end from Lua (8-mode byte-identical) -----------
// A grid is logically transparent: every program below must print exactly what
// the equivalent nested-table program would, in all 8 execution modes. That the
// matrix flattens (or reshapes, or deflates) underneath is invisible to the user.

test "grid e2e: fill a matrix with fused stores then read it back" {
    try expectProgram(
        \\local m = { {1,2,3}, {4,5,6}, {7,8,9} }
        \\for i=1,3 do for j=1,3 do m[i][j] = m[i][j] * 10 end end
        \\local s = 0
        \\for i=1,3 do for j=1,3 do s = s + m[i][j] end end
        \\print(s, m[1][1], m[3][3])
        \\
    ,
        "450\t10\t90\n",
    );
}

test "grid e2e: an f64 cell grid fills, accumulates, and reads back (native XMM cells)" {
    // The float twin of the fill test, sized to tier up so the f64 grid cell path
    // (gload/gstore via `movsd`, doc 14 Phase 8 Stage C) runs natively under
    // `record_execute_native` — byte-identical to tier-0 across all 8 modes. The
    // rows start as dense f64 arrays (`0.0`) so inflation unifies the cell lane to
    // f64; the hot inner loop both reads and writes f64 cells.
    try expectProgram(
        \\local m = {}
        \\for i=1,8 do local r={} for j=1,8 do r[j]=0.0 end m[i]=r end
        \\for i=1,8 do for j=1,8 do m[i][j] = i*0.5 + j*0.25 end end  -- inflate → f64 grid
        \\local s = 0.0
        \\for rep=1,40 do
        \\  for i=1,8 do for j=1,8 do s = s + m[i][j] * 2.0 end end
        \\end
        \\for i=1,8 do m[i][i] = s end                                -- f64 cell stores
        \\print(string.format("%.2f %.2f %.2f", s, m[1][1], m[8][8]))
        \\
    ,
        "17280.00 17280.00 17280.00\n",
    );
}

test "grid e2e: a fused store past the stride grows the grid (reshape-on-overflow)" {
    try expectProgram(
        \\local m = { {1,2}, {3,4} }
        \\m[1][1] = 9          -- inflate
        \\m[1][3] = 7          -- column 3 outruns stride 2 → grow, stay flat
        \\m[2][4] = 8          -- column 4 fits the grown stride; still flat
        \\print(m[1][1], m[1][2], m[1][3], m[2][4], m[1][4])
        \\
    ,
        "9\t2\t7\t8\tnil\n",
    );
}

test "grid e2e: a wider int store climbs the cell lane in place" {
    try expectProgram(
        \\local m = { {1,2}, {3,4} }
        \\m[1][1] = 1          -- inflate at a tiny lane
        \\m[2][2] = 1000000    -- past the lane → widen, stay flat
        \\print(m[2][2], m[1][1], m[2][1])
        \\
    ,
        "1000000\t1\t3\n",
    );
}

test "grid e2e: a float into an int grid deflates, and the value still lands" {
    try expectProgram(
        \\local m = { {1,2}, {3,4} }
        \\m[1][1] = 9          -- inflate (int grid)
        \\m[2][2] = 1.5        -- type change → deflate, store nested
        \\print(m[1][1], m[2][2], m[1][2], m[2][1])
        \\
    ,
        "9\t1.5\t2\t3\n",
    );
}

test "grid e2e: bare row access deflates yet stays correct (pairs, escape, equality)" {
    try expectProgram(
        \\local m = { {10,20}, {30,40} }
        \\m[1][1] = 11                 -- inflate
        \\local row = m[1]             -- bare access ⇒ deflate; row is a real table
        \\row[2] = 22                  -- mutating the escaped row is visible in m
        \\local sum = 0
        \\for _,v in ipairs(m[1]) do sum = sum + v end
        \\print(m[1][1], m[1][2], sum, m[1] == m[1], m[2][2])
        \\
    ,
        "11\t22\t33\ttrue\t40\n",
    );
}

test "grid e2e: table.insert on the matrix deflates and appends a whole row" {
    try expectProgram(
        \\local m = { {1,2}, {3,4} }
        \\m[1][1] = 9                  -- inflate
        \\table.insert(m, {5,6})       -- bare op on the matrix ⇒ deflate
        \\print(#m, m[3][1], m[3][2], m[1][1])
        \\
    ,
        "3\t5\t6\t9\n",
    );
}

test "grid e2e: an in-place row swap (the motivating counterexample) stays correct" {
    // `tmp = a[i]` is a bare access ⇒ the grid deflates and `tmp` is a real row
    // table, so the stale-alias hazard the gate was designed to avoid cannot arise.
    try expectProgram(
        \\local a = { {1,2,3}, {4,5,6} }
        \\a[1][1] = 10                 -- inflate
        \\local tmp = a[1]             -- bare access ⇒ deflate; tmp aliases the real row
        \\a[1] = a[2]
        \\a[2] = tmp
        \\print(a[1][1], a[1][3], a[2][1], a[2][3])
        \\
    ,
        "4\t6\t10\t3\n",
    );
}

test "grid e2e: table.sort over rows by a key deflates and orders correctly" {
    try expectProgram(
        \\local a = { {3,30}, {1,10}, {2,20} }
        \\a[1][1] = 3                  -- inflate (no-op value, just to flatten)
        \\table.sort(a, function(x,y) return x[1] < y[1] end)
        \\print(a[1][1], a[2][1], a[3][1], a[1][2], a[3][2])
        \\
    ,
        "1\t2\t3\t10\t30\n",
    );
}

// ---------------------------------------------------------------------------
// Doc 22 §B.6 (Phase B-v): the seeded-seam e2e battery — structural upvalue-
// seed chaining, the ten-leg upvalue-builtin nest, and hash-drift decline
// determinism. Output identity alone cannot prove these paths fired, so the
// native leg additionally asserts the B-iv/B-v internal witnesses.
// ---------------------------------------------------------------------------

fn assertSeededChainExercised(vm: *Vm, mode: TraceMode) anyerror!void {
    // Only the native leg compiles pages; the other legs carry the oracle.
    if (mode != .record_execute_native) return;

    // The inner loop's trace carries the upvalue seed (`A` reached through
    // `get_upval`) and must have compiled as a SEEDED page — the §B.4
    // "seeds_at_entry" invariant: plan non-empty ⇔ prologue present.
    var seeded_compiled: usize = 0;
    for (vm.trace.cache.items) |t| {
        if (t.inputs.len == 0) continue;
        if (t.native != .compiled) continue;
        const c = &t.native.compiled;
        try testing.expectEqual(c.seed_plan.nonEmpty(), c.seed_prologue);
        if (!c.seed_plan.nonEmpty()) continue;
        var has_upvalue = false;
        for (t.inputs) |seed| {
            if (seed.kind == .upvalue) has_upvalue = true;
        }
        try testing.expect(has_upvalue);
        seeded_compiled += 1;
    }
    try testing.expect(seeded_compiled >= 1);

    // The chain seams armed AROUND the seeded page (B-iv.3: seeded traces are
    // admitted at `findLinkTrace`/`armNativeLink`/loop-done selection), and
    // native entry really happened.
    try testing.expect(vm.trace.native_entries >= 1);
    const arms = vm.trace.native_link_arms + vm.trace.native_loopdone_link_arms +
        vm.trace.native_source_link_arms + vm.trace.sibling_handoff_arms;
    try testing.expect(arms >= 1);
    // Upvalue seeds have no hash cell to drift — nothing may have declined.
    try testing.expectEqual(@as(u64, 0), vm.trace.seed_hash_declines);
    try testing.expectEqual(@as(u64, 0), vm.trace.seed_capacity_declines);
}

test "B-v (doc 22 §B.6): structural — an upvalue-seeded inner loop chains through its .link continuation (all legs byte-identical)" {
    // The §B.6 structural row: `run`'s inner numeric-for calls `A` through an
    // upvalue, so its trace records exactly the upvalue InputSeed shape
    // (interp_trace_test "callee reached through an upvalue"); the outer
    // back-edge (`acc = acc + 1`) is its `.link` continuation. Before B-iv the
    // chain seams skipped every seeded trace; the inspect hook pins that the
    // seeded page compiles WITH its prologue (§B.4), enters natively, and the
    // link/loop-done arms actually fire around it.
    try expectProgramTuned(
        \\local function A(i, j) return i * 3 + j end
        \\local function run()
        \\  local acc = 0
        \\  for j = 1, 8 do
        \\    for i = 1, 40 do acc = acc + A(i, j) end
        \\    acc = acc + 1
        \\  end
        \\  return acc
        \\end
        \\print(run())
    , "21128\n", .{ .hotguard = 3, .inspect = &assertSeededChainExercised });
}

test "B-v (doc 22 §B.6): e2e ten-leg — a nest whose inner loop calls an upvalue builtin stays byte-identical with chaining live" {
    // The §B.6 e2e row: the `local sqrt = math.sqrt` shape from the doc —
    // an upvalue BUILTIN in the hot inner loop of a nest, across the full
    // stress × mode matrix. Output identity is the whole contract here (the
    // structural test above owns the internal witnesses).
    try expectProgramTuned(
        \\local sqrt = math.sqrt
        \\local function run()
        \\  local acc = 0
        \\  for j = 1, 6 do
        \\    for i = 1, 40 do acc = acc + sqrt(i * i) end
        \\    acc = acc + 1
        \\  end
        \\  return acc
        \\end
        \\print(run())
    , "4926\n", .{ .hotguard = 3 });
}

fn assertHashDriftDeclined(vm: *Vm, mode: TraceMode) anyerror!void {
    // Only the native leg has a seed prologue to decline; the tier-1a legs
    // take the pre-B-ii `native_eligible = false` downgrade instead.
    if (mode != .record_execute_native) return;
    // Round 2 re-enters the round-1 page after `t.w = 5` drifted the hash
    // count (1 → 2), so the entry seed validation MUST have declined at least
    // once — the B-v diagnostic is the only witness (output stays identical
    // by construction, the H1 tier-1a rerun).
    try testing.expect(vm.trace.seed_hash_declines >= 1);
    try testing.expectEqual(@as(u64, 0), vm.trace.seed_capacity_declines);
}

test "B-v (doc 22 §B.6): decline determinism — a hash-cell seed invalidated between activations declines and stays byte-identical" {
    // The §B.6 decline-determinism row, e2e half (the ledger-grammar halves
    // are unit-pinned in trace_replay_test): round 1 compiles the inner loop
    // with a hash_cell seed (`t.v`, expected_count 1); `t.w = 5` drifts the
    // count; round 2's native entry fails seed validation → seed_hash_decline
    // → the dispatcher reruns THE DECLINER on tier-1a → tier-0, output
    // byte-identical across all ten legs, no strike charged.
    try expectProgramTuned(
        \\local t = { v = 3 }
        \\local acc = 0
        \\for round = 1, 2 do
        \\  for i = 1, 40 do acc = acc + t.v end
        \\  if round == 1 then t.w = 5 end
        \\end
        \\print(acc)
    , "240\n", .{ .hotguard = 3, .inspect = &assertHashDriftDeclined });
}

test "executor: doc 31 ratchet regression — fixed short gmatch instances never gate the anchor" {
    // The str_gmatch pathology (doc 31 §1): each for-in instance yields a
    // FIXED token count below min_useful (5 here < 8), ending in a designed
    // exhaustion exit (a completed=0 receipt). Under the pre-doc-31 clear
    // threshold those zeros ratcheted the penalty to a gate the productive
    // receipts could never un-earn (2.6% native residency on a healthy trace
    // at bench scale); under clear-on-productive the anchor stays ungated
    // across arbitrarily many instances, receipts keep flowing, and output
    // is byte-identical to tier-0.
    const source =
        \\local n = 0
        \\for j = 1, 300 do
        \\  for w in string.gmatch("a b c d e", "%a") do n = n + 1 end
        \\end
        \\print(n)
    ;
    try expectTier0Equiv(source);

    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    var chunk = try runExecForTrace(&vm, gpa, source, &sink);
    defer chunk.deinit();
    try testing.expectEqualStrings("1500\n", sink.buffered());
    // Probe (2026-08-29): gate=0 record_gate=1 entries=300 penalty=0 cache=1.
    // The one record_gate entry is the OUTER j-loop's recording abort (its
    // body contains the untraceable generic-for header) — correctly a record
    // gate now, leaving the gmatch anchor's dispatch untouched.
    try testing.expectEqual(@as(usize, 0), vm.trace.gate.count());
    try testing.expectEqual(@as(usize, 0), vm.trace.penalty.count());
    try testing.expect(vm.trace.entries > 100);
}

// ---------------------------------------------------------------------------
// Doc 39 — numeric φ widening via a type-stabilizing peel. A plain-while root
// whose carried slot enters int at the recording trip but leaves it float
// commits as a PEELED trace: iteration 1 is a verbatim run-once region behind
// the preheader marker (int semantics preserved), iteration 2 records the
// float steady state against internal φs, and nativegen homes the split
// (entry load int/GP, steady value in the internal φ's XMM home, deopt flush
// from the steady home — skipped entirely at zero local completions).

/// The peel must actually have fired: some cached trace is `peeled`, carries
/// the mid-stream preheader marker, at least one internal φ, and a slot-bound
/// φ with a steady-φ association. On the native leg it must also have lowered
/// to machine code (the RV-3 relaxation is the whole point of Phase 3).
fn assertPeelCommitted(vm: *Vm, mode: TraceMode) anyerror!void {
    if (mode == .off) return; // no recorder, no cache — output oracle only
    var peeled: ?*const trace.Trace = null;
    for (vm.trace.cache.items) |tr| {
        if (tr.peeled) peeled = tr;
    }
    try testing.expect(peeled != null);
    const tr = peeled.?;
    var saw_marker = false;
    var saw_internal_phi = false;
    var saw_steady_assoc = false;
    for (tr.instrs) |ins| {
        switch (ins.op) {
            .preheader => saw_marker = true,
            .phi => {
                if (ins.aux == trace.PHI_INTERNAL) saw_internal_phi = true;
                if (ins.aux >= 0 and ins.a != 0) saw_steady_assoc = true;
            },
            else => {},
        }
    }
    try testing.expect(saw_marker);
    try testing.expect(saw_internal_phi);
    try testing.expect(saw_steady_assoc);
    if (mode == .record_execute_native) try testing.expect(tr.native == .compiled);
}

/// Doc 39 negative probes: whatever traces the program minted, NONE of them
/// peeled (the shape is out of the peel's v1 scope) — the output oracle in the
/// surrounding matrix run carries the correctness claim.
fn assertNoPeel(vm: *Vm, mode: TraceMode) anyerror!void {
    if (mode == .off) return;
    for (vm.trace.cache.items) |tr| {
        try testing.expect(!tr.peeled);
    }
}

test "doc 39: recurring int-entry/float-body while root peels, compiles, and stays byte-identical" {
    // Each kernel() instance re-arrives at the while anchor with `x` int; the
    // body forces it float at trip >= 5. With `hotloop = 4` the root records at
    // trip 5 of instance 1 — the transition trip — so the recording sees the
    // int entry AND the float body: the doc-39 peel shape. Every later
    // instance re-enters the peeled trace at ITS trip-5 arrival and runs the
    // float steady state to completion inside the trace.
    try expectProgramTuned(
        \\local function kernel()
        \\  local x = 0
        \\  local i = 1
        \\  while i < 30 do
        \\    if i >= 5 then x = x + 0.5 else x = x + 1 end
        \\    i = i + 1
        \\  end
        \\  return x
        \\end
        \\local s = 0
        \\for m = 1, 8 do s = s + kernel() end
        \\print(s)
    , "132\n", .{ .inspect = &assertPeelCommitted });
}

test "doc 39: zero-completion deopt leaves the boxes untouched (tier-0 replays iterations 1-2)" {
    // Instance m == 4 diverges INSIDE the run-once region (the iteration-1
    // branch guard fails before the first back-edge), so the peeled trace
    // exits with zero local completions: the deopt flush must be skipped and
    // tier-0 must replay both partial iterations from the int header state.
    try expectProgramTuned(
        \\local function kernel(skew)
        \\  local x = 0
        \\  local i = 1
        \\  while i < 30 do
        \\    if i >= 5 + skew then x = x + 0.5 else x = x + 1 end
        \\    i = i + 1
        \\  end
        \\  return x
        \\end
        \\local s = 0
        \\for m = 1, 8 do s = s + kernel(m == 4 and 3 or 0) end
        \\print(s)
    , "133.5\n", .{ .inspect = &assertPeelCommitted });
}

test "doc 39: run-once region keeps exact int semantics above 2^53" {
    // The int adds ride above 2^53 where float arithmetic rounds: if anything
    // widened iteration 1 early (the rejected eager-coercion design), the odd
    // increments would round and the printed difference would drift. The
    // outer loop re-runs the kernel so the peeled trace's run-once region
    // executes natively on later instances.
    try expectProgramTuned(
        \\local function kernel()
        \\  local y = 9007199254740993
        \\  local i = 1
        \\  while i < 30 do
        \\    if i >= 5 then y = y + 0.5 else y = y + 3 end
        \\    i = i + 1
        \\  end
        \\  return y - 9007199254740992
        \\end
        \\local r = 0
        \\for m = 1, 8 do r = kernel() end
        \\print(r)
    , "12\n", .{ .inspect = &assertPeelCommitted });
}

test "doc 39: the F1 reverse shape (float entry, int store) does not peel" {
    // At the recording trip (i == 5) the carried `x` enters FLOAT and the body
    // stores an int konst — the narrowing direction doc 39 explicitly defers.
    // The instability sweep requires an int entry, so the peel must decline;
    // the trace commits unpeeled (RV-3 keeps it off native) and the matrix
    // holds output parity.
    try expectProgramTuned(
        \\local x = 8
        \\local i = 1
        \\while i < 40 do
        \\  if i % 5 == 0 then x = 8 else x = x / 2 end
        \\  i = i + 1
        \\end
        \\print(x)
    , "0.5\n", .{ .inspect = &assertNoPeel });
}

test "doc 40 phase 0: zero-completion while-done on a peeled trace must not chain stale state" {
    // Codex finding 3 on the landed doc-39 code. Instances with n == 30 commit
    // the peel and drive the while-loopdone continuation machinery hot. The
    // m == 7 instance passes n == 6: it arrives at trip 5 with x == 4 (int, so
    // the peeled trace's fingerprint matches), the run-once region executes
    // iteration 5 (x -> 4.5, i -> 6), and the STEADY region's condition check
    // `i < n` fails before the first `.loop` — a while-done-classified exit
    // with zero local completions whose run-once work is real but unflushed.
    // If the loop-done chain continues at the post-loop PC from the untouched
    // boxes, the instance contributes the stale 4 instead of 4.5 and the sum
    // drifts. The inner while must share the OUTER loop's frame — a while
    // inside a called function can never arm the loop-done continuation
    // ("cont-arm refuse: no enclosing back-edge"), which would leave this
    // test green without ever reaching the chain path.
    try expectProgramTuned(
        \\local s = 0
        \\for m = 1, 12 do
        \\  local bound = (m == 7) and 6 or 30
        \\  local x = 0
        \\  local i = 1
        \\  while i < bound do
        \\    if i >= 5 then x = x + 0.5 else x = x + 1 end
        \\    i = i + 1
        \\  end
        \\  s = s + x
        \\end
        \\print(s)
    , "186\n", .{ .inspect = &assertPeelCommitted });
}

/// Doc 40 Phase 1: no cached trace may be a native `.unsupported` verdict.
/// The self-defeating F1-reverse commits were exactly the traces RV-3 kept
/// off native; with the commit preflight they must never enter the cache, so
/// every trace the program DID cache either compiled or was never dispatched
/// natively. Also demands the cache is non-empty (vacuity guard).
fn assertNoUnsupportedTraces(vm: *Vm, mode: TraceMode) anyerror!void {
    if (mode == .off) return;
    try testing.expect(vm.trace.cache.items.len > 0);
    for (vm.trace.cache.items) |tr| {
        try testing.expect(tr.native != .unsupported);
    }
}

test "doc 40 phase 1: the reset-to-int glue shape no longer commits self-defeating loop traces" {
    // The fft_bitreverse reduction: `k = n` stores an int into a slot the
    // while body floats (`k = k / 2`), so the glue/wrap recordings (prime-side
    // + continuation channels) close with a float entry fingerprint and an
    // int back-edge store — DOA as `.loop` traces (they can never take their
    // own back-edge) and the exact traces RV-3 kept off native. The commit
    // preflight must refuse them: post-run, NO cached trace carries a native
    // `.unsupported` verdict, and the ten-leg output oracle holds.
    try expectProgramTuned(
        \\local n = 16
        \\local total = 0
        \\for outer = 1, 60 do
        \\  local j = 0
        \\  for i = 0, 2 * n - 4, 2 do
        \\    if i < j then total = total + 1 end
        \\    local k = n
        \\    while k <= j do j = j - k; k = k / 2 end
        \\    j = j + k
        \\  end
        \\end
        \\print(total)
    , "360\n", .{ .inspect = &assertNoUnsupportedTraces });
}

test "doc 39: a numeric-for anchor with the same transition does not peel" {
    // Same int->float transition, but the anchor is a numeric `for` back-edge,
    // not a plain while — `maybeEnterPeel`'s `isPlainWhileAnchor` gate
    // declines and the close takes the ordinary path.
    try expectProgramTuned(
        \\local x = 0
        \\for i = 1, 30 do
        \\  if i >= 5 then x = x + 0.5 else x = x + 1 end
        \\end
        \\print(x)
    , "17\n", .{ .inspect = &assertNoPeel });
}
