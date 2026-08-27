//! Tests for `interp.zig` — effects.
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

const ClockSource = interp.ClockSource;
const Effect = interp.Effect;
const EffectKind = interp.EffectKind;
const EffectMode = interp.EffectMode;
const HostEnv = interp.HostEnv;
const RandomSeedSource = interp.RandomSeedSource;
const Vm = interp.Vm;
const catchable = interp.catchable;
const noteUnicodeVersion = interp.noteUnicodeVersion;

const util = @import("interp_testutil.zig");
const FakeFs = util.FakeFs;
const compileRun = util.compileRun;
const expectProgram = util.expectProgram;

// ---------------------------------------------------------------------------
// F2d — effect record / replay
//
// `clock()` is the first nondeterministic *input*: two calls differ, so two
// independent runs of a clock()-using program print different output. Recording
// the effect log and replaying it makes re-execution reproducible — the
// foundation deterministic replay (restore a keyframe, feed effects back) stands
// on. These tests prove (1) replay reproduces the recorded output exactly, (2)
// two fresh records genuinely differ (the nondeterminism is real), and (3) a
// short / exhausted log is reported, not silently wrong.
// ---------------------------------------------------------------------------

const EffectRun = struct {
    out: []u8,
    log: []Effect,
    fn deinit(self: EffectRun, gpa: std.mem.Allocator) void {
        gpa.free(self.out);
        gpa.free(self.log);
    }
};

/// A deterministic test clock: returns `next`, `next+step`, `next+2*step`, …
/// Injected as a `ClockSource` so tests don't depend on the wall clock. Two
/// distinct counters model the nondeterminism a real clock has between runs.
const CounterClock = struct {
    next: i64,
    step: i64 = 1,
    fn nowNs(ctx: *anyopaque) i64 {
        const self: *CounterClock = @ptrCast(@alignCast(ctx));
        const v = self.next;
        self.next += self.step;
        return v;
    }
    fn source(self: *CounterClock) ClockSource {
        return .{ .ctx = self, .nowNs = &CounterClock.nowNs };
    }
};

/// A deterministic test seed source: always hands back the same `value`. Injected
/// as a `RandomSeedSource` so `random()` tests don't depend on OS entropy. Two
/// distinct fixed seeds model the nondeterminism a real seed has between runs.
const FixedSeed = struct {
    value: u64,
    fn seed(ctx: *anyopaque) u64 {
        const self: *FixedSeed = @ptrCast(@alignCast(ctx));
        return self.value;
    }
    fn source(self: *FixedSeed) RandomSeedSource {
        return .{ .ctx = self, .seed = &FixedSeed.seed };
    }
};

/// A deterministic test env/args source for `getenv`/`argc`/`argv`. Holds a tiny
/// fixed environment + argv so tests don't depend on the real process. `HOME` is
/// set, `EMPTY` is set-but-empty (to exercise the ""-vs-unset distinction), and
/// every other name is unset (→ nil).
const FakeEnv = struct {
    home: []const u8 = "/home/bart",
    args: []const []const u8 = &.{ "prog", "alpha", "beta" },
    fn getenvFn(ctx: *anyopaque, name: []const u8) ?[]const u8 {
        const self: *FakeEnv = @ptrCast(@alignCast(ctx));
        if (std.mem.eql(u8, name, "HOME")) return self.home;
        if (std.mem.eql(u8, name, "EMPTY")) return ""; // set, but empty — not nil
        if (std.mem.eql(u8, name, "BADUTF8")) return "\xFF\xFE"; // not valid UTF-8 (S-B boundary)
        return null;
    }
    fn argCountFn(ctx: *anyopaque) i64 {
        const self: *FakeEnv = @ptrCast(@alignCast(ctx));
        return @intCast(self.args.len);
    }
    fn argFn(ctx: *anyopaque, i: i64) ?[]const u8 {
        const self: *FakeEnv = @ptrCast(@alignCast(ctx));
        if (i < 0 or i >= self.args.len) return null;
        return self.args[@intCast(i)];
    }
    fn source(self: *FakeEnv) HostEnv {
        return .{
            .ctx = self,
            .getenv = &FakeEnv.getenvFn,
            .argCount = &FakeEnv.argCountFn,
            .arg = &FakeEnv.argFn,
        };
    }
};

/// Compile + run `source` with the given effect mode. `preload` (replay only)
/// seeds the effect log fed back in call order. `clock` (record/off only) is the
/// injected deterministic clock; replay needs none (it feeds the log back).
/// Returns owned copies of the printed output and the resulting effect log
/// (`clock` results are ints, so the log is self-contained — safe past `vm.deinit`).
fn effectRun(gpa: std.mem.Allocator, source: [:0]const u8, mode: EffectMode, preload: []const Effect, clock: ?*CounterClock, seed: ?*FixedSeed) !EffectRun {
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");

    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();
    try testing.expect(!diags.hasErrors());

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var sink_buf: [512]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    vm.out = &sink;
    vm.effect_mode = mode;
    if (clock) |c| vm.clock_source = c.source();
    if (seed) |s| vm.random_seed_source = s.source();
    if (preload.len > 0) try vm.effect_log.appendSlice(gpa, preload);

    var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());

    _ = try vm.run(chunk.proto);
    return .{
        .out = try gpa.dupe(u8, sink.buffered()),
        .log = try gpa.dupe(Effect, vm.effect_log.items),
    };
}

test "F2d: replaying a recorded effect log reproduces the recorded output" {
    const gpa = testing.allocator;
    // Output that *depends on* the clock values, so replay fidelity is observable.
    const source =
        \\for i = 1, 4 do print(os.clock()) end
    ;

    // Record a run against a known clock sequence (1000, 1001, …): the printed
    // values land in `out`, the effects in `log`.
    var clk = CounterClock{ .next = 1000 };
    const rec = try effectRun(gpa, source, .record, &.{}, &clk, null);
    defer rec.deinit(gpa);
    try testing.expectEqual(@as(usize, 4), rec.log.len);

    // Replay the SAME log into a fresh VM with NO clock injected: clock() is not
    // called — the logged values are fed back — so output is byte-identical.
    const rep = try effectRun(gpa, source, .replay, rec.log, null, null);
    defer rep.deinit(gpa);
    try testing.expectEqualStrings(rec.out, rep.out);
    // Replay re-emits the same effects into its own log (every clock() consumed one).
    try testing.expectEqual(rec.log.len, rep.log.len);

    // A second record against a DIFFERENT clock sequence (9000, 9001, …) genuinely
    // differs — modelling the nondeterminism a real clock has between runs, which is
    // exactly what the log captures. (With injection the clock is deterministic, so
    // we vary it explicitly rather than leaning on wall-clock advance.)
    var clk2 = CounterClock{ .next = 9000 };
    const rec2 = try effectRun(gpa, source, .record, &.{}, &clk2, null);
    defer rec2.deinit(gpa);
    try testing.expect(!std.mem.eql(u8, rec.out, rec2.out));
}

