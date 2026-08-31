//! Tests for `interp.zig` — modules.
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

const EffectKind = interp.EffectKind;
const Vm = interp.Vm;

const util = @import("interp_testutil.zig");
const FakeFs = util.FakeFs;
const compileRun = util.compileRun;

// ---------------------------------------------------------------------------
// P3 — `require` / `package`. The module system is built on the existing
// `fs_source` + `file_read` effect (no new seam, no new effect kind): module
// content is the only nondeterministic input, so `require` programs record/replay
// byte-identically and snapshot like any other heap state. These tests inject an
// in-memory `FakeFs` (the default `package.path` resolves to `./?.mah`, `./?.lua`
// etc.) and prove: load+cache (read once), preload beats path, dotted-name→path
// mapping, both source extensions resolving with `.mah` taking precedence, the
// not-found message, an empty module defaulting to `true`, transitive require,
// record→replay parity, and a user-replaced searcher closure.
// ---------------------------------------------------------------------------

/// Build a VM wired with `out`, `.record` mode, and an injected `FakeFs`, then run
/// `source`. Shared scaffolding for the require tests. `sink` must outlive the call.
fn requireRun(gpa: std.mem.Allocator, vm: *Vm, ffs: *FakeFs, sink: *io.Writer, source: [:0]const u8) !void {
    vm.out = sink;
    vm.effect_mode = .record;
    vm.fs_source = ffs.source();
    try compileRun(gpa, vm, source);
}

test "P3: require loads, caches, and reads the file exactly once" {
    const gpa = testing.allocator;
    var ffs = FakeFs{ .entries = &.{
        .{ .path = "./m.lua", .content = "return {v = 99}" },
    } };
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var sink_buf: [128]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    try requireRun(gpa, &vm, &ffs, &sink,
        \\local a = require("m")
        \\local b = require("m")
        \\print(a.v, a == b)
    );
    try testing.expectEqualStrings("99\ttrue\n", sink.buffered());
    // The preload searcher returns a string (no read). The path searcher walks
    // `package.path` in order, and every probe is a recorded `file_read`: two
    // misses (`./m.mah`, `./m/init.mah`) then the hit on `./m.lua` — three.
    //
    // Three, not six, is the actual assertion here: the second `require` is served
    // from `package.loaded` and re-searches nothing. A caching regression would
    // double this count rather than change it by one, which is why the number is
    // still a sharp test of the property the name claims.
    try testing.expectEqual(@as(usize, 3), vm.effect_log.items.len);
    for (vm.effect_log.items) |e| try testing.expectEqual(EffectKind.file_read, e.kind);
}

test "P3: package.preload beats the path searcher and seeds package.loaded" {
    const gpa = testing.allocator;
    var ffs = FakeFs{ .entries = &.{
        .{ .path = "./m.lua", .content = "return 'from-file'" },
    } };
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var sink_buf: [128]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    try requireRun(gpa, &vm, &ffs, &sink,
        \\package.preload["m"] = function(name) return "preload:" .. name end
        \\print(require("m"))
        \\print(package.loaded.m)
    );
    try testing.expectEqualStrings("preload:m\npreload:m\n", sink.buffered());
    // Preload won before the path searcher ran → no file was ever read.
    try testing.expectEqual(@as(usize, 0), vm.effect_log.items.len);
}

test "P3: a dotted module name maps dots to the path separator" {
    const gpa = testing.allocator;
    var ffs = FakeFs{ .entries = &.{
        .{ .path = "./a/b.lua", .content = "return 'nested'" },
    } };
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var sink_buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    try requireRun(gpa, &vm, &ffs, &sink,
        \\print(require("a.b"))
    );
    try testing.expectEqualStrings("nested\n", sink.buffered());
}

test "P3: require resolves a `.mah` module" {
    const gpa = testing.allocator;
    var ffs = FakeFs{ .entries = &.{
        .{ .path = "./m.mah", .content = "return 'from-mah'" },
    } };
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var sink_buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    try requireRun(gpa, &vm, &ffs, &sink,
        \\print(require("m"))
    );
    try testing.expectEqualStrings("from-mah\n", sink.buffered());
}

test "P3: `.mah` wins over `.lua` when a module exists as both" {
    const gpa = testing.allocator;
    // Same module name available under both extensions. mahina is running, so the
    // mahina-specific file is the one that should load — a project can shadow a
    // Lua module with a mahina one without renaming the Lua original away.
    var ffs = FakeFs{ .entries = &.{
        .{ .path = "./m.mah", .content = "return 'from-mah'" },
        .{ .path = "./m.lua", .content = "return 'from-lua'" },
    } };
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var sink_buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    try requireRun(gpa, &vm, &ffs, &sink,
        \\print(require("m"))
    );
    try testing.expectEqualStrings("from-mah\n", sink.buffered());
    // The `.lua` candidate is never even read: the search stops at the first hit.
    try testing.expectEqual(@as(usize, 1), vm.effect_log.items.len);
}

test "P3: a `.lua` module still resolves when no `.mah` shadows it" {
    const gpa = testing.allocator;
    var ffs = FakeFs{ .entries = &.{
        .{ .path = "./m.lua", .content = "return 'from-lua'" },
    } };
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var sink_buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    try requireRun(gpa, &vm, &ffs, &sink,
        \\print(require("m"))
    );
    try testing.expectEqualStrings("from-lua\n", sink.buffered());
}

