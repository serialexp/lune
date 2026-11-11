//! Doc 86 P1 gate: exact resume over the program corpus.
//!
//! Every program under `tests/` (a `.lua` or `.mah` file; `build.zig` embeds
//! them as the `program_corpus` module, so a new program joins without a list
//! to keep) is recorded once, uninterrupted, against a fake clock, a fixed
//! seed and a fake environment. Then, for several cut steps k spread over the run, a VM replays the
//! recording to k and stops, the keyframe captured there is restored into a
//! fresh VM, and that VM replays on to the end. It must match the recording:
//!   (a) the run stopped at the cut (did not run straight through);
//!   (b) capturing the restored VM gives back the keyframe's bytes;
//!   (c) the output before the cut plus the output after it is the
//!       recording's output;
//!   (d) the final snapshot is the recording's, byte for byte (every
//!       counter in `VmState` included, so a resume that counted a step
//!       twice fails here);
//!   (e) the resumed run consumed exactly the recording's effects, in order:
//!       replay refuses an effect of the wrong kind, and the cursor ends at
//!       the end of the log.

const std = @import("std");
const testing = std.testing;
const corpus = @import("program_corpus");
const keyframeser = @import("keyframeser.zig");
const interp = @import("interp.zig");
const compiler = @import("compiler.zig");
const parser = @import("parser.zig");
const io = @import("io.zig");
const Diagnostics = @import("diag.zig").Diagnostics;
const Vm = interp.Vm;
const EffectLog = interp.EffectLog;

/// How many cuts each program is resumed from, spread evenly over its run.
const cuts_per_program = 9;

const system = @import("system.zig");

/// The groups every corpus program gets: the deterministic-under-replay
/// effects a test can fake. `env` gives a program string effects
/// (`os.getenv`), whose entries a replay interns only when it consumes them.
const groups: system.Groups = .{ .clock = true, .random = true, .env = true };

/// The recording's host environment: two variables, every other name unset.
const FakeEnv = struct {
    fn getenv(_: *anyopaque, name: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, name, "HOME")) return "/home/mahina";
        if (std.mem.eql(u8, name, "LANG")) return "C.UTF-8";
        return null;
    }
    const vtable: system.HostSystem.VTable = .{ .getenv = &FakeEnv.getenv };
};

/// A clock that advances a fixed step per reading.
const FakeClock = struct {
    next: i64 = 1_000_000,
    fn nowNs(ctx: *anyopaque) i64 {
        const self: *FakeClock = @ptrCast(@alignCast(ctx));
        const v = self.next;
        self.next += 37_000;
        return v;
    }
};

/// A seed source that always gives the same seed.
const FixedSeed = struct {
    fn seed(_: *anyopaque) u64 {
        return 0x6d61_6869_6e61;
    }
};

/// Room for any corpus program's output.
const out_capacity = 64 * 1024;

const Recording = struct {
    out: []u8,
    final_snap: []u8,
    total_safepoints: u64,
    collections: u64,

    fn deinit(self: Recording, gpa: std.mem.Allocator) void {
        gpa.free(self.out);
        gpa.free(self.final_snap);
    }
};

/// Parse and compile `program` into `vm`'s heap.
fn compileInto(gpa: std.mem.Allocator, vm: *Vm, program: keyframeser.Program.Source, source: [:0]const u8) !compiler.Chunk {
    var diags = Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();
    try testing.expect(!diags.hasErrors());
    const chunk = try compiler.compileWithOptions(gpa, vm.heap, source, tree.root, &diags, program.options);
    try testing.expect(!diags.hasErrors());
    return chunk;
}

/// Attach `vm` to the session's `log` in `mode`.
fn attach(vm: *Vm, log: *EffectLog, mode: interp.EffectMode) void {
    vm.shareEffectLog(log);
    vm.effect_mode = mode;
}

/// Run `source` uninterrupted, recording its effects into `log`.
fn record(gpa: std.mem.Allocator, program: keyframeser.Program.Source, source: [:0]const u8, log: *EffectLog, out_buf: []u8) !Recording {
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var sink = io.Writer.fixed(out_buf);
    vm.out = &sink;
    attach(&vm, log, .record);
    try vm.enableSystem(groups);
    var clock: FakeClock = .{};
    vm.setClockSource(.{ .ctx = &clock, .nowNs = &FakeClock.nowNs });
    var seed_ctx: u8 = 0;
    vm.random_seed_source = .{ .ctx = &seed_ctx, .seed = &FixedSeed.seed };
    var env_ctx: u8 = 0;
    vm.system = .{ .ctx = &env_ctx, .vtable = &FakeEnv.vtable };

    var chunk = try compileInto(gpa, &vm, program, source);
    defer chunk.deinit();
    try testing.expect((try vm.start(chunk.proto)) == .finished);
    return .{
        .out = try gpa.dupe(u8, sink.buffered()),
        .final_snap = try keyframeser.encodeSnapshot(gpa, &vm),
        .total_safepoints = vm.safepoint_seq,
        .collections = vm.heap.collections,
    };
}

