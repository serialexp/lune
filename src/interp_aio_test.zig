//! Tests for doc 73 §7.6's `aio`: operations a program awaits, run by a
//! host while it goes on. `FakeAio` stands in for the CLI's threads: it
//! finishes file operations newest first and sleeps shortest first, so the
//! order tasks wake in is the host's, not the program's. Every program is
//! recorded and then replayed with no host at all, which must print the
//! same and start nothing.

const std = @import("std");
const interp = @import("interp.zig");
const io = @import("io.zig");
const system = @import("system.zig");
const effectser = @import("effectser.zig");
const util = @import("interp_testutil.zig");
const keyframeser = @import("keyframeser.zig");
const parser = @import("parser.zig");
const compiler = @import("compiler.zig");
const Diagnostics = @import("diag.zig").Diagnostics;
const testing = std.testing;

const Vm = interp.Vm;
const EffectKind = interp.EffectKind;
const EffectMode = interp.EffectMode;
const AsyncHost = system.AsyncHost;

const FakeAio = struct {
    gpa: std.mem.Allocator,
    files: std.StringHashMapUnmanaged([]u8) = .empty,
    ops: std.ArrayList(Op) = .empty,
    /// Every `start` and `next`, so a test can prove a replay made none.
    calls: usize = 0,

    const Op = struct {
        id: AsyncHost.OpId,
        kind: enum { sleep, read, write, append },
        ns: u64 = 0,
        path: []u8 = &.{},
        data: []u8 = &.{},
    };

    fn init(gpa: std.mem.Allocator) FakeAio {
        return .{ .gpa = gpa };
    }

    fn deinit(self: *FakeAio) void {
        for (self.ops.items) |op| self.freeOp(op);
        self.ops.deinit(self.gpa);
        var it = self.files.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            self.gpa.free(e.value_ptr.*);
        }
        self.files.deinit(self.gpa);
    }

    fn freeOp(self: *FakeAio, op: Op) void {
        self.gpa.free(op.path);
        self.gpa.free(op.data);
    }

    fn put(self: *FakeAio, path: []const u8, bytes: []const u8) !void {
        const data = try self.gpa.dupe(u8, bytes);
        errdefer self.gpa.free(data);
        const gop = try self.files.getOrPut(self.gpa, path);
        if (gop.found_existing) {
            self.gpa.free(gop.value_ptr.*);
        } else {
            gop.key_ptr.* = self.gpa.dupe(u8, path) catch |e| {
                self.files.removeByPtr(gop.key_ptr);
                return e;
            };
        }
        gop.value_ptr.* = data;
    }

    fn host(self: *FakeAio) AsyncHost {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: AsyncHost.VTable = .{ .start = &start, .next = &next };

    fn start(ctx: *anyopaque, id: AsyncHost.OpId, request: AsyncHost.Request) bool {
        const self: *FakeAio = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        var op: Op = .{ .id = id, .kind = .sleep };
        switch (request) {
            .sleep => |ns| op.ns = ns,
            .read => |p| {
                op.kind = .read;
                op.path = self.gpa.dupe(u8, p) catch return false;
            },
            .write => |w| {
                op.kind = if (w.append) .append else .write;
                op.path = self.gpa.dupe(u8, w.path) catch return false;
                op.data = self.gpa.dupe(u8, w.data) catch return false;
            },
        }
        self.ops.append(self.gpa, op) catch return false;
        return true;
    }

    /// The newest file operation, else the shortest sleep (the oldest of
    /// equal ones).
    fn next(ctx: *anyopaque) AsyncHost.Completion {
        const self: *FakeAio = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        var pick: ?usize = null;
        var i = self.ops.items.len;
        while (i > 0) {
            i -= 1;
            if (self.ops.items[i].kind != .sleep) {
                pick = i;
                break;
            }
        }
        if (pick == null) {
            for (self.ops.items, 0..) |op, k| {
                if (pick == null or op.ns < self.ops.items[pick.?].ns) pick = k;
            }
        }
        const op = self.ops.orderedRemove(pick.?);
        defer self.freeOp(op);
        const outcome: AsyncHost.Outcome = switch (op.kind) {
            .sleep => .done,
            .read => if (self.files.get(op.path)) |b| .{ .bytes = b } else .{ .fail = .not_found },
            .write, .append => blk: {
                if (std.mem.startsWith(u8, op.path, "ro/")) break :blk .{ .fail = .permission_denied };
                const old: []const u8 = if (op.kind == .append) self.files.get(op.path) orelse "" else "";
                const joined = std.mem.concat(self.gpa, u8, &.{ old, op.data }) catch @panic("oom");
                defer self.gpa.free(joined);
                self.put(op.path, joined) catch @panic("oom");
                break :blk .done;
            },
        };
        return .{ .id = op.id, .outcome = outcome };
    }
};