test "P3: `.mah` and `.lua` init forms both resolve for a dotted name" {
    const gpa = testing.allocator;
    var ffs = FakeFs{ .entries = &.{
        .{ .path = "./pkg/init.mah", .content = "return 'mah-init'" },
        .{ .path = "./other/init.lua", .content = "return 'lua-init'" },
    } };
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var sink_buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    try requireRun(gpa, &vm, &ffs, &sink,
        \\print(require("pkg"))
        \\print(require("other"))
    );
    try testing.expectEqualStrings("mah-init\nlua-init\n", sink.buffered());
}

test "P3: require of a missing module raises the accumulated not-found message" {
    const gpa = testing.allocator;
    var ffs = FakeFs{ .entries = &.{} }; // empty FS
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var sink_buf: [256]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    try requireRun(gpa, &vm, &ffs, &sink,
        \\local ok, e = pcall(require, "ghost")
        \\print(ok)
        \\print(e)
    );
    // Every searcher contributes a line: preload's "no field", then the four path
    // candidates from the default `package.path` — both `.mah` forms before both
    // `.lua` forms, which is the search order itself, asserted end-to-end.
    try testing.expectEqualStrings(
        "false\n" ++
            "module 'ghost' not found:\n" ++
            "\tno field package.preload['ghost']\n" ++
            "\tno file './ghost.mah'\n" ++
            "\tno file './ghost/init.mah'\n" ++
            "\tno file './ghost.lua'\n" ++
            "\tno file './ghost/init.lua'\n",
        sink.buffered(),
    );
}

test "P3: a module that returns nothing caches as true" {
    const gpa = testing.allocator;
    var ffs = FakeFs{
        .entries = &.{
            .{ .path = "./m.lua", .content = "local x = 1" }, // returns no value
        },
    };
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var sink_buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    try requireRun(gpa, &vm, &ffs, &sink,
        \\print(require("m"))
        \\print(package.loaded.m)
    );
    try testing.expectEqualStrings("true\ntrue\n", sink.buffered());
}

test "P3: transitive require (a loader requires another module)" {
    const gpa = testing.allocator;
    var ffs = FakeFs{ .entries = &.{
        .{ .path = "./top.lua", .content = "local s = require('sub')\nreturn s + 1" },
        .{ .path = "./sub.lua", .content = "return 41" },
    } };
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var sink_buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    try requireRun(gpa, &vm, &ffs, &sink,
        \\print(require("top"))
    );
    try testing.expectEqualStrings("42\n", sink.buffered());
}

test "P3: record→serialize→replay reproduces a require program with the FS detached" {
    const gpa = testing.allocator;
    const effectser = @import("effectser.zig");
    var ffs = FakeFs{ .entries = &.{
        .{ .path = "./greeter.lua", .content = "local m = {}\nfunction m.hi(w) return 'hi ' .. w end\nreturn m" },
    } };
    const driver: [:0]const u8 =
        \\local g = require("greeter")
        \\print(g.hi("mahina"))
    ;

    var rec_out_buf: [64]u8 = undefined;
    var log_bytes: []u8 = undefined;
    {
        var vm = try Vm.init(gpa);
        defer vm.deinit();
        var sink = io.Writer.fixed(&rec_out_buf);
        try requireRun(gpa, &vm, &ffs, &sink, driver);
        try testing.expectEqualStrings("hi mahina\n", sink.buffered());
        // Three file_reads. The path searcher probes `package.path` templates in
        // order and every probe — hit or miss — is a recorded `file_read`, exactly
        // as in stock Lua where each template costs a real `fopen`. So a `.lua`
        // module costs two recorded misses (`./greeter.mah`, `./greeter/init.mah`)
        // before the hit on `./greeter.lua`. The misses are part of the recording
        // and must replay identically, which is what this test then proves.
        try testing.expectEqual(@as(usize, 3), vm.effect_log.items.len);
        log_bytes = try effectser.encodeFile(gpa, vm.effect_log.items);
    }
    defer gpa.free(log_bytes);

    var rep_out_buf: [64]u8 = undefined;
    {
        var vm = try Vm.init(gpa);
        defer vm.deinit();
        var sink = io.Writer.fixed(&rep_out_buf);
        vm.out = &sink;
        const log = try effectser.decodeFile(gpa, vm.heap, log_bytes);
        defer gpa.free(log);
        try vm.effect_log.appendSlice(gpa, log);
        vm.effect_mode = .replay; // NO fs_source — content must come from the log
        try compileRun(gpa, &vm, driver);
        try testing.expectEqualStrings("hi mahina\n", sink.buffered());
    }
    try testing.expectEqualStrings(rec_out_buf[0.."hi mahina\n".len], rep_out_buf[0.."hi mahina\n".len]);
}

test "P3: a user-replaced searcher (a Lua closure) is honoured" {
    const gpa = testing.allocator;
    var ffs = FakeFs{ .entries = &.{} };
    var vm = try Vm.init(gpa);
    defer vm.deinit();
    var sink_buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&sink_buf);
    // Replace the preload searcher (index 1) with a closure returning a loader.
    try requireRun(gpa, &vm, &ffs, &sink,
        \\package.searchers[1] = function(name)
        \\  return function() return "custom:" .. name end
        \\end
        \\print(require("anything"))
    );
    try testing.expectEqualStrings("custom:anything\n", sink.buffered());
}