test "F2d: replay with a too-short log reports EffectLogExhausted (no silent divergence)" {
    const gpa = testing.allocator;
    const source =
        \\print(os.clock()); print(os.clock())
    ;
    // A one-entry log for a program that asks for two effects. Replay feeds the
    // log back (no clock needed) and runs out on the second call.
    const short = [_]Effect{.{ .kind = .clock, .result = Value.int(123) }};
    try testing.expectError(error.EffectLogExhausted, effectRun(gpa, source, .replay, &short, null, null));
}

test "F2d: off mode logs nothing and calls effects normally (default behaviour)" {
    const gpa = testing.allocator;
    // Off mode calls the injected clock directly and logs nothing.
    var clk = CounterClock{ .next = 1 };
    const run = try effectRun(gpa, "print(os.clock() > 0)", .off, &.{}, &clk, null);
    defer run.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), run.log.len);
    try testing.expectEqualStrings("true\n", run.out);
}

test "F2d: clock() with no injected source is ClockUnavailable" {
    const gpa = testing.allocator;
    // The interpreter holds no clock of its own; record/off with no source set
    // surfaces a clear error rather than reaching for a platform clock.
    try testing.expectError(error.ClockUnavailable, effectRun(gpa, "print(os.clock())", .record, &.{}, null, null));
}

test "F2d: os.clock is float seconds, os.nsclock is int nanoseconds (same source)" {
    const gpa = testing.allocator;
    // Pin the clock so both reads see the same instant (2.5e9 ns = 2.5 s). os.clock
    // divides to a float; os.nsclock hands back the raw integer nanoseconds.
    var clk = CounterClock{ .next = 2_500_000_000, .step = 0 };
    const run = try effectRun(gpa,
        \\print(os.clock() == 2.5)
        \\print(os.nsclock() == 2500000000)
        \\print(math.type(os.clock()), math.type(os.nsclock()))
    , .off, &.{}, &clk, null);
    defer run.deinit(gpa);
    try testing.expectEqualStrings("true\ntrue\nfloat\tinteger\n", run.out);
    try testing.expectEqual(@as(usize, 0), run.log.len); // off mode logs nothing
}

test "F2d: a run mixing os.clock (float) and os.nsclock (int) records + replays byte-identically" {
    const gpa = testing.allocator;
    // Both natives share EffectKind.clock; the log interleaves float and int
    // scalars, consumed by call order on replay. The shared-effect replay path is
    // the thing this exercises (the off-mode shape test above doesn't).
    const source =
        \\print(os.clock()); print(os.nsclock()); print(os.clock())
    ;
    var clk = CounterClock{ .next = 1_500_000_000, .step = 1_000_000_000 };
    const rec = try effectRun(gpa, source, .record, &.{}, &clk, null);
    defer rec.deinit(gpa);
    try testing.expectEqual(@as(usize, 3), rec.log.len); // 2 os.clock + 1 os.nsclock
    // Replay feeds the log back (no clock injected) → byte-identical output.
    const rep = try effectRun(gpa, source, .replay, rec.log, null, null);
    defer rep.deinit(gpa);
    try testing.expectEqualStrings(rec.out, rep.out);
    try testing.expectEqual(rec.log.len, rep.log.len);
}

// ---------------------------------------------------------------------------
// warn — Lua 5.4 diagnostic warnings (pure stderr output, NOT a recorded effect)
// ---------------------------------------------------------------------------

const OutErr = struct { out: []const u8, err: []const u8 };

/// Run `source` capturing stdout (`vm.out`) into `out_buf` and `warn` output
/// (`vm.err`) into `err_buf`; returns slices into those caller-owned buffers.
fn runOutErr(gpa: std.mem.Allocator, source: [:0]const u8, out_buf: []u8, err_buf: []u8) !OutErr {
    var out = io.Writer.fixed(out_buf);
    var err = io.Writer.fixed(err_buf);
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    vm.out = &out;
    vm.err = &err;
    vm.source = source;
    try compileRun(gpa, &vm, source);
    return .{ .out = out.buffered(), .err = err.buffered() };
}

test "warn: concatenates string args into one stderr line, separate from stdout" {
    var ob: [256]u8 = undefined;
    var eb: [256]u8 = undefined;
    const r = try runOutErr(testing.allocator,
        \\warn("a", "b", "c")
        \\print("x")
    , &ob, &eb);
    try testing.expectEqualStrings("lune warning: abc\n", r.err);
    try testing.expectEqualStrings("x\n", r.out);
}

test "warn: @off suppresses, @on re-enables (control while off is still honoured)" {
    var ob: [256]u8 = undefined;
    var eb: [256]u8 = undefined;
    const r = try runOutErr(testing.allocator,
        \\warn("one")
        \\warn("@off")
        \\warn("two")
        \\warn("@on")
        \\warn("three")
    , &ob, &eb);
    // "two" is suppressed; "@on" re-enables even though the system was off.
    try testing.expectEqualStrings("lune warning: one\nlune warning: three\n", r.err);
}

test "warn: unknown @control is ignored (system stays on, no line emitted for it)" {
    var ob: [256]u8 = undefined;
    var eb: [256]u8 = undefined;
    const r = try runOutErr(testing.allocator,
        \\warn("@frobnicate")
        \\warn("still on")
    , &ob, &eb);
    try testing.expectEqualStrings("lune warning: still on\n", r.err);
}

test "warn: a leading-@ piece is only a control message when it is the sole arg" {
    var ob: [256]u8 = undefined;
    var eb: [256]u8 = undefined;
    const r = try runOutErr(testing.allocator,
        \\warn("@x", "y")
    , &ob, &eb);
    // Two pieces → not a control message → emitted verbatim (concatenated).
    try testing.expectEqualStrings("lune warning: @xy\n", r.err);
}