const Run = struct {
    out: []u8,
    log: []u8,
    kinds: []EffectKind,

    fn deinit(self: Run, gpa: std.mem.Allocator) void {
        gpa.free(self.out);
        gpa.free(self.log);
        gpa.free(self.kinds);
    }
};

const RunOpts = struct {
    aio: ?*FakeAio = null,
    mode: EffectMode = .off,
    log: []const u8 = "",
    io_errors: system.IoErrors = .raise,
    stress: bool = false,
    groups: system.Groups = .{ .files = true, .clock = true },
    /// Install `aio` at all (a VM whose host has none leaves it out).
    install: bool = true,
};

fn run(gpa: std.mem.Allocator, opts: RunOpts, source: [:0]const u8) !Run {
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var out_buf: [4096]u8 = undefined;
    var out = io.Writer.fixed(&out_buf);
    vm.out = &out;
    vm.heap.setGcStress(opts.stress);
    try vm.enableSystem(opts.groups);
    if (opts.install) try vm.enableAio(if (opts.aio) |a| a.host() else null);
    vm.io_errors = opts.io_errors;
    if (opts.mode == .replay) try effectser.decodeInto(vm.effect_log, gpa, opts.log);
    vm.effect_mode = opts.mode;
    try util.compileRun(gpa, &vm, source);
    if (opts.mode == .replay) try testing.expectEqual(vm.effect_log.entries.items.len, vm.effect_cursor);
    try testing.expectEqual(@as(u32, 0), vm.aio_inflight);
    const kinds = try gpa.alloc(EffectKind, vm.effect_log.entries.items.len);
    errdefer gpa.free(kinds);
    for (vm.effect_log.entries.items, kinds) |e, *k| k.* = e.kind;
    return .{
        .out = try gpa.dupe(u8, out.buffered()),
        .log = if (opts.mode == .record) try effectser.encodeFile(gpa, vm.effect_log) else try gpa.dupe(u8, ""),
        .kinds = kinds,
    };
}

/// Record `source` against a fresh `FakeAio` holding `files`, then replay
/// it with no host: both print `expected`, under both GC disciplines.
/// Returns the recorded effect kinds (caller frees).
fn expectAio(files: []const [2][]const u8, opts: RunOpts, source: [:0]const u8, expected: []const u8) ![]EffectKind {
    const gpa = testing.allocator;
    var kinds: ?[]EffectKind = null;
    errdefer if (kinds) |k| gpa.free(k);
    inline for (.{ false, true }) |stress| {
        var fake = FakeAio.init(gpa);
        defer fake.deinit();
        for (files) |f| try fake.put(f[0], f[1]);
        var rec_opts = opts;
        rec_opts.aio = &fake;
        rec_opts.mode = .record;
        rec_opts.stress = stress;
        const rec = try run(gpa, rec_opts, source);
        defer rec.deinit(gpa);
        try testing.expectEqualStrings(expected, rec.out);
        const calls = fake.calls;
        var rep_opts = opts;
        rep_opts.mode = .replay;
        rep_opts.log = rec.log;
        rep_opts.stress = stress;
        const rep = try run(gpa, rep_opts, source);
        defer rep.deinit(gpa);
        try testing.expectEqualStrings(expected, rep.out);
        try testing.expectEqual(calls, fake.calls);
        if (kinds == null) kinds = try gpa.dupe(EffectKind, rec.kinds);
    }
    return kinds.?;
}

test "aio: tasks wake in the order the host finishes, not the order they started" {
    const kinds = try expectAio(&.{}, .{},
        \\local async function w(name, op) await op; print(name) end
        \\w("slow", aio.sleep(0.3))
        \\w("fast", aio.sleep(0.1))
        \\w("zero", aio.sleep(0))
        \\print("started")
    , "started\nzero\nfast\nslow\n");
    defer testing.allocator.free(kinds);
    try testing.expectEqualSlices(EffectKind, &.{ .aio_complete, .aio_result, .aio_complete, .aio_result, .aio_complete, .aio_result }, kinds);
}