/// Replay `source` to `cut`, restore the keyframe captured there, replay on
/// to the end, and check (a)–(e) against `rec`.
fn expectResumeAt(
    gpa: std.mem.Allocator,
    program: keyframeser.Program.Source,
    source: [:0]const u8,
    log: *EffectLog,
    rec: Recording,
    cut: u64,
    out_buf: []u8,
) !void {
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var sink = io.Writer.fixed(out_buf);
    vm.out = &sink;
    attach(&vm, log, .replay);
    try vm.enableSystem(groups);
    var chunk = try compileInto(gpa, &vm, program, source);
    defer chunk.deinit();

    vm.setSuspendCtl(.{ .after_safepoints = cut });
    try testing.expect((try vm.start(chunk.proto)) == .suspended); // (a)
    const before = sink.buffered();
    try testing.expect(std.mem.startsWith(u8, rec.out, before));
    const mid = try keyframeser.encodeSnapshot(gpa, &vm);
    defer gpa.free(mid);

    const vm_r = try keyframeser.restore(gpa, mid, .{ .source = program }, keyframeser.NativeRegistry.base());
    defer {
        vm_r.deinit();
        gpa.destroy(vm_r);
    }
    attach(vm_r, log, .replay);
    {
        const again = try keyframeser.encodeSnapshot(gpa, vm_r);
        defer gpa.free(again);
        try testing.expectEqualSlices(u8, mid, again); // (b)
    }

    var sink_r = io.Writer.fixed(out_buf[before.len..]);
    vm_r.out = &sink_r;
    try testing.expect((try vm_r.exec()) == .finished);
    try testing.expectEqualStrings(rec.out[before.len..], sink_r.buffered()); // (c)

    const final_snap = try keyframeser.encodeSnapshot(gpa, vm_r);
    defer gpa.free(final_snap);
    try testing.expectEqualSlices(u8, rec.final_snap, final_snap); // (d)
    try testing.expectEqual(log.len(), vm_r.effect_cursor); // (e)
}

/// The cut steps for a run of `total` safepoints: `cuts_per_program` of them,
/// strictly inside the run, evenly spread, without repeats.
fn cutAt(total: u64, i: u64) u64 {
    return 1 + (total - 2) * i / (cuts_per_program - 1);
}

test "doc 86 P1: every corpus program resumes exactly from a keyframe at every sampled step" {
    const gpa = testing.allocator;
    try testing.expect(corpus.files.len > 1);
    const out_buf = try gpa.alloc(u8, out_capacity);
    defer gpa.free(out_buf);
    // The gate has to cross a collection somewhere, or it says nothing about
    // the GC schedule a keyframe carries.
    var collections: u64 = 0;
    for (corpus.files) |file| {
        errdefer std.debug.print("corpus program: {s}\n", .{file.path});
        const source = try gpa.dupeSentinel(u8, file.data, 0);
        defer gpa.free(source);
        // The chunk is named as the CLI names it, so error messages that
        // carry a position read the same as a `mahina tests/...` run.
        const name = try std.fmt.allocPrint(gpa, "tests{s}", .{file.path});
        defer gpa.free(name);
        const program: keyframeser.Program.Source = .{ .text = source, .options = .{ .chunk_name = name } };

        var log: EffectLog = .{};
        defer log.deinit(gpa);
        const rec = try record(gpa, program, source, &log, out_buf);
        defer rec.deinit(gpa);
        try testing.expect(rec.total_safepoints > cuts_per_program);
        collections += rec.collections;

        var prev: u64 = 0;
        for (0..cuts_per_program) |i| {
            const cut = cutAt(rec.total_safepoints, i);
            if (cut == prev) continue;
            prev = cut;
            errdefer std.debug.print("cut: {d} of {d}\n", .{ cut, rec.total_safepoints });
            try expectResumeAt(gpa, program, source, &log, rec, cut, out_buf);
        }
    }
    try testing.expect(collections > 0);
}
