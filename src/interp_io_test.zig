//! Tests for the `io` library (doc 65 Phase 3): text and binary reads across
//! host buffers, writes, seeks and the default files, both error modes, and
//! the record/replay contract — every host operation's result is logged on
//! record, and a replay reproduces the run with no host behind it.
//! `FakeHost` (`interp_testutil.zig`) stands in for the OS.

const std = @import("std");
const interp = @import("interp.zig");
const io = @import("io.zig");
const system = @import("system.zig");
const effectser = @import("effectser.zig");
const keyframeser = @import("keyframeser.zig");
const compiler = @import("compiler.zig");
const parser = @import("parser.zig");
const Diagnostics = @import("diag.zig").Diagnostics;
const testing = std.testing;

const Vm = interp.Vm;
const EffectKind = interp.EffectKind;
const EffectMode = interp.EffectMode;
const util = @import("interp_testutil.zig");
const FakeHost = util.FakeHost;
const compileRun = util.compileRun;

/// One run's captured streams and, for a record, the encoded effect log.
const Run = struct {
    out: []u8,
    err: []u8,
    log: []u8,
    kinds: []EffectKind,

    fn deinit(self: Run, gpa: std.mem.Allocator) void {
        gpa.free(self.out);
        gpa.free(self.err);
        gpa.free(self.log);
        gpa.free(self.kinds);
    }
};

const RunOpts = struct {
    host: ?*FakeHost = null,
    mode: EffectMode = .off,
    /// The log a replay reads.
    log: []const u8 = "",
    io_errors: system.IoErrors = .raise,
};

/// Run `source` in a fresh VM with the files and stdio groups on.
fn run(gpa: std.mem.Allocator, opts: RunOpts, source: [:0]const u8) !Run {
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var out_buf: [4096]u8 = undefined;
    var out = io.Writer.fixed(&out_buf);
    var err_buf: [1024]u8 = undefined;
    var err = io.Writer.fixed(&err_buf);
    vm.out = &out;
    vm.err = &err;
    try vm.enableSystem(.{ .files = true, .stdio = true });
    if (opts.host) |h| vm.system = h.system();
    vm.io_errors = opts.io_errors;
    if (opts.mode == .replay) try effectser.decodeInto(&vm.effect_log, gpa, vm.heap, opts.log);
    vm.effect_mode = opts.mode;
    try compileRun(gpa, &vm, source);
    if (opts.mode == .replay) try testing.expectEqual(vm.effect_log.entries.items.len, vm.effect_cursor);
    const kinds = try gpa.alloc(EffectKind, vm.effect_log.entries.items.len);
    errdefer gpa.free(kinds);
    for (vm.effect_log.entries.items, kinds) |e, *k| k.* = e.kind;
    return .{
        .out = try gpa.dupe(u8, out.buffered()),
        .err = try gpa.dupe(u8, err.buffered()),
        .log = if (opts.mode == .record) try effectser.encodeFile(gpa, &vm.effect_log) else try gpa.dupe(u8, ""),
        .kinds = kinds,
    };
}

/// Run `source` live (off mode) and check stdout.
fn expectOut(host: *FakeHost, source: [:0]const u8, expected: []const u8) !void {
    const r = try run(testing.allocator, .{ .host = host }, source);
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings(expected, r.out);
}

/// Record `source` against `host`, then replay the log with no host at all:
/// the outputs must match byte for byte. Returns the recorded run.
fn recordReplay(gpa: std.mem.Allocator, host: *FakeHost, opts: RunOpts, source: [:0]const u8) !Run {
    var rec_opts = opts;
    rec_opts.host = host;
    rec_opts.mode = .record;
    const rec = try run(gpa, rec_opts, source);
    errdefer rec.deinit(gpa);
    const calls = host.calls;
    var rep_opts = opts;
    rep_opts.host = null;
    rep_opts.mode = .replay;
    rep_opts.log = rec.log;
    const rep = try run(gpa, rep_opts, source);
    defer rep.deinit(gpa);
    try testing.expectEqualStrings(rec.out, rep.out);
    try testing.expectEqualStrings(rec.err, rep.err);
    try testing.expectEqual(calls, host.calls);
    return rec;
}