test "aio: write, append and read a whole file, text or bytes" {
    const kinds = try expectAio(&.{}, .{},
        \\print(await aio.write("f.txt", "héllo"))
        \\print(await aio.append("f.txt", 42))
        \\print(await aio.read("f.txt"))
        \\local b = await aio.read("f.txt", "b")
        \\print(#b, b[1], b[2], b[3])
        \\print(await aio.write("g.bin", (await aio.read("f.txt", "b"))))
        \\print(await aio.read("g.bin"))
    , "true\ntrue\nhéllo42\n8\t104\t195\t169\ntrue\nhéllo42\n");
    defer testing.allocator.free(kinds);
    try testing.expectEqual(EffectKind.io_error_mode, kinds[0]);
}

test "aio: reads in flight together come back in the host's order" {
    const kinds = try expectAio(&.{ .{ "a", "A" }, .{ "b", "B" }, .{ "c", "C" } }, .{},
        \\local got = {}
        \\local async function r(p) local v = await aio.read(p); got[#got + 1] = v end
        \\local ts = { r("a"), r("b"), r("c") }
        \\for _, t in ipairs(ts) do await t end
        \\print(table.concat(got, " "))
    , "C B A\n");
    defer testing.allocator.free(kinds);
}

test "aio: a failure raises at the await, or gives Lua's returns" {
    const files = [_][2][]const u8{.{ "bad.txt", "\xff\xfe" }};
    const src =
        \\print(pcall(function() return await aio.read("missing.txt") end))
        \\print(pcall(function() return await aio.read("bad.txt") end))
        \\print(pcall(function() return await aio.write("ro/x", "y") end))
        \\local b = await aio.read("bad.txt", "b")
        \\print(#b, b[1])
    ;
    const k1 = try expectAio(&files, .{}, src, "false\tcannot read 'missing.txt': not found\n" ++
        "false\tcannot read 'bad.txt': not valid UTF-8\n" ++
        "false\tcannot write 'ro/x': permission denied\n" ++
        "2\t255\n");
    defer testing.allocator.free(k1);
    const k2 = try expectAio(&files, .{ .io_errors = .lua }, src, "true\tnil\tcannot read 'missing.txt': not found\t1\n" ++
        "true\tnil\tcannot read 'bad.txt': not valid UTF-8\t5\n" ++
        "true\tnil\tcannot write 'ro/x': permission denied\t2\n" ++
        "2\t255\n");
    defer testing.allocator.free(k2);
}

test "aio: an unawaited failure is an unobserved task error at the end" {
    const gpa = testing.allocator;
    var fake = FakeAio.init(gpa);
    defer fake.deinit();
    try testing.expectError(error.LuaError, run(gpa, .{ .aio = &fake },
        \\local async function f() await aio.read("nope") end
        \\f()
    ));
}

test "aio: bad arguments raise at the call and start nothing" {
    const kinds = try expectAio(&.{}, .{},
        \\print(pcall(aio.sleep, "x"))
        \\print(pcall(aio.sleep, -1))
        \\print(pcall(aio.read, 1))
        \\print(pcall(aio.read, "f", "x"))
        \\print(pcall(aio.write, "f", true))
        \\print(pcall(aio.write, "f", { 1, 300 }))
    , "false\tbad argument #1 to '?' (number expected, got string)\n" ++
        "false\tbad argument #1 to '?' (negative or NaN duration)\n" ++
        "false\tbad argument #1 to '?' (string expected, got number)\n" ++
        "false\tbad argument #2 to '?' (invalid mode)\n" ++
        "false\tbad argument #2 to '?' (string or byte array expected, got boolean)\n" ++
        "false\tbyte array element is not a byte (an integer 0..255)\n");
    defer testing.allocator.free(kinds);
    try testing.expectEqual(@as(usize, 0), kinds.len);
}

test "aio: a group that is off leaves its functions out; no host, no aio" {
    const gpa = testing.allocator;
    var fake = FakeAio.init(gpa);
    defer fake.deinit();
    const only_clock = try run(gpa, .{ .aio = &fake, .groups = .{ .clock = true } },
        \\print(type(aio.sleep), aio.read, aio.write)
    );
    defer only_clock.deinit(gpa);
    try testing.expectEqualStrings("function\tnil\tnil\n", only_clock.out);
    const none = try run(gpa, .{ .install = false },
        \\print(aio)
    );
    defer none.deinit(gpa);
    try testing.expectEqualStrings("nil\n", none.out);
    const hostless = try run(gpa, .{},
        \\print(pcall(aio.sleep, 1))
    );
    defer hostless.deinit(gpa);
    try testing.expectEqualStrings("false\taio: this host runs no asynchronous operations\n", hostless.out);
}
/// The FakeAio every matrix leg's VM is wired to (`installMatrixAio`).
var matrix_aio: ?*FakeAio = null;

fn installMatrixAio(vm: *Vm) anyerror!void {
    try vm.enableSystem(.{ .clock = true });
    try vm.enableAio(matrix_aio.?.host());
}

test "aio: awaits in hot loops on every GC and trace leg" {
    var fake = FakeAio.init(testing.allocator);
    defer fake.deinit();
    matrix_aio = &fake;
    defer matrix_aio = null;
    // The waits take the shortest sleep first, the oldest of equal ones.
    try util.expectProgramTuned(
        \\local log = {}
        \\local async function tick(v) await aio.sleep(v % 3); log[#log + 1] = v; return v end
        \\local s = 0
        \\for i = 1, 60 do s = s + await tick(i) end
        \\log = {}
        \\local ts = {}
        \\for i = 1, 30 do ts[i] = tick(31 - i) end
        \\for i = 1, 30 do s = s + await ts[i] end
        \\print(s, table.concat(log, ","))
    , "2295\t30,27,24,21,18,15,12,9,6,3,28,25,22,19,16,13,10,7,4,1,29,26,23,20,17,14,11,8,5,2\n", .{ .setup = &installMatrixAio });
}

// ---------------------------------------------------------------------------
// Keyframes (format 18): the operations in flight are a VM root. A replay
// restored at any cut settles them from the log and finishes as the
// uninterrupted run did; a live restore can't, as no host is running them.
// ---------------------------------------------------------------------------

const kf_source =
    \\local log = {}
    \\local async function w(name, op) local v = await op; log[#log + 1] = name; return v end
    \\local a = w("a", aio.sleep(2))
    \\local b = w("b", aio.sleep(1))
    \\local c = w("c", aio.read("g"))
    \\print(await c)
    \\print(await a == nil, await b == nil)
    \\print(table.concat(log, " "))
;

/// A VM for `kf_source`: output to `sink`, `aio` installed (run by `host`,
/// or none for a replay), and in replay mode the decoded `log`.
fn kfVm(gpa: std.mem.Allocator, sink: *io.Writer, host: ?AsyncHost, log: ?[]const u8) !Vm {
    var vm = try Vm.init(gpa);
    errdefer vm.deinit();
    vm.out = sink;
    try vm.enableSystem(.{ .files = true, .clock = true });
    try vm.enableAio(host);
    if (log) |l| {
        try effectser.decodeInto(vm.effect_log, gpa, l);
        vm.effect_mode = .replay;
    } else vm.effect_mode = .record;
    return vm;
}

const KfRef = struct { out: []u8, log: []u8, safepoints: u64 };

fn kfRecord(gpa: std.mem.Allocator, tree: *const @import("ast.zig").Ast) !KfRef {
    var fake = FakeAio.init(gpa);
    defer fake.deinit();
    try fake.put("g", "G");
    var buf: [512]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    var vm = try kfVm(gpa, &sink, fake.host(), null);
    defer vm.deinit();
    var diags = Diagnostics.init(gpa);
    defer diags.deinit();
    var chunk = try compiler.compile(gpa, vm.heap, kf_source, tree.root, &diags);
    defer chunk.deinit();
    _ = try vm.run(chunk.proto);
    const out = try gpa.dupe(u8, sink.buffered());
    errdefer gpa.free(out);
    return .{ .out = out, .log = try effectser.encodeFile(gpa, vm.effect_log), .safepoints = vm.safepoint_seq };
}

test "aio: a replay restored at any cut settles the operations in flight from the log" {
    const gpa = testing.allocator;
    var diags = Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, kf_source, &diags);
    defer tree.deinit();
    const ref = try kfRecord(gpa, &tree);
    defer gpa.free(ref.out);
    defer gpa.free(ref.log);
    try testing.expectEqualStrings("G\ntrue\ttrue\nc b a\n", ref.out);

    var cuts_in_flight: usize = 0;
    var cut: u64 = 1;
    while (cut <= ref.safepoints) : (cut += 1) {
        var buf: [512]u8 = undefined;
        var sink = io.Writer.fixed(&buf);
        var vm = try kfVm(gpa, &sink, null, ref.log);
        defer vm.deinit();
        var chunk = try compiler.compile(gpa, vm.heap, kf_source, tree.root, &diags);
        defer chunk.deinit();
        vm.setSuspendCtl(.{ .after_safepoints = cut });
        if ((try vm.start(chunk.proto)) != .suspended) continue;
        if (vm.aio_inflight > 0) cuts_in_flight += 1;
        const mid = try keyframeser.encodeSnapshot(gpa, &vm);
        defer gpa.free(mid);

        const vm_r = try keyframeser.restore(gpa, mid, .of(kf_source), keyframeser.NativeRegistry.base());
        defer {
            vm_r.deinit();
            gpa.destroy(vm_r);
        }
        try testing.expectEqual(vm.aio_inflight, vm_r.aio_inflight);
        try testing.expectEqual(vm.aio_next_id, vm_r.aio_next_id);
        {
            const again = try keyframeser.encodeSnapshot(gpa, vm_r);
            defer gpa.free(again);
            try testing.expectEqualSlices(u8, mid, again);
        }
        var buf_r: [512]u8 = undefined;
        var sink_r = io.Writer.fixed(&buf_r);
        vm_r.out = &sink_r;
        try effectser.decodeInto(vm_r.effect_log, gpa, ref.log);
        try testing.expectEqual(vm.effect_cursor, vm_r.effect_cursor);
        vm_r.effect_mode = .replay;
        try testing.expect((try vm_r.exec()) == .finished);
        var combined: std.ArrayList(u8) = .empty;
        defer combined.deinit(gpa);
        try combined.appendSlice(gpa, sink.buffered());
        try combined.appendSlice(gpa, sink_r.buffered());
        try testing.expectEqualStrings(ref.out, combined.items);
        try testing.expectEqual(vm_r.effect_log.entries.items.len, vm_r.effect_cursor);
        try testing.expectEqual(@as(u32, 0), vm_r.aio_inflight);
    }
    try testing.expect(cuts_in_flight > 0);
}

test "aio: a live restore with operations in flight refuses at the wait" {
    const gpa = testing.allocator;
    var diags = Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, kf_source, &diags);
    defer tree.deinit();
    const ref = try kfRecord(gpa, &tree);
    defer gpa.free(ref.out);
    defer gpa.free(ref.log);

    // The first cut with all three operations in flight.
    var cut: u64 = 1;
    while (cut <= ref.safepoints) : (cut += 1) {
        var buf: [512]u8 = undefined;
        var sink = io.Writer.fixed(&buf);
        var vm = try kfVm(gpa, &sink, null, ref.log);
        defer vm.deinit();
        var chunk = try compiler.compile(gpa, vm.heap, kf_source, tree.root, &diags);
        defer chunk.deinit();
        vm.setSuspendCtl(.{ .after_safepoints = cut });
        if ((try vm.start(chunk.proto)) != .suspended or vm.aio_inflight < 3) continue;
        const mid = try keyframeser.encodeSnapshot(gpa, &vm);
        defer gpa.free(mid);
        const vm_r = try keyframeser.restore(gpa, mid, .of(kf_source), keyframeser.NativeRegistry.base());
        defer {
            vm_r.deinit();
            gpa.destroy(vm_r);
        }
        var fake = FakeAio.init(gpa);
        defer fake.deinit();
        var buf_r: [512]u8 = undefined;
        var sink_r = io.Writer.fixed(&buf_r);
        vm_r.out = &sink_r;
        vm_r.aio = fake.host();
        try testing.expectError(error.LuaError, vm_r.exec());
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const fault = try vm_r.describeFault(error.LuaError, arena.allocator());
        try testing.expect(std.mem.indexOf(u8, fault.message, "aio: an operation in flight at the keyframe cannot continue live") != null);
        try testing.expectEqual(@as(usize, 0), fake.calls);
        return;
    }
    return error.TestExpectedCut;
}