test "warn: non-string and missing arguments are bad-argument errors" {
    var ob: [256]u8 = undefined;
    var eb: [256]u8 = undefined;
    // Every piece is checked before any emission (Lua semantics): a bad 2nd arg
    // raises even though the 1st is a valid string.
    try testing.expectError(error.LuaError, runOutErr(testing.allocator, "warn(\"ok\", 5)", &ob, &eb));
    try testing.expectError(error.LuaError, runOutErr(testing.allocator, "warn()", &ob, &eb));
}

// ---------------------------------------------------------------------------
// F2e — seed-based randomness (`math.random` / `math.randomseed`)
//
// `math.random()` is a nondeterministic *input* like `clock()`, but seed-based:
// the single recorded effect is one `random_seed`, acquired lazily on the first
// call, from which a VM-internal PRNG reproduces the entire draw stream on replay.
// So a multi-draw program records exactly ONE effect, and replaying that one seed
// reproduces every draw byte-identically. These tests prove (1) record→replay
// fidelity with a single logged seed, (2) different seeds yield different streams
// (the PRNG genuinely varies), (3) a missing seed in the log is reported, (4) no
// injected source is a clear error, (5) draws lie in [0,1), (6) the integer forms
// `math.random(n)` / `math.random(m,n)` stay in range and reject empty intervals,
// and (7) `math.randomseed` re-seeds deterministically (and its no-arg entropy
// form records/replays through the same boundary).
// ---------------------------------------------------------------------------

test "F2e: replaying the recorded seed reproduces the whole draw stream" {
    const gpa = testing.allocator;
    // Three draws — proving the single seed drives the entire stream, not one call.
    const source =
        \\print(math.random()); print(math.random()); print(math.random())
    ;

    var sd = FixedSeed{ .value = 0xC0FFEE };
    const rec = try effectRun(gpa, source, .record, &.{}, null, &sd);
    defer rec.deinit(gpa);
    // Exactly one effect logged regardless of draw count: the seed, acquired once.
    try testing.expectEqual(@as(usize, 1), rec.log.len);
    try testing.expectEqual(EffectKind.random_seed, rec.log[0].kind);

    // Replay the one-entry log into a fresh VM with NO seed source: random() is
    // still called (it is a pure native), but the seed comes from the log, so the
    // PRNG reproduces the identical stream and output is byte-identical.
    const rep = try effectRun(gpa, source, .replay, rec.log, null, null);
    defer rep.deinit(gpa);
    try testing.expectEqualStrings(rec.out, rep.out);
    try testing.expectEqual(rec.log.len, rep.log.len);
}

test "F2e: different seeds yield different draw streams" {
    const gpa = testing.allocator;
    const source =
        \\print(math.random()); print(math.random())
    ;
    var sd_a = FixedSeed{ .value = 1 };
    var sd_b = FixedSeed{ .value = 2 };
    const a = try effectRun(gpa, source, .record, &.{}, null, &sd_a);
    defer a.deinit(gpa);
    const b = try effectRun(gpa, source, .record, &.{}, null, &sd_b);
    defer b.deinit(gpa);
    // Same seed would mean same stream; two distinct seeds must differ (this is
    // the nondeterminism the log captures — two fresh records use fresh seeds).
    try testing.expect(!std.mem.eql(u8, a.out, b.out));
}

test "F2e: replay with no seed in the log reports EffectLogExhausted" {
    const gpa = testing.allocator;
    // An empty log for a program that needs the seed: replay runs out immediately.
    try testing.expectError(error.EffectLogExhausted, effectRun(gpa, "print(math.random())", .replay, &.{}, null, null));
}

test "F2e: math.random() with no injected source is RandomUnavailable" {
    const gpa = testing.allocator;
    // The VM owns the PRNG but not the seed; record/off with no source set
    // surfaces a clear error rather than reaching for OS entropy itself.
    try testing.expectError(error.RandomUnavailable, effectRun(gpa, "print(math.random())", .record, &.{}, null, null));
}

test "F2e: draws lie in [0,1)" {
    const gpa = testing.allocator;
    // `r < 1 and r >= 0` over several draws — the float() contract.
    const source =
        \\local ok = true
        \\for i = 1, 50 do
        \\  local r = math.random()
        \\  if r < 0 or r >= 1 then ok = false end
        \\end
        \\print(ok)
    ;
    var sd = FixedSeed{ .value = 42 };
    const run = try effectRun(gpa, source, .record, &.{}, null, &sd);
    defer run.deinit(gpa);
    try testing.expectEqualStrings("true\n", run.out);
}

test "F2e: math.random(m,n) stays in [m,n] and hits both ends" {
    const gpa = testing.allocator;
    // Over many draws of a small interval every result must be in [m,n], and the
    // bounds must actually be reachable (the projection isn't off-by-one).
    const source =
        \\local lo, hi = 3, 8
        \\local ok, sawlo, sawhi = true, false, false
        \\for i = 1, 400 do
        \\  local r = math.random(lo, hi)
        \\  if r < lo or r > hi then ok = false end
        \\  if r == lo then sawlo = true end
        \\  if r == hi then sawhi = true end
        \\end
        \\print(ok, sawlo, sawhi)
    ;
    var sd = FixedSeed{ .value = 42 };
    const run = try effectRun(gpa, source, .record, &.{}, null, &sd);
    defer run.deinit(gpa);
    try testing.expectEqualStrings("true\ttrue\ttrue\n", run.out);
}

test "F2e: math.random(n) is [1,n]; (1,1) is always 1; (0) spans negatives" {
    const gpa = testing.allocator;
    const source =
        \\local ok = true
        \\for i = 1, 200 do
        \\  local r = math.random(6)         -- [1,6]
        \\  if r < 1 or r > 6 then ok = false end
        \\  if math.random(1, 1) ~= 1 then ok = false end
        \\end
        \\-- random(0) is a full-width integer: over many draws at least one is
        \\-- negative (the high bit set), proving it isn't clamped to non-negative.
        \\local sawneg = false
        \\for i = 1, 200 do if math.random(0) < 0 then sawneg = true end end
        \\print(ok, sawneg)
    ;
    var sd = FixedSeed{ .value = 7 };
    const run = try effectRun(gpa, source, .record, &.{}, null, &sd);
    defer run.deinit(gpa);
    try testing.expectEqualStrings("true\ttrue\n", run.out);
}