test "io: read formats cross host buffers (3-byte fills)" {
    var host = FakeHost.init(testing.allocator);
    defer host.deinit();
    try host.put("in.txt", "hello wörld\n42 3.5 0x10 -7e1\nñandú\nlast");
    try expectOut(&host,
        \\local f = io.open("in.txt")
        \\print(f:read("l"))
        \\print(f:read("n", "n", "n", "n"))
        \\print(f:read("L"))
        \\print(f:read(3))
        \\print(f:read(0))
        \\print(f:read("a"))
        \\print(f:read(0), f:read("l"), f:read("a"))
        \\f:close()
    , "hello wörld\n42\t3.5\t16\t-70\n\n\nñan\n\ndú\nlast\nnil\tnil\t\n");
}

test "io: a count reads code points, a binary count reads bytes into a byte array" {
    var host = FakeHost.init(testing.allocator);
    defer host.deinit();
    try host.put("u.txt", "äöü€x");
    try expectOut(&host,
        \\local f = io.open("u.txt")
        \\print(f:read(4), f:read(5))
        \\f:close()
        \\local b = io.open("u.txt", "rb")
        \\local a = b:read(3)
        \\print(#a, a[1], a[2], a[3])
        \\print(pcall(b.read, b, "l"))
        \\b:close()
    , "äöü€\tx\n3\t195\t164\t195\nfalse\tbad argument #2 to 'read' (format not allowed on a binary file)\n");
}

test "io: write, seek, append and io.lines against the host" {
    var host = FakeHost.init(testing.allocator);
    defer host.deinit();
    try expectOut(&host,
        \\local f = io.open("o.txt", "w+")
        \\print(f:write("one\n", 2, "\n", 3.5, "\n") == f)
        \\print(f:seek("cur"), f:seek("set", 4))
        \\print(f:read("l"), f:seek("end"))
        \\f:close()
        \\local a = io.open("o.txt", "a")
        \\a:write("four\n")
        \\a:close()
        \\for l in io.lines("o.txt") do io.write("[", l, "]") end
        \\print()
        \\for a, b in io.lines("o.txt", 1, "l") do io.write(a, "|", b, ";") end
        \\print()
    , "true\n10\t4\n2\t10\n[one][2][3.5][four]\no|ne;2|;3|.5;f|our;\n");
    try testing.expectEqualStrings("one\n2\n3.5\nfour\n", host.contentOf("o.txt").?);
}

test "io: binary writes take byte arrays" {
    var host = FakeHost.init(testing.allocator);
    defer host.deinit();
    try expectOut(&host,
        \\local f = io.open("b.bin", "wb")
        \\f:write({0x41, 0x42}, "C")
        \\print(pcall(f.write, f, {256}))
        \\f:close()
    , "false\tbyte array element is not a byte (an integer 0..255)\n");
    try testing.expectEqualStrings("ABC", host.contentOf("b.bin").?);
}

test "io: failures raise by default and return nil, msg, code in Lua mode" {
    var host = FakeHost.init(testing.allocator);
    defer host.deinit();
    host.denied = &.{"secret"};
    const source =
        \\print(pcall(io.open, "missing.txt"))
        \\print(pcall(io.open, "secret", "w"))
        \\print(pcall(io.open, "x", "rw"))
    ;
    {
        const r = try run(testing.allocator, .{ .host = &host }, source);
        defer r.deinit(testing.allocator);
        try testing.expectEqualStrings("false\tcannot open 'missing.txt': not found\n" ++
            "false\tcannot open 'secret': permission denied\n" ++
            "false\tbad argument #2 to 'open' (invalid mode)\n", r.out);
    }
    {
        const r = try run(testing.allocator, .{ .host = &host, .io_errors = .lua }, source);
        defer r.deinit(testing.allocator);
        try testing.expectEqualStrings("true\tnil\tcannot open 'missing.txt': not found\t1\n" ++
            "true\tnil\tcannot open 'secret': permission denied\t2\n" ++
            "false\tbad argument #2 to 'open' (invalid mode)\n", r.out);
    }
}

test "io: closed and wrong-direction handles are refused without asking the host" {
    var host = FakeHost.init(testing.allocator);
    defer host.deinit();
    try host.put("r.txt", "x");
    try expectOut(&host,
        \\local w = io.open("w.txt", "w")
        \\print(pcall(w.read, w))
        \\local r = io.open("r.txt")
        \\print(pcall(r.write, r, "y"))
        \\r:close()
        \\print(pcall(r.read, r))
        \\print(io.type(r), io.type(w), io.type(42))
        \\print(pcall(io.stdout.close, io.stdout))
        \\print(pcall(io.stdout.seek, io.stdout))
        \\w:close()
    , "false\tcannot read 'w.txt': not open for reading\n" ++
        "false\tcannot write 'r.txt': not open for writing\n" ++
        "false\tattempt to use a closed file\n" ++
        "closed file\tfile\tnil\n" ++
        "false\tcannot close standard file\n" ++
        "false\tcannot seek stdout: not seekable\n");
}

test "io: stdout and stderr go to the VM's seams and are not logged" {
    var host = FakeHost.init(testing.allocator);
    defer host.deinit();
    const r = try recordReplay(testing.allocator, &host, .{},
        \\io.write("a", 1, "\n")
        \\io.stderr:write("e\n")
        \\io.stdout:write("b\n")
    );
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("a1\nb\n", r.out);
    try testing.expectEqualStrings("e\n", r.err);
    try testing.expectEqual(@as(usize, 0), r.kinds.len);
    try testing.expectEqual(@as(usize, 0), host.calls);
}

test "io: stdin reads and io.read take the default input" {
    var host = FakeHost.init(testing.allocator);
    defer host.deinit();
    host.stdin = "first line\n12 rest\n";
    const r = try recordReplay(testing.allocator, &host, .{},
        \\print(io.read())
        \\print(io.read("n"), io.stdin:read("a"))
        \\print(io.read())
    );
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("first line\n12\t rest\n\nnil\n", r.out);
}

test "io: every host operation records and replays with no host" {
    var host = FakeHost.init(testing.allocator);
    defer host.deinit();
    try host.put("data.txt", "alpha\nbeta\n");
    const r = try recordReplay(testing.allocator, &host, .{},
        \\local f = io.open("data.txt", "r+")
        \\print(f:read("l", 2))
        \\print(f:seek("end"))
        \\f:write("gamma\n")
        \\f:setvbuf("full", 64)
        \\f:flush()
        \\f:seek("set")
        \\print(f:read("a"))
        \\f:close()
        \\local t = io.tmpfile()
        \\t:write("tmp")
        \\t:seek("set")
        \\print(t:read("a"))
        \\t:close()
        \\for l in io.lines("data.txt") do io.write(l, ",") end
        \\print()
        \\local b = io.open("data.txt", "rb")
        \\local bytes = b:read(5)
        \\print(#bytes, bytes[1], bytes[5])
        \\b:close()
        \\print(pcall(io.open, "nope"))
    );
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("alpha\tbe\n11\nalpha\nbeta\ngamma\n\ntmp\nalpha,beta,gamma,\n5\t97\t97\n" ++
        "false\tcannot open 'nope': not found\n", r.out);
    var seen: std.EnumSet(EffectKind) = .empty;
    for (r.kinds) |k| seen.insert(k);
    for ([_]EffectKind{ .file_open, .file_read_op, .file_write, .file_seek, .file_control, .io_error_mode }) |k|
        try testing.expect(seen.contains(k));
}

test "io: Lua-mode failures replay in Lua mode" {
    var host = FakeHost.init(testing.allocator);
    defer host.deinit();
    const r = try recordReplay(testing.allocator, &host, .{ .io_errors = .lua },
        \\print(io.open("nope"))
    );
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("nil\tcannot open 'nope': not found\t1\n", r.out);
}

test "io: a replay in the other error mode is refused" {
    var host = FakeHost.init(testing.allocator);
    defer host.deinit();
    const source = "print(pcall(io.open, 'nope'))";
    const rec = try run(testing.allocator, .{ .host = &host, .mode = .record, .io_errors = .lua }, source);
    defer rec.deinit(testing.allocator);
    try testing.expectError(error.IoErrorModeMismatch, run(testing.allocator, .{ .mode = .replay, .log = rec.log }, source));
}

test "io: without the files group io.open is absent; io.write is always there" {
    var vm = try Vm.init(testing.allocator);
    defer vm.deinit();
    var out_buf: [256]u8 = undefined;
    var out = io.Writer.fixed(&out_buf);
    vm.out = &out;
    try compileRun(testing.allocator, &vm,
        \\print(io.open, io.tmpfile, io.read, io.stdin)
        \\io.write("ok\n")
    );
    try testing.expectEqualStrings("nil\tnil\tnil\tnil\nok\n", out.buffered());
}

test "io: a restored handle is detached until reopenFiles, which resumes at the captured position" {
    const gpa = testing.allocator;
    var host = FakeHost.init(gpa);
    defer host.deinit();
    try host.put("log.txt", "one\ntwo\nthree\n");

    const source: [:0]const u8 =
        \\F = io.open("log.txt")
        \\G = io.open("gone.txt", "w")
        \\print(F:read("l"))
    ;
    var diags = Diagnostics.init(gpa);
    defer diags.deinit();
    var tree = try parser.parse(gpa, source, &diags);
    defer tree.deinit();

    // The capturing VM owns the heap the program's constants live in; it must
    // outlive the restored VM that borrows `chunk.proto`.
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var buf: [256]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    vm.out = &sink;
    try vm.enableSystem(.{ .files = true });
    vm.system = host.system();
    var chunk = try compiler.compile(gpa, vm.heap, source, tree.root, &diags);
    defer chunk.deinit();
    try testing.expect(!diags.hasErrors());
    _ = try vm.run(chunk.proto);
    try testing.expectEqualStrings("one\n", sink.buffered());
    const snap = try keyframeser.encodeSnapshot(gpa, &vm);
    defer gpa.free(snap);

    // A later process: the same log.txt, untouched; gone.txt never existed.
    var host2 = FakeHost.init(gpa);
    defer host2.deinit();
    try host2.put("log.txt", "one\ntwo\nthree\n");

    const vm_r = try keyframeser.restore(gpa, snap, chunk.proto, keyframeser.NativeRegistry.base());
    defer {
        vm_r.deinit();
        gpa.destroy(vm_r);
    }
    var buf_r: [512]u8 = undefined;
    var sink_r = io.Writer.fixed(&buf_r);
    vm_r.out = &sink_r;
    vm_r.system = host2.system();
    try compileRun(gpa, vm_r,
        \\print(pcall(F.read, F, "l"))
    );
    try testing.expectEqual(@as(usize, 0), host2.calls);
    try testing.expectEqual(@as(usize, 1), vm_r.reopenFiles());
    try compileRun(gpa, vm_r,
        \\print(F:read("l"))
        \\print(pcall(G.write, G, "x"))
    );
    try testing.expectEqualStrings("false\tfile handle was not reopened after restore\ntwo\n" ++
        "false\tfile handle was not reopened after restore\n", sink_r.buffered());
}
