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
const effectser = @import("effectser.zig");
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

/// A deterministic host environment for `os.getenv`, so tests don't depend on
/// the real process. `HOME` is set, `EMPTY` is set-but-empty (to exercise the
/// ""-vs-unset distinction), and every other name is unset (→ nil).
const FakeEnv = struct {
    home: []const u8 = "/home/bart",
    fn getenvFn(ctx: *anyopaque, name: []const u8) ?[]const u8 {
        const self: *FakeEnv = @ptrCast(@alignCast(ctx));
        if (std.mem.eql(u8, name, "HOME")) return self.home;
        if (std.mem.eql(u8, name, "EMPTY")) return ""; // set, but empty — not nil
        if (std.mem.eql(u8, name, "BADUTF8")) return "\xFF\xFE"; // not valid UTF-8 (S-B boundary)
        return null;
    }
    const vtable: interp.HostSystem.VTable = .{ .getenv = &FakeEnv.getenvFn };
    /// Make this the VM's host system and install the env group (`os.getenv`).
    fn install(self: *FakeEnv, vm: *Vm) !void {
        vm.system = .{ .ctx = self, .vtable = &vtable };
        try vm.enableSystem(.{ .env = true });
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
    // Every program here may read the clock; the group is installed even when
    // no source is (a replay, or the `ClockUnavailable` test).
    try vm.enableSystem(.{ .clock = true });
    if (clock) |c| vm.setClockSource(c.source());
    if (seed) |s| vm.random_seed_source = s.source();
    if (preload.len > 0) try vm.effect_log.entries.appendSlice(gpa, preload);

    var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());

    _ = try vm.run(chunk.proto);
    return .{
        .out = try gpa.dupe(u8, sink.buffered()),
        .log = try gpa.dupe(Effect, vm.effect_log.entries.items),
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

    // A second record against a clock that ADVANCES differently (steps of 7 ns)
    // genuinely differs — modelling the nondeterminism a real clock has between
    // runs, which is exactly what the log captures. (With injection the clock is
    // deterministic, so we vary it explicitly rather than leaning on wall-clock
    // advance. Only the rate shows: `os.clock` counts from the VM's first
    // reading, so a different starting value alone would print the same.)
    var clk2 = CounterClock{ .next = 9000, .step = 7 };
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
    const short = [_]Effect{Effect.of(.clock, Value.int(123))};
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

test "F2d: os.clock is float seconds, os.nsclock is int nanoseconds, both from the VM's zero" {
    const gpa = testing.allocator;
    // The clock starts at 7 s and advances 2.5 s per read. Installing it takes the
    // first reading as the VM's zero, so the program's reads are 2.5 s and 5 s
    // after it, not the source's absolute 9.5 s and 12 s. os.clock divides to a
    // float; os.nsclock hands back the integer nanoseconds.
    var clk = CounterClock{ .next = 7_000_000_000, .step = 2_500_000_000 };
    const run = try effectRun(gpa,
        \\print(os.clock() == 2.5)
        \\print(os.nsclock() == 5000000000)
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
    try testing.expectEqualStrings("mahina warning: abc\n", r.err);
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
    try testing.expectEqualStrings("mahina warning: one\nmahina warning: three\n", r.err);
}

test "warn: unknown @control is ignored (system stays on, no line emitted for it)" {
    var ob: [256]u8 = undefined;
    var eb: [256]u8 = undefined;
    const r = try runOutErr(testing.allocator,
        \\warn("@frobnicate")
        \\warn("still on")
    , &ob, &eb);
    try testing.expectEqualStrings("mahina warning: still on\n", r.err);
}

test "warn: a leading-@ piece is only a control message when it is the sole arg" {
    var ob: [256]u8 = undefined;
    var eb: [256]u8 = undefined;
    const r = try runOutErr(testing.allocator,
        \\warn("@x", "y")
    , &ob, &eb);
    // Two pieces → not a control message → emitted verbatim (concatenated).
    try testing.expectEqualStrings("mahina warning: @xy\n", r.err);
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

test "doc 65 Q4: math.random() with no injected source starts from the fixed default seed" {
    const gpa = testing.allocator;
    // No entropy source: the VM is deterministic. The default seed is still
    // logged, so a replay needs no source either.
    const a = try effectRun(gpa, "print(math.random(1, 1000000))", .record, &.{}, null, null);
    defer a.deinit(gpa);
    const b = try effectRun(gpa, "print(math.random(1, 1000000))", .record, &.{}, null, null);
    defer b.deinit(gpa);
    try testing.expectEqualStrings(a.out, b.out);
    try testing.expectEqual(@as(usize, 1), a.log.len);
    try testing.expectEqual(EffectKind.random_seed, a.log[0].kind);
    try testing.expectEqual(@as(i64, @bitCast(interp.default_random_seed)), a.log[0].result.value.asInt());
    const rep = try effectRun(gpa, "print(math.random(1, 1000000))", .replay, a.log, null, null);
    defer rep.deinit(gpa);
    try testing.expectEqualStrings(a.out, rep.out);
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
    try testing.expectEqual(@as(usize, 0), vm.effect_log.entries.items.len);
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

test "doc 65 Q4: math.randomseed() with no injected source uses the default seed" {
    const gpa = testing.allocator;
    // The no-arg entropy form draws like a lazy random(): the default seed.
    const r = try effectRun(gpa, "print(math.randomseed())", .record, &.{}, null, null);
    defer r.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), r.log.len);
    try testing.expectEqual(@as(i64, @bitCast(interp.default_random_seed)), r.log[0].result.value.asInt());
}

// ---------------------------------------------------------------------------
// env effect — `os.getenv` as a nondeterministic input. The first effect whose
// result is a heap *string*, so it exercises (a) the value semantics (set vs
// unset vs empty), (b) the replay feed-back of a string result, and (c) the
// GC-root that keeps a parked string result alive across a collection. The cross-run *byte* equivalence (serialize
// → replay) is proven in `effectser`'s round-trip test, where a standalone
// effect-log blob sidesteps cross-heap string lifetimes.
// ---------------------------------------------------------------------------

test "env: os.getenv reads set/unset/empty (record)" {
    const gpa = testing.allocator;
    var fenv = FakeEnv{};
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var sink_buf: [512]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    vm.out = &sink;
    vm.effect_mode = .record;
    try fenv.install(&vm);

    try compileRun(gpa, &vm,
        \\print(os.getenv("HOME"))
        \\print(os.getenv("MISSING"))
        \\print(os.getenv("EMPTY") == "")
        \\print(pcall(os.getenv, 1))
    );
    // HOME set; MISSING → nil; EMPTY is set-but-empty (== "" is true, not nil);
    // a non-string name is a bad argument, raised before any effect is logged.
    try testing.expectEqualStrings(
        "/home/bart\nnil\ntrue\nfalse\tbad argument #1 to 'os.getenv' (string expected, got number)\n",
        sink.buffered(),
    );
    // One effect logged per successful call.
    try testing.expectEqual(@as(usize, 3), vm.effect_log.entries.items.len);
    for (vm.effect_log.entries.items) |it| try testing.expectEqual(EffectKind.getenv, it.kind);
}

test "doc 65 Q5: without the env group, os.getenv is absent and nothing is unavailable" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var sink_buf: [256]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    vm.out = &sink;
    vm.effect_mode = .record;
    // No host system, no groups: the env functions aren't installed, the bare
    // `getenv`/`argc`/`argv` globals are gone (Q3), and file loads miss.
    try compileRun(gpa, &vm,
        \\print(os.getenv, os.clock, getenv, argc, argv)
        \\print(loadfile("x.lua"))
        \\print(pcall(dofile, "x.lua"))
    );
    try testing.expectEqualStrings(
        "nil\tnil\tnil\tnil\tnil\nnil\tcannot open x.lua\nfalse\tcannot open x.lua\n",
        sink.buffered(),
    );
}

test "env: a recorded string result survives a GC collection while parked in the log" {
    const gpa = testing.allocator;
    var fenv = FakeEnv{};
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    vm.effect_mode = .record;
    try fenv.install(&vm);

    // Read HOME but discard the result — nothing references the string except the
    // effect log. A collection would de-intern + free it without the new root.
    try compileRun(gpa, &vm, "os.getenv(\"HOME\")");
    try testing.expectEqual(@as(usize, 1), vm.effect_log.entries.items.len);

    vm.collect(); // force a stop-the-world sweep

    // The logged result must still be a live string reading "/home/bart".
    const res = vm.effect_log.entries.items[0].result.value;
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
    // host system: getenv is not called — the logged string is fed back.
    try vm.enableSystem(.{ .env = true });
    const logged = try vm.heap.internValue("REPLAYED");
    try vm.effect_log.append(gpa, Effect.of(.getenv, logged));
    vm.effect_mode = .replay;

    try compileRun(gpa, &vm, "print(os.getenv(\"IGNORED\"))");
    try testing.expectEqualStrings("REPLAYED\n", sink.buffered());
}

test "S-B: getenv of non-UTF-8 host bytes raises a catchable error" {
    const gpa = testing.allocator;
    var fenv = FakeEnv{};
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var sink_buf: [512]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    vm.out = &sink;
    vm.effect_mode = .record;
    try fenv.install(&vm);

    try compileRun(gpa, &vm,
        \\print(os.getenv("HOME"))                 -- valid: still works
        \\local ok, e = pcall(os.getenv, "BADUTF8")  -- invalid env value → catchable error
        \\print(ok, type(e))
    );
    // A valid read passes through; the invalid read raises a string error value.
    try testing.expectEqualStrings("/home/bart\nfalse\tstring\n", sink.buffered());
}

test "S-B: a recorded non-UTF-8 getenv replays byte-identically (validate-after-log)" {
    const gpa = testing.allocator;
    const src =
        \\local ok, e = pcall(os.getenv, "BADUTF8")
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
    try fenv.install(&vm);
    try compileRun(gpa, &vm, src);
    const recorded = rec_sink.buffered();
    try testing.expectEqualStrings("false\tstring\n", recorded);
    // Exactly one getenv effect logged, holding the raw invalid bytes.
    try testing.expectEqual(@as(usize, 1), vm.effect_log.entries.items.len);
    try testing.expectEqual(EffectKind.getenv, vm.effect_log.entries.items[0].kind);

    // Replay the same VM's log (string result lives in this heap) with no host
    // system: the native is not called, the logged bytes are re-validated → same
    // raise, same caught error, byte-identical output.
    vm.effect_mode = .replay;
    vm.effect_cursor = 0;
    vm.system = null;
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
    vm.system = ffs.system();

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
    vm.system = ffs.system();
    try compileRun(gpa, &vm, src);
    const recorded = rec_sink.buffered();
    try testing.expectEqualStrings("false\tstring\n", recorded);
    // Exactly one file_read effect logged, holding the raw invalid bytes.
    try testing.expectEqual(@as(usize, 1), vm.effect_log.entries.items.len);
    try testing.expectEqual(EffectKind.file_read, vm.effect_log.entries.items[0].kind);

    // Replay the same VM's log with no fs_source:
    // the logged bytes are re-validated -> same raise, same caught error, byte-identical output.
    vm.effect_mode = .replay;
    vm.effect_cursor = 0;
    vm.system = null;
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
    try testing.expectEqual(@as(usize, 1), vm.effect_log.entries.items.len);
    try testing.expectEqual(EffectKind.unicode_version, vm.effect_log.entries.items[0].kind);

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
    try vm.effect_log.append(gpa, Effect.of(.unicode_version, Value.int(0xDEAD)));
    // Even wrapped in pcall, the mismatch is a determinism fault: NOT catchable.
    try testing.expectError(error.UnicodeVersionMismatch, compileRun(gpa, &vm,
        \\print(pcall(string.upper, "x"))
    ));
}

test "S-C: a unicode_version log entry with a non-int (float) result is rejected, not asserted" {
    // The decoder accepts only an int here, but an in-memory log can still
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
    try vm.effect_log.append(gpa, Effect.of(.unicode_version, Value.float(16.0)));
    try testing.expectError(error.UnicodeVersionMismatch, compileRun(gpa, &vm,
        \\print(pcall(string.lower, "X"))
    ));
    // Validate-before-advance: the rejected (unreadable-version) entry was NOT
    // consumed and no pin happened.
    try testing.expectEqual(@as(usize, 0), vm.effect_cursor);
    try testing.expect(!vm.unicode_version_pinned);
}

test "S-C: a wrong-version pin is not self-erasing — the rejected entry stays at the cursor and a retry re-raises" {
    // The doc-26 TODO regression. `nextLoggedEffect` used to advance the
    // cursor BEFORE validation, so after a (fatal, uncatchable)
    // `UnicodeVersionMismatch` the wrong-version entry sat BEHIND the cursor
    // with `unicode_version_pinned` still false; a host re-running the
    // faulted-but-live VM then hit `versionAlreadyConsumed`'s prefix scan and
    // SILENTLY pinned the mismatched table — the exact divergence the error
    // exists to prevent. Under validate-before-advance the entry stays in
    // front of the cursor, so the retry re-validates and re-raises, forever.
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var sink_buf: [128]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    vm.out = &sink;
    vm.effect_mode = .replay;
    try vm.effect_log.append(gpa, Effect.of(.unicode_version, Value.int(0xDEAD)));
    const src =
        \\print(pcall(string.upper, "x"))
    ;
    try testing.expectError(error.UnicodeVersionMismatch, compileRun(gpa, &vm, src));
    try testing.expectEqual(@as(usize, 0), vm.effect_cursor);
    try testing.expect(!vm.unicode_version_pinned);
    // The composed-bug leg. NB (found writing this test): a top-level re-`run`
    // of the faulted VM is ALREADY refused fail-closed by beginTopLevelEpoch
    // (`DirtyTopLevelEntry`, depth != 0) — that road to the silent pin is
    // shut. The seam that remains is any later `noteUnicodeVersion` on the
    // same VM (a host driving calls directly, or a resumed session): pre-fix
    // it found the wrong-version entry BEHIND the cursor, took the
    // `versionAlreadyConsumed` path, and silently pinned the mismatched
    // table; now it re-validates the un-consumed entry and re-raises.
    try testing.expectError(error.UnicodeVersionMismatch, noteUnicodeVersion(&vm));
    try testing.expectEqual(@as(usize, 0), vm.effect_cursor);
    try testing.expect(!vm.unicode_version_pinned);
}

test "replay: a kind-diverged log entry is not consumed — the cursor stays put on EffectKindMismatch" {
    // The same cursor-truthfulness contract at the generic `nextLoggedEffect`
    // level: the log's next entry is a .unicode_version but the program's next
    // effect is a clock read. The divergence raises, and the unconsumed entry
    // stays in front of the cursor rather than being silently skipped.
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var sink_buf: [128]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    vm.out = &sink;
    vm.effect_mode = .replay;
    try vm.enableSystem(.{ .clock = true });
    try vm.effect_log.append(gpa, Effect.of(.unicode_version, Value.int(1)));
    try testing.expectError(error.EffectKindMismatch, compileRun(gpa, &vm,
        \\print(os.clock())
    ));
    try testing.expectEqual(@as(usize, 0), vm.effect_cursor);
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
// content rides the record/replay boundary exactly like `os.getenv`: a heap
// string (or nil) logged on record, fed back on replay (the path is plain program
// data — only the content is the effect). These tests prove (1) `loadfile`/`dofile`
// work against an injected FS, (2) a record→serialize→replay round-trip reproduces
// the output with the FS DETACHED on replay (so the content provably came from the
// log, not disk), (3) a missing file is `(nil, msg)` for `loadfile` and a *raise*
// for `dofile`, and (4) with no host system a load finds no file (`cannot open`).
// ---------------------------------------------------------------------------

test "A-vi: committed effect sequence is mode-independent across all four commit families" {
    const gpa = testing.allocator;
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
        try vm.enableSystem(.{ .clock = true });
        var out_buf: [256]u8 = undefined;
        var sink = io.Writer.fixed(&out_buf);
        vm.out = &sink;
        vm.setClockSource(clock.source());
        vm.random_seed_source = seed.source();
        vm.system = ffs.system();
        try compileRun(gpa, &vm, source);
        try testing.expectEqual(@as(u64, 4), vm.committed_effect_seq);
        try testing.expectEqual(@as(usize, 0), vm.effect_log.entries.items.len);
    }

    // Record produces clock, random_seed, unicode_version, file_read in order.
    var log_bytes: []u8 = undefined;
    {
        var clock = CounterClock{ .next = 1000 };
        var seed = FixedSeed{ .value = 0x1234 };
        var vm = try Vm.init(gpa);
        defer vm.deinit();
        try vm.enableSystem(.{ .clock = true });
        var out_buf: [256]u8 = undefined;
        var sink = io.Writer.fixed(&out_buf);
        vm.out = &sink;
        vm.effect_mode = .record;
        vm.setClockSource(clock.source());
        vm.random_seed_source = seed.source();
        vm.system = ffs.system();
        try compileRun(gpa, &vm, source);
        try testing.expectEqual(@as(u64, 4), vm.committed_effect_seq);
        try testing.expectEqual(@as(usize, 4), vm.effect_log.entries.items.len);
        try testing.expectEqual(EffectKind.clock, vm.effect_log.entries.items[0].kind);
        try testing.expectEqual(EffectKind.random_seed, vm.effect_log.entries.items[1].kind);
        try testing.expectEqual(EffectKind.unicode_version, vm.effect_log.entries.items[2].kind);
        try testing.expectEqual(EffectKind.file_read, vm.effect_log.entries.items[3].kind);
        log_bytes = try effectser.encodeFile(gpa, &vm.effect_log);
    }
    defer gpa.free(log_bytes);

    // Replay commits the identical four events with all host sources detached.
    // Re-entering the already-consumed Unicode pin models snapshot resume: no
    // new log entry is consumed, so the logical commit counter must not move.
    {
        var vm = try Vm.init(gpa);
        defer vm.deinit();
        try vm.enableSystem(.{ .clock = true });
        var out_buf: [256]u8 = undefined;
        var sink = io.Writer.fixed(&out_buf);
        vm.out = &sink;
        try effectser.decodeInto(&vm.effect_log, gpa, vm.heap, log_bytes);
        vm.effect_mode = .replay;
        try compileRun(gpa, &vm, source);
        try testing.expectEqual(@as(u64, 4), vm.committed_effect_seq);
        try testing.expectEqual(vm.effect_log.entries.items.len, vm.effect_cursor);
        vm.unicode_version_pinned = false;
        try noteUnicodeVersion(&vm);
        try testing.expectEqual(@as(u64, 4), vm.committed_effect_seq);
        try testing.expectEqual(vm.effect_log.entries.items.len, vm.effect_cursor);
    }

    // A host failure occurs before commitment and leaves the counter untouched.
    {
        var vm = try Vm.init(gpa);
        defer vm.deinit();
        try vm.enableSystem(.{ .clock = true });
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
    vm.system = ffs.system();

    try compileRun(gpa, &vm,
        \\local f = loadfile("lib.lua")
        \\print(f())
    );
    try testing.expectEqualStrings("42\n", sink.buffered());
    // Exactly one file_read effect logged (the single loadfile read).
    try testing.expectEqual(@as(usize, 1), vm.effect_log.entries.items.len);
    try testing.expectEqual(EffectKind.file_read, vm.effect_log.entries.items[0].kind);
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
    vm.system = ffs.system();

    try compileRun(gpa, &vm,
        \\print(dofile("answer.lua"))
    );
    // dofile runs the chunk with no args; the chunk returns two values.
    try testing.expectEqualStrings("42\tok\n", sink.buffered());
}

test "doc 68 §7.3: a dofile'd chunk runs as an activation: it yields, and all its results pass" {
    const gpa = testing.allocator;
    var ffs = FakeFs{ .entries = &.{
        .{ .path = "y.lua", .content = "local v = coroutine.yield(1)\nreturn v, 'done', nil" },
        .{ .path = "none.lua", .content = "" },
        .{ .path = "boom.lua", .content = "error('boom', 0)" },
    } };
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var sink_buf: [256]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    vm.out = &sink;
    vm.effect_mode = .record;
    vm.system = ffs.system();

    try compileRun(gpa, &vm,
        \\local co = coroutine.wrap(function() return dofile("y.lua") end)
        \\print(co())
        \\print(co(7))
        \\print(select('#', dofile("none.lua")))
        \\print(pcall(dofile, "none.lua"))
        \\print(pcall(dofile, "boom.lua"))
        \\print(pcall(function() return dofile("boom.lua") end))
        \\print(select('#', pcall(dofile, "y.lua")))
    );
    // `pcall(dofile, …)` runs the chunk through `callValue`, where `yield`
    // is an error: the last line counts `false` and its message.
    try testing.expectEqualStrings("1\n7\tdone\tnil\n0\ntrue\nfalse\tboom\nfalse\tboom\n2\n", sink.buffered());
}

test "L-3: record→serialize→replay reproduces output with the FS detached" {
    const gpa = testing.allocator;
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
        vm.system = ffs.system();
        try compileRun(gpa, &vm, driver);
        // Two file reads (loadfile + dofile), both file_read effects.
        try testing.expectEqual(@as(usize, 2), vm.effect_log.entries.items.len);
        try testing.expectEqual(EffectKind.file_read, vm.effect_log.entries.items[0].kind);
        try testing.expectEqual(EffectKind.file_read, vm.effect_log.entries.items[1].kind);
        log_bytes = try effectser.encodeFile(gpa, &vm.effect_log);
    }
    defer gpa.free(log_bytes);

    // --- replay: a fresh VM with NO host system. The serialized log is decoded
    // into its heap and fed back; a read that reached for the host would find no
    // file — so byte-identical output proves the content came from the log. ---
    var rep_out_buf: [128]u8 = undefined;
    {
        var vm = try Vm.init(gpa);
        defer vm.deinit();
        var sink = io.Writer.fixed(&rep_out_buf);
        vm.out = &sink;
        try effectser.decodeInto(&vm.effect_log, gpa, vm.heap, log_bytes);
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
    vm.system = ffs.system();

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

test "L-3: a non-string path argument is a bad-argument error" {
    const gpa = testing.allocator;
    var ffs = FakeFs{ .entries = &.{} };
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    vm.effect_mode = .record;
    vm.system = ffs.system();
    // A numeric path raises `bad argument` (raised, not (nil,msg)) — matching Lua.
    try testing.expectError(error.LuaError, compileRun(gpa, &vm, "loadfile(42)"));
}

// Multi-file locations: a fault, its backtrace frames and the replay line index
// each carry the proto id of their line, and `loadedChunkIndexOf` turns that id
// into the chunk (so the file) it was compiled from — the static chunk's ids map
// to null.
test "multi-file: fault, frames and safepoint lines name the chunk their line is in" {
    const gpa = testing.allocator;
    const parser = @import("parser.zig");
    const diag = @import("diag.zig");
    const source: [:0]const u8 =
        \\local m = require("mod")
        \\local t = {}
        \\m.f(t)
    ;
    var ffs = FakeFs{ .entries = &.{
        .{ .path = "./mod.mah", .content = "local M = {}\nfunction M.f(x)\n  return x.y + 1\nend\nreturn M\n" },
    } };

    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var diags = diag.Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();
    var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();

    vm.system = ffs.system();
    vm.setRecordSafepointLines(true);
    try testing.expectError(error.TypeError, vm.run(chunk.proto));

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const fault = try vm.describeFault(error.TypeError, arena.allocator());
    // The leaf is line 3 of mod.mah, the one loaded chunk.
    try testing.expectEqual(@as(u32, 3), fault.line);
    try testing.expectEqual(@as(?usize, 0), vm.loadedChunkIndexOf(fault.proto_id));
    try testing.expectEqualStrings("./mod.mah", vm.loaded_chunks.items[0].chunk.proto.name);
    // Frames: the leaf in mod.mah, then the call site on line 3 of the script.
    try testing.expectEqual(@as(usize, 2), fault.frames.len);
    try testing.expectEqual(fault.proto_id, fault.frames[0].proto_id);
    try testing.expectEqual(@as(?usize, null), vm.loadedChunkIndexOf(fault.frames[1].proto_id));
    try testing.expectEqual(@as(u32, 3), fault.frames[1].line);

    // The replay index names the chunk of every line, and both files appear.
    var saw_static = false;
    var saw_mod_line3 = false;
    for (vm.safepoint_lines.items) |sp| {
        if (vm.loadedChunkIndexOf(sp.proto_id)) |_| {
            if (sp.line == 3) saw_mod_line3 = true;
        } else saw_static = true;
    }
    try testing.expect(saw_static and saw_mod_line3);
}

// ---------------------------------------------------------------------------
// Doc 65 Phase 2 — the effect log for host operations: the recording cap, the
// pinned io error mode, and fail/bytes results through record and replay.

test "doc 65 §4.5: a recording past the effect-log limit is fatal, uncatchable, and names the limit" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var sink_buf: [256]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    vm.out = &sink;
    var env: FakeEnv = .{};
    try env.install(&vm);
    vm.effect_mode = .record;
    // A nil getenv result encodes as 3 bytes (kind, tag, pad): room for three.
    const limit = effectser.file_header_size + 3 * 3;
    vm.effect_log_limit = limit;
    const err = compileRun(gpa, &vm,
        \\for i = 1, 10 do print(pcall(os.getenv, "UNSET")) end
    );
    try testing.expectError(error.EffectLogLimit, err);
    try testing.expect(!interp.catchable(error.EffectLogLimit));
    // The entries before the cap are all there, none dropped, none past it.
    try testing.expectEqual(@as(usize, 3), vm.effect_log.len());
    try testing.expectEqual(limit, vm.effect_log_encoded);
    try testing.expectEqualStrings("true\tnil\ntrue\tnil\ntrue\tnil\n", sink.buffered());
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const fault = try vm.describeFault(error.EffectLogLimit, arena.allocator());
    try testing.expect(std.mem.indexOf(u8, fault.message, "limit of 17 bytes") != null);
    try testing.expect(std.mem.indexOf(u8, fault.message, "--effect-log-limit") != null);
}

test "doc 65 §4.5: the cap counts what encodeFile writes, and 0 or off mode means none" {
    const gpa = testing.allocator;
    const src =
        \\for i = 1, 50 do os.getenv("HOME") end
    ;
    // Record with no cap: the counter equals the encoded file's size.
    {
        var vm = try Vm.init(gpa);
        defer vm.deinit();
        var env: FakeEnv = .{};
        try env.install(&vm);
        vm.effect_mode = .record;
        vm.effect_log_limit = 0;
        try compileRun(gpa, &vm, src);
        try testing.expectEqual(@as(usize, 50), vm.effect_log.len());
        const bytes = try effectser.encodeFile(gpa, &vm.effect_log);
        defer gpa.free(bytes);
        try testing.expectEqual(bytes.len, vm.effect_log_encoded);
    }
    // Off mode logs nothing, so a tiny cap never trips.
    {
        var vm = try Vm.init(gpa);
        defer vm.deinit();
        var env: FakeEnv = .{};
        try env.install(&vm);
        vm.effect_log_limit = 1;
        try compileRun(gpa, &vm, src);
        try testing.expectEqual(@as(usize, 0), vm.effect_log.len());
    }
}

test "doc 65 §4.4: the io error mode is pinned once per session in record" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    vm.effect_mode = .record;
    vm.io_errors = .lua;
    try interp.noteIoErrorMode(&vm);
    try interp.noteIoErrorMode(&vm);
    try testing.expectEqual(@as(usize, 1), vm.effect_log.len());
    const e = vm.effect_log.entries.items[0];
    try testing.expectEqual(EffectKind.io_error_mode, e.kind);
    try testing.expectEqual(@as(i64, 1), e.result.value.asInt());
    try testing.expectEqual(@as(u64, 1), vm.committed_effect_seq);
}

test "doc 65 §4.4: a replay under the other io error mode refuses, and the entry stays at the cursor" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    vm.effect_mode = .replay;
    vm.io_errors = .raise;
    try vm.effect_log.append(gpa, Effect.of(.io_error_mode, Value.int(1)));
    try testing.expectError(error.IoErrorModeMismatch, interp.noteIoErrorMode(&vm));
    try testing.expectError(error.IoErrorModeMismatch, interp.noteIoErrorMode(&vm));
    try testing.expectEqual(@as(usize, 0), vm.effect_cursor);
    try testing.expect(!vm.io_errors_pinned);
    try testing.expect(!interp.catchable(error.IoErrorModeMismatch));
    // Under the recorded mode it is consumed once.
    vm.io_errors = .lua;
    try interp.noteIoErrorMode(&vm);
    try interp.noteIoErrorMode(&vm);
    try testing.expectEqual(@as(usize, 1), vm.effect_cursor);
    try testing.expect(vm.io_errors_pinned);
}

test "doc 65 §4.4: a resumed replay does not consume a second io error mode pin" {
    // The keyframe carries no pinned flag: after a restore the pin before the
    // cut is found behind the cursor, as for `unicode_version`.
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    vm.effect_mode = .replay;
    try vm.effect_log.append(gpa, Effect.of(.io_error_mode, Value.int(0)));
    try vm.effect_log.append(gpa, Effect.of(.file_seek, Value.int(9)));
    vm.effect_cursor = 1;
    try interp.noteIoErrorMode(&vm);
    try testing.expectEqual(@as(usize, 1), vm.effect_cursor);
    try testing.expectEqual(@as(i64, 9), (try interp.replayHost(&vm, .file_seek)).value.asInt());
}

test "doc 65 §4.2: host results — values, failures and bytes — record, encode and replay" {
    const gpa = testing.allocator;
    var log_bytes: []u8 = undefined;
    {
        var vm = try Vm.init(gpa);
        defer vm.deinit();
        vm.effect_mode = .record;
        try interp.noteIoErrorMode(&vm);
        try interp.recordHost(&vm, .file_open, .{ .value = Value.int(3) });
        try interp.recordHost(&vm, .file_open, .{ .fail = .not_found });
        var buf = [_]u8{ 0xff, 0x00, 0x80 };
        try interp.recordHostBytes(&vm, .file_read_op, &buf);
        buf[0] = 0; // the log holds its own copy
        try interp.recordHost(&vm, .file_read_op, .{ .value = try vm.heap.internValue("línea") });
        try interp.recordHost(&vm, .file_write, .{ .value = Value.nil() });
        try testing.expectEqual(@as(u64, 6), vm.committed_effect_seq);
        log_bytes = try effectser.encodeFile(gpa, &vm.effect_log);
        try testing.expectEqual(log_bytes.len, vm.effect_log_encoded);
    }
    defer gpa.free(log_bytes);
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    try effectser.decodeInto(&vm.effect_log, gpa, vm.heap, log_bytes);
    vm.effect_mode = .replay;
    try interp.noteIoErrorMode(&vm);
    try testing.expectEqual(@as(i64, 3), (try interp.replayHost(&vm, .file_open)).value.asInt());
    try testing.expectEqual(@import("system.zig").ErrorClass.not_found, (try interp.replayHost(&vm, .file_open)).fail);
    const raw = try interp.replayHost(&vm, .file_read_op);
    try testing.expectEqualSlices(u8, &.{ 0xff, 0x00, 0x80 }, vm.effect_log.bytesOf(raw.bytes));
    const line = (try interp.replayHost(&vm, .file_read_op)).value;
    try testing.expectEqualStrings("línea", string.String.fromHeader(line.asHeap()).bytes());
    // A kind the program did not ask for is refused and left at the cursor.
    try testing.expectError(error.EffectKindMismatch, interp.replayHost(&vm, .file_seek));
    try testing.expect((try interp.replayHost(&vm, .file_write)).value.tag == .nil);
    try testing.expectError(error.EffectLogExhausted, interp.replayHost(&vm, .file_write));
}

test "doc 65 §4.5: a bytes result past the cap is refused and leaves the log as it was" {
    const gpa = testing.allocator;
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    vm.effect_mode = .record;
    vm.effect_log_limit = effectser.file_header_size + 2 + 4 + 15;
    try testing.expectError(error.EffectLogLimit, interp.recordHostBytes(&vm, .file_read_op, "sixteen bytes!!!"));
    try testing.expectEqual(@as(usize, 0), vm.effect_log.len());
    try testing.expectEqual(@as(usize, 0), vm.effect_log.bytes.items.len);
    try interp.recordHostBytes(&vm, .file_read_op, "fifteen bytes!!");
    try testing.expectEqual(vm.effect_log_limit, vm.effect_log_encoded);
}