test "F2e: math.random empty interval and non-integer args are bad-argument errors" {
    const gpa = testing.allocator;
    var sd = FixedSeed{ .value = 1 };
    // m > n → "interval is empty".
    try testing.expectError(error.LuaError, effectRun(gpa, "print(math.random(5, 2))", .record, &.{}, null, &sd));
    var sd2 = FixedSeed{ .value = 1 };
    // a non-integral float → "number has no integer representation".
    try testing.expectError(error.LuaError, effectRun(gpa, "print(math.random(1.5))", .record, &.{}, null, &sd2));
    var sd3 = FixedSeed{ .value = 1 };
    // a non-number → "number expected".
    try testing.expectError(error.LuaError, effectRun(gpa, "print(math.random('x'))", .record, &.{}, null, &sd3));
}

test "F2e: an invalid math.random call raises before touching the seed/effect boundary" {
    const gpa = testing.allocator;
    // Reviewers' catch: arg/interval validation must happen BEFORE the lazy seed,
    // so an invalid *first* call doesn't consume the entropy/effect boundary. Proof:
    // in replay mode with an EMPTY log, an invalid call surfaces its bad-argument
    // LuaError — NOT EffectLogExhausted (which is what trying to read a seed first
    // would yield). Both the empty-interval and the bad-type forms.
    try testing.expectError(error.LuaError, effectRun(gpa, "print(math.random(5, 2))", .replay, &.{}, null, null));
    try testing.expectError(error.LuaError, effectRun(gpa, "print(math.random('x'))", .replay, &.{}, null, null));
    // And in record mode with a seed source: an invalid first call logs ZERO
    // effects (the seed was never acquired). Inspect the log on a live VM.
    var sd = FixedSeed{ .value = 1 };
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var sink_buf: [256]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    vm.out = &sink;
    vm.effect_mode = .record;
    vm.random_seed_source = sd.source();
    try testing.expectError(error.LuaError, compileRun(gpa, &vm, "math.random(5, 2)"));
    try testing.expectEqual(@as(usize, 0), vm.effect_log.items.len);
}

test "F2e: math.randomseed(x) re-seeds deterministically (same seed → same stream)" {
    const gpa = testing.allocator;
    // Explicit-seed form logs NO effect (the seed is in the program), and seeding
    // twice with the same x reproduces the stream — proving the re-seed is a pure
    // function of x, independent of the lazy entropy seed.
    const source =
        \\math.randomseed(123)
        \\local a = {}
        \\for i = 1, 5 do a[i] = math.random(1, 1000) end
        \\math.randomseed(123)
        \\local same = true
        \\for i = 1, 5 do if math.random(1, 1000) ~= a[i] then same = false end end
        \\print(same)
    ;
    // No seed source injected: an explicit randomseed needs none, and no lazy seed
    // is acquired (rng is set before the first draw), so this records zero effects.
    const run = try effectRun(gpa, source, .off, &.{}, null, null);
    defer run.deinit(gpa);
    try testing.expectEqualStrings("true\n", run.out);
    try testing.expectEqual(@as(usize, 0), run.log.len);
}

test "F2e: math.randomseed() entropy form records and replays the seed" {
    const gpa = testing.allocator;
    // No-arg randomseed pulls one entropy seed through the .random_seed boundary,
    // so a draw afterward is reproduced byte-for-byte on replay of that one effect.
    const source =
        \\math.randomseed()
        \\print(math.random(1, 1000000))
    ;
    var sd = FixedSeed{ .value = 0xABCDEF };
    const rec = try effectRun(gpa, source, .record, &.{}, null, &sd);
    defer rec.deinit(gpa);
    // Exactly one effect: the no-arg randomseed's entropy draw (the later
    // math.random reuses that PRNG state, logging nothing).
    try testing.expectEqual(@as(usize, 1), rec.log.len);
    try testing.expectEqual(EffectKind.random_seed, rec.log[0].kind);
    const rep = try effectRun(gpa, source, .replay, rec.log, null, null);
    defer rep.deinit(gpa);
    try testing.expectEqualStrings(rec.out, rep.out);
}

test "F2e: math.randomseed() with no injected source is RandomUnavailable" {
    const gpa = testing.allocator;
    // The no-arg entropy form needs a seed source, exactly like a lazy random().
    try testing.expectError(error.RandomUnavailable, effectRun(gpa, "math.randomseed()", .record, &.{}, null, null));
}

// ---------------------------------------------------------------------------
// env/args effects — `getenv`/`argc`/`argv` as nondeterministic inputs. These
// are the first effects whose result is a heap *string*, so they exercise (a)
// the value semantics (set vs unset vs empty, argv bounds), (b) the replay
// feed-back of a string result, and (c) the GC-root that keeps a parked string
// result alive across a collection. The cross-run *byte* equivalence (serialize
// → replay) is proven in `effectser`'s round-trip test, where a standalone
// effect-log blob sidesteps cross-heap string lifetimes.
// ---------------------------------------------------------------------------

test "env: getenv reads set/unset/empty; argc/argv read the args (record)" {
    const gpa = testing.allocator;
    var fenv = FakeEnv{};
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var sink_buf: [512]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    vm.out = &sink;
    vm.effect_mode = .record;
    vm.host_env = fenv.source();

    try compileRun(gpa, &vm,
        \\print(getenv("HOME"))
        \\print(getenv("MISSING"))
        \\print(getenv("EMPTY") == "")
        \\print(argc())
        \\print(argv(0)); print(argv(2))
        \\print(argv(5))
    );
    // HOME set; MISSING → nil; EMPTY is set-but-empty (== "" is true, not nil);
    // argc = 3; argv(0)/argv(2) in range; argv(5) out of range → nil.
    try testing.expectEqualStrings(
        "/home/bart\nnil\ntrue\n3\nprog\nbeta\nnil\n",
        sink.buffered(),
    );
    // One effect logged per effect call: 3 getenv + 1 argc + 3 argv = 7.
    try testing.expectEqual(@as(usize, 7), vm.effect_log.items.len);
    try testing.expectEqual(EffectKind.getenv, vm.effect_log.items[0].kind);
    try testing.expectEqual(EffectKind.argc, vm.effect_log.items[3].kind);
    try testing.expectEqual(EffectKind.argv, vm.effect_log.items[4].kind);
}

test "env: getenv/argc/argv with no host_env injected is EnvUnavailable" {
    const gpa = testing.allocator;
    inline for (.{ "print(getenv(\"X\"))", "print(argc())", "print(argv(0))" }) |src| {
        var vm = try Vm.init(gpa);
        defer vm.deinit();
        vm.effect_mode = .record; // no host_env set
        try testing.expectError(error.EnvUnavailable, compileRun(gpa, &vm, src));
    }
}

test "env: a recorded string result survives a GC collection while parked in the log" {
    const gpa = testing.allocator;
    var fenv = FakeEnv{};
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    vm.effect_mode = .record;
    vm.host_env = fenv.source();

    // Read HOME but discard the result — nothing references the string except the
    // effect log. A collection would de-intern + free it without the new root.
    try compileRun(gpa, &vm, "getenv(\"HOME\")");
    try testing.expectEqual(@as(usize, 1), vm.effect_log.items.len);

    vm.collect(); // force a stop-the-world sweep

    // The logged result must still be a live string reading "/home/bart".
    const res = vm.effect_log.items[0].result;
    try testing.expect(res.isHeap() and res.heapType() == .string);
    try testing.expectEqualStrings("/home/bart", string.String.fromHeader(res.asHeap()).bytes());
}

test "env: replay feeds back a logged string result without calling the native" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var sink_buf: [128]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    vm.out = &sink;

    // Preload a getenv result interned into *this* VM's heap, then replay with no
    // host_env injected: getenv is not called — the logged string is fed back.
    const logged = try vm.heap.internValue("REPLAYED");
    try vm.effect_log.append(gpa, .{ .kind = .getenv, .result = logged });
    vm.effect_mode = .replay;

    try compileRun(gpa, &vm, "print(getenv(\"IGNORED\"))");
    try testing.expectEqualStrings("REPLAYED\n", sink.buffered());
}

test "S-B: getenv/argv of non-UTF-8 host bytes raises a catchable error" {
    const gpa = testing.allocator;
    // An env with one valid arg and one invalid-UTF-8 arg.
    var fenv = FakeEnv{ .args = &.{ "prog", "\xFF\xFE" } };
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var sink_buf: [512]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    vm.out = &sink;
    vm.effect_mode = .record;
    vm.host_env = fenv.source();

    try compileRun(gpa, &vm,
        \\print(getenv("HOME"))                 -- valid: still works
        \\print(argv(0))                          -- valid: "prog"
        \\local ok, e = pcall(getenv, "BADUTF8")  -- invalid env value → catchable error
        \\print(ok, type(e))
        \\local ok2, e2 = pcall(argv, 1)          -- invalid arg → catchable error
        \\print(ok2, type(e2))
    );
    // Valid reads pass through; the two invalid reads raise a string error value.
    try testing.expectEqualStrings(
        "/home/bart\nprog\nfalse\tstring\nfalse\tstring\n",
        sink.buffered(),
    );
}

test "S-B: a recorded non-UTF-8 getenv replays byte-identically (validate-after-log)" {
    const gpa = testing.allocator;
    const src =
        \\local ok, e = pcall(getenv, "BADUTF8")
        \\print(ok, type(e))
    ;
    // Record: the invalid bytes ARE logged (validation runs after logEffect), the
    // error is caught by pcall. Capture output + the effect log.
    var fenv = FakeEnv{};
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var rec_buf: [256]u8 = undefined;
    var rec_sink = io.Writer.fixed(&rec_buf);
    vm.out = &rec_sink;
    vm.effect_mode = .record;
    vm.host_env = fenv.source();
    try compileRun(gpa, &vm, src);
    const recorded = rec_sink.buffered();
    try testing.expectEqualStrings("false\tstring\n", recorded);
    // Exactly one getenv effect logged, holding the raw invalid bytes.
    try testing.expectEqual(@as(usize, 1), vm.effect_log.items.len);
    try testing.expectEqual(EffectKind.getenv, vm.effect_log.items[0].kind);

    // Replay the same VM's log (string result lives in this heap) with no host_env:
    // the native is not called, the logged bytes are re-validated → same raise,
    // same caught error, byte-identical output.
    vm.effect_mode = .replay;
    vm.effect_cursor = 0;
    vm.host_env = null;
    var rep_buf: [256]u8 = undefined;
    var rep_sink = io.Writer.fixed(&rep_buf);
    vm.out = &rep_sink;
    try compileRun(gpa, &vm, src);
    try testing.expectEqualStrings(recorded, rep_sink.buffered());
}

test "S-B: a recorded non-UTF-8 argv replays byte-identically (validate-after-log)" {
    const gpa = testing.allocator;
    const src =
        \\local ok, e = pcall(argv, 1)
        \\print(ok, type(e))
    ;
    // Record: arg 1 is invalid UTF-8. The bytes ARE logged (validation runs after
    // logEffect), the error is caught by pcall. argv is a distinct EffectKind from
    // getenv, so it exercises the same performEffect path under a different kind.
    var fenv = FakeEnv{ .args = &.{ "prog", "\xFF\xFE" } };
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var rec_buf: [256]u8 = undefined;
    var rec_sink = io.Writer.fixed(&rec_buf);
    vm.out = &rec_sink;
    vm.effect_mode = .record;
    vm.host_env = fenv.source();
    try compileRun(gpa, &vm, src);
    const recorded = rec_sink.buffered();
    try testing.expectEqualStrings("false\tstring\n", recorded);
    try testing.expectEqual(@as(usize, 1), vm.effect_log.items.len);
    try testing.expectEqual(EffectKind.argv, vm.effect_log.items[0].kind);

    // Replay the same VM's log with no host_env: the native is not called, the
    // logged bytes are re-validated → same raise, byte-identical output.
    vm.effect_mode = .replay;
    vm.effect_cursor = 0;
    vm.host_env = null;
    var rep_buf: [256]u8 = undefined;
    var rep_sink = io.Writer.fixed(&rep_buf);
    vm.out = &rep_sink;
    try compileRun(gpa, &vm, src);
    try testing.expectEqualStrings(recorded, rep_sink.buffered());
}

test "S-B: loadfile of non-UTF-8 file content raises a catchable error" {
    const gpa = testing.allocator;
    var ffs = FakeFs{
        .entries = &.{
            .{ .path = "good.lua", .content = "return 1" },
            .{ .path = "bad.lua", .content = "\xFF\xFE" }, // not valid UTF-8
        },
    };
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var sink_buf: [256]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    vm.out = &sink;
    vm.effect_mode = .record;
    vm.fs_source = ffs.source();

    try compileRun(gpa, &vm,
        \\print((loadfile("good.lua"))())     -- valid file still compiles + runs
        \\print(pcall(loadfile, "bad.lua"))   -- invalid bytes → catchable error
    );
    // The valid file returns 1; the bad read raises a string error value caught by pcall.
    const out = sink.buffered();
    try testing.expect(std.mem.startsWith(u8, out, "1\nfalse\t"));
}

test "S-B: a recorded non-UTF-8 loadfile replays byte-identically (validate-after-log)" {
    const gpa = testing.allocator;
    const src =
        \\local ok, e = pcall(loadfile, "bad.lua")
        \\print(ok, type(e))
    ;
    var ffs = FakeFs{ .entries = &.{
        .{ .path = "bad.lua", .content = "\xFF\xFE" },
    } };
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var rec_buf: [256]u8 = undefined;
    var rec_sink = io.Writer.fixed(&rec_buf);
    vm.out = &rec_sink;
    vm.effect_mode = .record;
    vm.fs_source = ffs.source();
    try compileRun(gpa, &vm, src);
    const recorded = rec_sink.buffered();
    try testing.expectEqualStrings("false\tstring\n", recorded);
    // Exactly one file_read effect logged, holding the raw invalid bytes.
    try testing.expectEqual(@as(usize, 1), vm.effect_log.items.len);
    try testing.expectEqual(EffectKind.file_read, vm.effect_log.items[0].kind);

    // Replay the same VM's log with no fs_source:
    // the logged bytes are re-validated -> same raise, same caught error, byte-identical output.
    vm.effect_mode = .replay;
    vm.effect_cursor = 0;
    vm.fs_source = null;
    var rep_buf: [256]u8 = undefined;
    var rep_sink = io.Writer.fixed(&rep_buf);
    vm.out = &rep_sink;
    try compileRun(gpa, &vm, src);
    try testing.expectEqualStrings(recorded, rep_sink.buffered());
}

test "S-B: populateArgs rejects a non-UTF-8 command-line argument" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    // A valid argv populates fine; an invalid one raises before it can enter `arg`.
    try vm.populateArgs(&.{ "prog", "ok" });
    try testing.expectError(error.LuaError, vm.populateArgs(&.{ "prog", "\xFF\xFE" }));

    // Atomicity: a malformed *later* arg must leave `arg[]` untouched, not
    // half-filled. Validate all args first, then mutate. Here arg[0]="prog" is
    // valid but arg[1] is invalid — the raise happens before any `tbl.set`, so a
    // fresh VM's `arg` table has neither entry.
    var vm2 = try Vm.init(gpa);
    defer vm2.deinit();
    try testing.expectError(error.LuaError, vm2.populateArgs(&.{ "prog", "\xFF\xFE" }));
    const argt = vm2.globals.get(try vm2.heap.internValue("arg"));
    try testing.expect(argt.isHeap() and argt.heapType() == .table);
    const tbl = table.Table.fromHeader(argt.asHeap());
    try testing.expect(tbl.get(Value.int(0)).isNil()); // "prog" never entered
    try testing.expect(tbl.get(Value.int(1)).isNil());
}

// ---------------------------------------------------------------------------
// S-C — Unicode-aware `upper`/`lower` + the `unicode_version` session effect.
// The case table is a compiled-in constant whose content churns between Unicode
// releases, so the active version is recorded once per session (at the first
// case op) and re-pinned on replay — a determinism gate. These tests prove (1)
// the version is pinned exactly once regardless of how many case ops run, (2) a
// recorded session replays byte-identically, and (3) a replay under a different
// version refuses (fatal, uncatchable) rather than silently diverging.
// ---------------------------------------------------------------------------

test "S-C: Unicode upper/lower is byte-identical across all modes" {
    try expectProgram(
        \\print(string.upper("café"), string.lower("ΑΒΓ"))
        \\print(#string.upper("héllo"))
        \\
    ,
        "CAFÉ\tαβγ\n5\n",
    );
}

test "S-C: case ops pin the unicode_version exactly once; replay is byte-identical" {
    const gpa = testing.allocator;
    const src =
        \\print(string.upper("café"))
        \\print(string.lower("ΑΒΓ"))
    ;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var rec_buf: [256]u8 = undefined;
    var rec_sink = io.Writer.fixed(&rec_buf);
    vm.out = &rec_sink;
    vm.effect_mode = .record;
    try compileRun(gpa, &vm, src);
    const recorded = rec_sink.buffered();
    try testing.expectEqualStrings("CAFÉ\nαβγ\n", recorded);
    // Two case operations, but the version is pinned only ONCE.
    try testing.expectEqual(@as(usize, 1), vm.effect_log.items.len);
    try testing.expectEqual(EffectKind.unicode_version, vm.effect_log.items[0].kind);

    // Replay the same log → byte-identical (the recorded version equals this
    // binary's compiled version, so the re-pin passes and the tables match).
    vm.effect_mode = .replay;
    vm.effect_cursor = 0;
    vm.unicode_version_pinned = false;
    var rep_buf: [256]u8 = undefined;
    var rep_sink = io.Writer.fixed(&rep_buf);
    vm.out = &rep_sink;
    try compileRun(gpa, &vm, src);
    try testing.expectEqualStrings(recorded, rep_sink.buffered());
}

test "S-C: a replay log with a wrong unicode_version is a fatal, uncatchable error" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var sink_buf: [128]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    vm.out = &sink;
    vm.effect_mode = .replay;
    // A log claiming a Unicode version this binary's table was NOT built against.
    try vm.effect_log.append(gpa, .{ .kind = .unicode_version, .result = Value.int(0xDEAD) });
    // Even wrapped in pcall, the mismatch is a determinism fault: NOT catchable.
    try testing.expectError(error.UnicodeVersionMismatch, compileRun(gpa, &vm,
        \\print(pcall(string.upper, "x"))
    ));
}

test "S-C: a unicode_version log entry with a non-int (float) result is rejected, not asserted" {
    // The shared scalar shape-gate accepts int OR float, so a corrupt log could
    // park a float-tagged result on a .unicode_version entry. noteUnicodeVersion
    // must turn that into a clean UnicodeVersionMismatch rather than asserting in
    // asInt() on hostile bytes.
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var sink_buf: [128]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    vm.out = &sink;
    vm.effect_mode = .replay;
    try vm.effect_log.append(gpa, .{ .kind = .unicode_version, .result = Value.float(16.0) });
    try testing.expectError(error.UnicodeVersionMismatch, compileRun(gpa, &vm,
        \\print(pcall(string.lower, "X"))
    ));
}

test "S-D: pattern matching over multibyte text is byte-identical across all modes" {
    // find/match/gmatch/gsub on a code-point-native string: character indices,
    // whole-code-point `.`, and multibyte gsub. Pattern ops are pure natives (JIT
    // trace barriers), so 8-mode parity is inherited — assert it. No host effect,
    // so this needs no recorded input.
    try expectProgram(
        \\local s = "héllo wörld"
        \\print(s:find("l"))            -- char start/end of first 'l'
        \\print(s:match("h(.)"))        -- captures the whole 'é'
        \\print(s:find("w()"))          -- start,end then position capture (char index)
        \\local t = {}
        \\for c in s:gmatch("%a") do t[#t+1] = c end
        \\print(#t, t[1], t[6])         -- ASCII-class only matches ASCII letters
        \\print((s:gsub(".", "x")))     -- every code point replaced once
        \\print(s:sub(s:find("wörld"))) -- find result composes with char-indexed sub
        \\
    ,
        "3\t3\n" ++
            "é\n" ++
            "7\t7\t8\n" ++
            "8\th\tr\n" ++
            "xxxxxxxxxxx\n" ++
            "wörld\n",
    );
}

// ---------------------------------------------------------------------------
// L-3 — `loadfile`/`dofile` + the `file_read` effect. A file read is a
// nondeterministic input (the filesystem differs between machines/runs), so the
// content rides the record/replay boundary exactly like `getenv`/`argv`: a heap
// string (or nil) logged on record, fed back on replay (the path is plain program
// data — only the content is the effect). These tests prove (1) `loadfile`/`dofile`
// work against an injected FS, (2) a record→serialize→replay round-trip reproduces
// the output with the FS DETACHED on replay (so the content provably came from the
// log, not disk), (3) a missing file is `(nil, msg)` for `loadfile` and a *raise*
// for `dofile`, and (4) no injected source is a clear `FsUnavailable`.
// ---------------------------------------------------------------------------

test "A-vi: committed effect sequence is mode-independent across all four commit families" {
    const gpa = testing.allocator;
    const effectser = @import("effectser.zig");
    const source: [:0]const u8 =
        \\local c = os.clock()
        \\local r = math.random()
        \\local u = string.upper("x")
        \\local v = string.lower("Y")
        \\local f = loadfile("effect.lua")
        \\print(c, r, u, v, f())
    ;
    var ffs = FakeFs{ .entries = &.{
        .{ .path = "effect.lua", .content = "return 42" },
    } };

    // Off mode commits the same four logical families without producing a log.
    {
        var clock = CounterClock{ .next = 1000 };
        var seed = FixedSeed{ .value = 0x1234 };
        var vm = try Vm.init(gpa);
        defer vm.deinit();
        var out_buf: [256]u8 = undefined;
        var sink = io.Writer.fixed(&out_buf);
        vm.out = &sink;
        vm.clock_source = clock.source();
        vm.random_seed_source = seed.source();
        vm.fs_source = ffs.source();
        try compileRun(gpa, &vm, source);
        try testing.expectEqual(@as(u64, 4), vm.committed_effect_seq);
        try testing.expectEqual(@as(usize, 0), vm.effect_log.items.len);
    }

    // Record produces clock, random_seed, unicode_version, file_read in order.
    var log_bytes: []u8 = undefined;
    {
        var clock = CounterClock{ .next = 1000 };
        var seed = FixedSeed{ .value = 0x1234 };
        var vm = try Vm.init(gpa);
        defer vm.deinit();
        var out_buf: [256]u8 = undefined;
        var sink = io.Writer.fixed(&out_buf);
        vm.out = &sink;
        vm.effect_mode = .record;
        vm.clock_source = clock.source();
        vm.random_seed_source = seed.source();
        vm.fs_source = ffs.source();
        try compileRun(gpa, &vm, source);
        try testing.expectEqual(@as(u64, 4), vm.committed_effect_seq);
        try testing.expectEqual(@as(usize, 4), vm.effect_log.items.len);
        try testing.expectEqual(EffectKind.clock, vm.effect_log.items[0].kind);
        try testing.expectEqual(EffectKind.random_seed, vm.effect_log.items[1].kind);
        try testing.expectEqual(EffectKind.unicode_version, vm.effect_log.items[2].kind);
        try testing.expectEqual(EffectKind.file_read, vm.effect_log.items[3].kind);
        log_bytes = try effectser.encodeFile(gpa, vm.effect_log.items);
    }
    defer gpa.free(log_bytes);

    // Replay commits the identical four events with all host sources detached.
    // Re-entering the already-consumed Unicode pin models snapshot resume: no
    // new log entry is consumed, so the logical commit counter must not move.
    {
        var vm = try Vm.init(gpa);
        defer vm.deinit();
        var out_buf: [256]u8 = undefined;
        var sink = io.Writer.fixed(&out_buf);
        vm.out = &sink;
        const log = try effectser.decodeFile(gpa, vm.heap, log_bytes);
        defer gpa.free(log);
        try vm.effect_log.appendSlice(gpa, log);
        vm.effect_mode = .replay;
        try compileRun(gpa, &vm, source);
        try testing.expectEqual(@as(u64, 4), vm.committed_effect_seq);
        try testing.expectEqual(vm.effect_log.items.len, vm.effect_cursor);
        vm.unicode_version_pinned = false;
        try noteUnicodeVersion(&vm);
        try testing.expectEqual(@as(u64, 4), vm.committed_effect_seq);
        try testing.expectEqual(vm.effect_log.items.len, vm.effect_cursor);
    }

    // A host failure occurs before commitment and leaves the counter untouched.
    {
        var vm = try Vm.init(gpa);
        defer vm.deinit();
        try testing.expectError(error.ClockUnavailable, compileRun(gpa, &vm,
            \\local t = os.clock()
        ));
        try testing.expectEqual(@as(u64, 0), vm.committed_effect_seq);
    }
}

test "L-3: loadfile reads + compiles a file via the file_read effect (record)" {
    const gpa = testing.allocator;
    var ffs = FakeFs{ .entries = &.{
        .{ .path = "lib.lua", .content = "return 6 * 7" },
    } };
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var sink_buf: [128]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    vm.out = &sink;
    vm.effect_mode = .record;
    vm.fs_source = ffs.source();

    try compileRun(gpa, &vm,
        \\local f = loadfile("lib.lua")
        \\print(f())
    );
    try testing.expectEqualStrings("42\n", sink.buffered());
    // Exactly one file_read effect logged (the single loadfile read).
    try testing.expectEqual(@as(usize, 1), vm.effect_log.items.len);
    try testing.expectEqual(EffectKind.file_read, vm.effect_log.items[0].kind);
}

test "L-3: dofile runs the file and returns its results (record)" {
    const gpa = testing.allocator;
    var ffs = FakeFs{ .entries = &.{
        .{ .path = "answer.lua", .content = "local a, b = ...\nreturn 40 + 2, 'ok'" },
    } };
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var sink_buf: [128]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    vm.out = &sink;
    vm.effect_mode = .record;
    vm.fs_source = ffs.source();

    try compileRun(gpa, &vm,
        \\print(dofile("answer.lua"))
    );
    // dofile runs the chunk with no args; the chunk returns two values.
    try testing.expectEqualStrings("42\tok\n", sink.buffered());
}

test "L-3: record→serialize→replay reproduces output with the FS detached" {
    const gpa = testing.allocator;
    const effectser = @import("effectser.zig");
    // `add.lua` is a vararg chunk loaded by `loadfile` and then called with args;
    // `const.lua` is run directly by `dofile`. Two distinct file_read effects.
    var ffs = FakeFs{ .entries = &.{
        .{ .path = "add.lua", .content = "local a, b = ...\nreturn a + b" },
        .{ .path = "const.lua", .content = "return 100" },
    } };
    const driver: [:0]const u8 =
        \\print(loadfile("add.lua")(3, 4))
        \\print(dofile("const.lua"))
    ;

    // --- record: run against the in-memory FS, capture output + serialized log ---
    var rec_out_buf: [128]u8 = undefined;
    var log_bytes: []u8 = undefined;
    {
        var vm = try Vm.init(gpa);
        defer vm.deinit();
        var sink = io.Writer.fixed(&rec_out_buf);
        vm.out = &sink;
        vm.effect_mode = .record;
        vm.fs_source = ffs.source();
        try compileRun(gpa, &vm, driver);
        // Two file reads (loadfile + dofile), both file_read effects.
        try testing.expectEqual(@as(usize, 2), vm.effect_log.items.len);
        try testing.expectEqual(EffectKind.file_read, vm.effect_log.items[0].kind);
        try testing.expectEqual(EffectKind.file_read, vm.effect_log.items[1].kind);
        log_bytes = try effectser.encodeFile(gpa, vm.effect_log.items);
    }
    defer gpa.free(log_bytes);

    // --- replay: a fresh VM with NO fs_source. The serialized log is decoded into
    // its heap and fed back; if any read reached for disk it would be FsUnavailable
    // (no source) — so byte-identical output proves the content came from the log. ---
    var rep_out_buf: [128]u8 = undefined;
    {
        var vm = try Vm.init(gpa);
        defer vm.deinit();
        var sink = io.Writer.fixed(&rep_out_buf);
        vm.out = &sink;
        const log = try effectser.decodeFile(gpa, vm.heap, log_bytes);
        defer gpa.free(log);
        try vm.effect_log.appendSlice(gpa, log);
        vm.effect_mode = .replay;
        // No fs_source set on purpose.
        try compileRun(gpa, &vm, driver);
    }
    // loadfile("add.lua")(3,4) = 7; dofile("const.lua") = 100.
    try testing.expectEqualStrings("7\n100\n", rep_out_buf[0..6]);
    // Record and replay produced byte-identical output.
    try testing.expectEqualStrings(rep_out_buf[0..6], rec_out_buf[0..6]);
}

test "L-3: loadfile of a missing file is (nil, msg); dofile raises" {
    const gpa = testing.allocator;
    var ffs = FakeFs{ .entries = &.{} }; // empty FS: every path is missing
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var sink_buf: [256]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    vm.out = &sink;
    vm.effect_mode = .record;
    vm.fs_source = ffs.source();

    try compileRun(gpa, &vm,
        \\local f, e = loadfile("nope.lua")
        \\print(f, e)
        \\local ok, err = pcall(dofile, "nope.lua")
        \\print(ok, err)
    );
    // loadfile → (nil, "cannot open nope.lua"); dofile raises the same message,
    // caught by pcall as (false, msg). The message is a function of the path only
    // (no host errno), so it is deterministic.
    try testing.expectEqualStrings(
        "nil\tcannot open nope.lua\nfalse\tcannot open nope.lua\n",
        sink.buffered(),
    );
}

test "L-3: loadfile/dofile with no fs_source injected is FsUnavailable" {
    const gpa = testing.allocator;
    inline for (.{ "loadfile(\"x.lua\")", "dofile(\"x.lua\")" }) |s| {
        var vm = try Vm.init(gpa);
        defer vm.deinit();
        vm.effect_mode = .record; // no fs_source set
        try testing.expectError(error.FsUnavailable, compileRun(gpa, &vm, s));
    }
}

test "L-3: a non-string path argument is a bad-argument error" {
    const gpa = testing.allocator;
    var ffs = FakeFs{ .entries = &.{} };
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    vm.effect_mode = .record;
    vm.fs_source = ffs.source();
    // A numeric path raises `bad argument` (raised, not (nil,msg)) — matching Lua.
    try testing.expectError(error.LuaError, compileRun(gpa, &vm, "loadfile(42)"));
}
