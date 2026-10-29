//! Doc 74 §9 — `zig build bench-lsp` (ReleaseFast).
//!
//! The language server's performance budget, measured per stage and end to
//! end: from a change arriving to the diagnostics message being encoded
//! (debounce excluded), over realistic files at 1k / 10k / 100k lines and the
//! adversarial corpus (one 1 MB line of astral characters, 60k distinct
//! constants, 500-deep nesting, a file broken every 20 lines, an edit burst of
//! 200 changes, 50 open documents), the cost `require` resolution adds
//! against the real disk, and member completion on a required module, cold and
//! from the module cache (doc 74 §7.4).
//!
//! Budget (doc 74 Q12): ≤ 10 ms end to end at 10k lines, ≤ 100 ms at 100k.
//! Informational, not a gate (global Rule #22): run it deliberately, on a
//! quiet machine, and compare against itself.

const std = @import("std");
const mahina = @import("mahina");

const lsp = mahina.lsp;
const analysis = lsp.analysis;
const server = lsp.server;

const Case = struct {
    name: []const u8,
    text: []const u8,
    reps: usize,
};

fn now(io: std.Io) i96 {
    return std.Io.Timestamp.now(io, .awake).nanoseconds;
}

fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
}

// ---- corpus -----------------------------------------------------------------

/// Roughly `lines` lines of ordinary code: functions with loops, tables,
/// closures and calls to earlier functions. `break_every` > 0 injects a
/// syntax error every that many lines.
/// `requires`: each block starts with a literal `require` of `mod_<i % 200>`,
/// for the cross-file table.
fn realistic(gpa: std.mem.Allocator, lines: usize, break_every: usize, requires: bool) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var line: usize = 0;
    var i: usize = 0;
    while (line < lines) : (i += 1) {
        if (requires) {
            try out.print(gpa, "local m_{d} = require(\"mod_{d}\")\n", .{ i, i % cross_modules_named });
            line += 1;
        }
        const block = try std.fmt.allocPrint(gpa,
            \\local function work_{d}(items, scale)
            \\  local total = 0
            \\  for idx = 1, #items do
            \\    local item = items[idx]
            \\    if item.kind == "a" then
            \\      total = total + item.value * scale
            \\    else
            \\      total = total - (item.value or 0)
            \\    end
            \\  end
            \\  local cache = {{ total = total, label = "block_{d}", parts = {{ 1, 2, 3 }} }}
            \\  return function(extra) return cache.total + extra + #cache.parts end
            \\end
            \\
        , .{ i, i });
        defer gpa.free(block);
        try out.appendSlice(gpa, block);
        line += 13;
        if (break_every != 0 and (i + 1) * 13 / break_every > i * 13 / break_every) {
            try out.appendSlice(gpa, "local broken = = 1\n");
            line += 1;
        }
    }
    return out.toOwnedSlice(gpa);
}

fn astralLine(gpa: std.mem.Allocator, bytes: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "local t = { ");
    while (out.items.len < bytes) try out.appendSlice(gpa, "\"\u{1F600}\u{1F601}\", ");
    // No closing brace: the error lands at the very end of a 1 MB line.
    return out.toOwnedSlice(gpa);
}

fn manyConstants(gpa: std.mem.Allocator, n: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "local x\n");
    for (0..n) |i| {
        const line = try std.fmt.allocPrint(gpa, "x = {d}.5\n", .{i});
        defer gpa.free(line);
        try out.appendSlice(gpa, line);
    }
    return out.toOwnedSlice(gpa);
}

fn nested(gpa: std.mem.Allocator, depth: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "return ");
    for (0..depth) |_| try out.appendSlice(gpa, "f(");
    try out.appendSlice(gpa, "1");
    for (0..depth) |_| try out.appendSlice(gpa, ")");
    return out.toOwnedSlice(gpa);
}

// ---- stages -----------------------------------------------------------------

const Stages = struct {
    parse: u64 = std.math.maxInt(u64),
    resolve: u64 = std.math.maxInt(u64),
    check: u64 = std.math.maxInt(u64),
    analyse: u64 = std.math.maxInt(u64),
    peak: usize = 0,
    allocs: usize = 0,
    diags: usize = 0,
};

/// Each stage on its own, best of `reps`, then the whole `analyse` once more
/// under a tracking allocator.
fn stages(gpa: std.mem.Allocator, io: std.Io, text: []const u8, reps: usize) !Stages {
    var r = Stages{};
    const source = try gpa.dupeSentinel(u8, text, 0);
    defer gpa.free(source);
    const known = &mahina.interp.builtin_global_names;

    for (0..reps) |_| {
        var diags = mahina.diag.Diagnostics.init(gpa);
        defer diags.deinit();
        const t0 = now(io);
        var tree = try mahina.parser.parse(gpa, source, &diags);
        defer tree.deinit();
        const t1 = now(io);
        var res = try mahina.resolve.resolve(gpa, tree.root, @intCast(source.len));
        defer res.deinit();
        const t2 = now(io);
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        var heap = mahina.gc.Heap.init(gpa);
        defer heap.deinit();
        mahina.compiler.checkChunk(gpa, arena.allocator(), &heap, source, tree.root, &res, &diags, .{ .known_globals = known }) catch {};
        const t3 = now(io);
        r.parse = @min(r.parse, @as(u64, @intCast(t1 - t0)));
        r.resolve = @min(r.resolve, @as(u64, @intCast(t2 - t1)));
        r.check = @min(r.check, @as(u64, @intCast(t3 - t2)));
    }
    for (0..reps) |_| {
        const t0 = now(io);
        var an = try analysis.analyse(gpa, text, known, .{});
        const t1 = now(io);
        r.diags = an.diagnostics.len;
        an.deinit();
        r.analyse = @min(r.analyse, @as(u64, @intCast(t1 - t0)));
    }
    var tracker = mahina.mem.TrackingAllocator.init(gpa);
    var an = try analysis.analyse(tracker.allocator(), text, known, .{});
    an.deinit();
    r.peak = tracker.stats.peak_bytes;
    r.allocs = tracker.stats.alloc_count;
    return r;
}

/// One syntax request (doc 74 §7.1) answered on an open, analysed document:
/// the request in, the encoded response out, best of `reps`.
/// Best-of-`reps` time of one request on an open, analysed `text`. `tail` is
/// more `params` members (a `,"position":…`), or empty.
fn requestNs(gpa: std.mem.Allocator, io: std.Io, text: []const u8, method: []const u8, tail: []const u8, reps: usize) !u64 {
    var core = server.Server.init(gpa, .{});
    defer core.deinit();
    core.known_globals = &mahina.interp.builtin_global_names;
    var out = server.Outbox.init(gpa);
    defer out.deinit();
    try open(gpa, &core, &out, text);

    const body = try std.fmt.allocPrint(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"{s}\",\"params\":{{\"textDocument\":{{\"uri\":\"file:///bench.mh\"}}{s}}}}}", .{ method, tail });
    defer gpa.free(body);
    var best: u64 = std.math.maxInt(u64);
    for (0..reps) |_| {
        out.reset();
        const t0 = now(io);
        try core.handle(0, body, &out);
        const t1 = now(io);
        if (out.messages().len != 1) return error.NoResponse;
        best = @min(best, @as(u64, @intCast(t1 - t0)));
    }
    return best;
}

/// A change in, the encoded `publishDiagnostics` out: the budget's own
/// measurement. The edit replaces the whole text; the debounce is not waited.
fn endToEnd(gpa: std.mem.Allocator, io: std.Io, text: []const u8, reps: usize) !u64 {
    var core = server.Server.init(gpa, .{});
    defer core.deinit();
    core.known_globals = &mahina.interp.builtin_global_names;
    var out = server.Outbox.init(gpa);
    defer out.deinit();
    try open(gpa, &core, &out, text);

    var best: u64 = std.math.maxInt(u64);
    for (0..reps) |rep| {
        const body = try changeBody(gpa, text, @intCast(rep + 2));
        defer gpa.free(body);
        out.reset();
        const t0 = now(io);
        try core.handle(1000 + rep * 1000, body, &out);
        try core.tick(1000 + rep * 1000 + 250, &out);
        const t1 = now(io);
        if (out.messages().len != 1) {
            mahina.io.eprint("e2e: {d} messages\n", .{out.messages().len});
            return error.NoPublish;
        }
        best = @min(best, @as(u64, @intCast(t1 - t0)));
    }
    return best;
}

/// The cross-file table's modules: `mod_0` … `mod_99` exist on disk, and the
/// text names `mod_0` … `mod_199`, so half its requires resolve nowhere and try
/// every template.
const cross_modules_on_disk = 100;
const cross_modules_named = 200;
const cross_dir = "/tmp/mahina-bench-lsp";

fn writeModules(io: std.Io) !void {
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, cross_dir) catch {};
    try cwd.createDirPath(io, cross_dir);
    for (0..cross_modules_on_disk) |k| {
        var buf: [96]u8 = undefined;
        const path = try std.fmt.bufPrint(&buf, cross_dir ++ "/mod_{d}.mah", .{k});
        try cwd.writeFile(io, .{ .sub_path = path, .data = "return {}\n" });
    }
}

/// `endToEnd` for a document in a workspace folder at `cross_dir`, reading
/// `files` (null: no disk, so nothing is probed and no miss is reported).
fn crossFile(gpa: std.mem.Allocator, io: std.Io, text: []const u8, files: ?lsp.workspace.Files, reps: usize) !u64 {
    var core = server.Server.init(gpa, .{});
    defer core.deinit();
    core.known_globals = &mahina.interp.builtin_global_names;
    core.files = files;
    var out = server.Outbox.init(gpa);
    defer out.deinit();
    try core.handle(0, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"capabilities\":{},\"rootUri\":\"file://" ++ cross_dir ++ "\"}}", &out);
    try core.handle(0, "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}", &out);
    const uri = "file://" ++ cross_dir ++ "/bench.mh";
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try aw.writer.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"" ++ uri ++ "\",\"version\":1,\"text\":");
    try std.json.Stringify.value(text, .{}, &aw.writer);
    try aw.writer.writeAll("}}}");
    try core.handle(0, aw.written(), &out);
    try core.tick(250, &out);

    var best: u64 = std.math.maxInt(u64);
    for (0..reps) |rep| {
        aw.clearRetainingCapacity();
        try aw.writer.print("{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{{\"textDocument\":{{\"uri\":\"" ++ uri ++ "\",\"version\":{d}}},\"contentChanges\":[{{\"text\":", .{rep + 2});
        try std.json.Stringify.value(text, .{}, &aw.writer);
        try aw.writer.writeAll("}]}}");
        out.reset();
        const t0 = now(io);
        try core.handle(1000 + rep * 1000, aw.written(), &out);
        try core.tick(1000 + rep * 1000 + 250, &out);
        const t1 = now(io);
        if (out.messages().len != 1) return error.NoPublish;
        best = @min(best, @as(u64, @intCast(t1 - t0)));
    }
    return best;
}

/// A module of `lines` lines that exports every block's function, written to
/// `cross_dir/big.mah`.
fn writeBigModule(gpa: std.mem.Allocator, io: std.Io, lines: usize) !usize {
    const body = try realistic(gpa, lines, 0, false);
    defer gpa.free(body);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try out.appendSlice(gpa, "local M = {}\n");
    try out.appendSlice(gpa, body);
    const blocks = std.mem.count(u8, body, "local function work_");
    for (0..blocks) |i| try out.print(gpa, "M.work_{d} = work_{d}\n", .{ i, i });
    try out.appendSlice(gpa, "return M\n");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = cross_dir ++ "/big.mah", .data = out.items });
    return blocks;
}

/// Member completion after `m.` for a module local bound to `big.mah` on disk:
/// cold (the module read, parsed and its exports listed) and warm (the cache
/// checks the text it read again and answers), best of `reps`.
fn moduleMembers(gpa: std.mem.Allocator, io: std.Io, reps: usize) !struct { cold: u64, warm: u64 } {
    var core = server.Server.init(gpa, .{});
    defer core.deinit();
    core.known_globals = &mahina.interp.builtin_global_names;
    core.files = lsp.host_stdio.disk;
    var out = server.Outbox.init(gpa);
    defer out.deinit();
    try core.handle(0, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"capabilities\":{},\"rootUri\":\"file://" ++ cross_dir ++ "\"}}", &out);
    try core.handle(0, "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}", &out);
    const uri = "file://" ++ cross_dir ++ "/use.mh";
    try core.handle(0, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"" ++ uri ++ "\",\"version\":1,\"text\":\"local m = require(\\\"big\\\")\\nm.\\n\"}}}", &out);
    try core.tick(250, &out);
    const body = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/completion\",\"params\":{\"textDocument\":{\"uri\":\"" ++ uri ++ "\"},\"position\":{\"line\":1,\"character\":2}}}";

    var cold: u64 = std.math.maxInt(u64);
    var warm: u64 = std.math.maxInt(u64);
    for (0..reps) |_| {
        core.module_cache.remove(cross_dir ++ "/big.mah");
        for ([_]*u64{ &cold, &warm }) |slot| {
            out.reset();
            const t0 = now(io);
            try core.handle(300, body, &out);
            const t1 = now(io);
            if (out.messages().len != 1) return error.NoResponse;
            slot.* = @min(slot.*, @as(u64, @intCast(t1 - t0)));
        }
    }
    if (core.module_cache.builds != reps) return error.CacheMissed;
    return .{ .cold = cold, .warm = warm };
}

fn open(gpa: std.mem.Allocator, core: *server.Server, out: *server.Outbox, text: []const u8) !void {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try aw.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"capabilities\":{}}}");
    try core.handle(0, aw.written(), out);
    aw.clearRetainingCapacity();
    try aw.writer.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}");
    try core.handle(0, aw.written(), out);
    const body = try openBody(gpa, text);
    defer gpa.free(body);
    try core.handle(0, body, out);
    try core.tick(250, out);
}

fn openBody(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    try aw.writer.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file:///bench.mh\",\"version\":1,\"text\":");
    try std.json.Stringify.value(text, .{}, &aw.writer);
    try aw.writer.writeAll("}}}");
    return aw.toOwnedSlice();
}

fn changeBody(gpa: std.mem.Allocator, text: []const u8, version: i64) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    try aw.writer.print("{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{{\"textDocument\":{{\"uri\":\"file:///bench.mh\",\"version\":{d}}},\"contentChanges\":[{{\"text\":", .{version});
    try std.json.Stringify.value(text, .{}, &aw.writer);
    try aw.writer.writeAll("}]}}");
    return aw.toOwnedSlice();
}

/// 200 one-character edits in a burst, then the one analysis they cost.
fn editBurst(gpa: std.mem.Allocator, io: std.Io, text: []const u8) !u64 {
    var core = server.Server.init(gpa, .{});
    defer core.deinit();
    core.known_globals = &mahina.interp.builtin_global_names;
    var out = server.Outbox.init(gpa);
    defer out.deinit();
    try open(gpa, &core, &out, text);

    const t0 = now(io);
    for (0..200) |k| {
        var buf: [256]u8 = undefined;
        const body = try std.fmt.bufPrint(&buf,
            \\{{"jsonrpc":"2.0","method":"textDocument/didChange","params":{{"textDocument":{{"uri":"file:///bench.mh","version":{d}}},"contentChanges":[{{"range":{{"start":{{"line":0,"character":0}},"end":{{"line":0,"character":0}}}},"text":"-"}}]}}}}
        , .{k + 2});
        out.reset();
        try core.handle(1000 + k, body, &out);
    }
    out.reset();
    try core.tick(5000, &out);
    const t1 = now(io);
    if (out.messages().len != 1) return error.NoPublish;
    return @intCast(t1 - t0);
}

/// 50 open documents of 1k lines, each edited once, all analysed by one tick.
fn manyDocuments(gpa: std.mem.Allocator, io: std.Io, text: []const u8) !struct { ns: u64, peak: usize } {
    var tracker = mahina.mem.TrackingAllocator.init(gpa);
    const ta = tracker.allocator();
    var core = server.Server.init(ta, .{});
    defer core.deinit();
    core.known_globals = &mahina.interp.builtin_global_names;
    var out = server.Outbox.init(ta);
    defer out.deinit();
    try open(ta, &core, &out, text);
    for (1..50) |k| {
        var aw: std.Io.Writer.Allocating = .init(ta);
        defer aw.deinit();
        try aw.writer.print("{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{{\"textDocument\":{{\"uri\":\"file:///bench{d}.mh\",\"version\":1,\"text\":", .{k});
        try std.json.Stringify.value(text, .{}, &aw.writer);
        try aw.writer.writeAll("}}}");
        try core.handle(0, aw.written(), &out);
    }
    out.reset();
    const t0 = now(io);
    try core.tick(1000, &out);
    const t1 = now(io);
    if (out.messages().len != 49) return error.NoPublish;
    return .{ .ns = @intCast(t1 - t0), .peak = tracker.stats.peak_bytes };
}

pub fn main(init: std.process.Init) u8 {
    const gpa = init.gpa;
    const io = init.io;
    run(gpa, io) catch |e| {
        mahina.io.eprint("bench-lsp: error: {s}\n", .{@errorName(e)});
        return 1;
    };
    return 0;
}

fn run(gpa: std.mem.Allocator, io: std.Io) !void {
    var cases: std.ArrayList(Case) = .empty;
    defer {
        for (cases.items) |c| gpa.free(c.text);
        cases.deinit(gpa);
    }
    try cases.append(gpa, .{ .name = "realistic 1k lines", .text = try realistic(gpa, 1_000, 0, false), .reps = 20 });
    try cases.append(gpa, .{ .name = "realistic 10k lines", .text = try realistic(gpa, 10_000, 0, false), .reps = 10 });
    try cases.append(gpa, .{ .name = "realistic 100k lines", .text = try realistic(gpa, 100_000, 0, false), .reps = 5 });
    try cases.append(gpa, .{ .name = "broken every 20 lines (10k)", .text = try realistic(gpa, 10_000, 20, false), .reps = 10 });
    try cases.append(gpa, .{ .name = "one 1 MB line, astral chars", .text = try astralLine(gpa, 1 << 20), .reps = 5 });
    try cases.append(gpa, .{ .name = "60k distinct constants", .text = try manyConstants(gpa, 60_000), .reps = 5 });
    try cases.append(gpa, .{ .name = "500-deep nesting", .text = try nested(gpa, 500), .reps = 20 });
    try cases.append(gpa, .{ .name = "50k-deep nesting (adversarial)", .text = try nested(gpa, 50_000), .reps = 3 });

    mahina.io.print(
        \\language server stages and end to end (doc 74 §9; best of N, ms)
        \\
        \\{s: <30} {s: >9} {s: >7} {s: >7} {s: >8} {s: >8} {s: >9} {s: >10} {s: >9} {s: >6}
        \\
    , .{ "case", "bytes", "parse", "resolve", "check", "analyse", "end2end", "peak MiB", "allocs", "diags" });
    for (cases.items) |c| {
        const s = try stages(gpa, io, c.text, c.reps);
        const e2e = try endToEnd(gpa, io, c.text, @max(3, c.reps / 2));
        mahina.io.print("{s: <30} {d: >9} {d: >7.2} {d: >7.2} {d: >8.2} {d: >8.2} {d: >9.2} {d: >10.1} {d: >9} {d: >6}\n", .{
            c.name,
            c.text.len,
            ms(s.parse),
            ms(s.resolve),
            ms(s.check),
            ms(s.analyse),
            ms(e2e),
            @as(f64, @floatFromInt(s.peak)) / (1024.0 * 1024.0),
            s.allocs,
            s.diags,
        });
    }

    mahina.io.print(
        \\
        \\syntax requests on an open, analysed document (doc 74 §7.1; best of N, ms)
        \\
        \\{s: <30} {s: >9} {s: >14} {s: >10} {s: >10}
        \\
    , .{ "case", "bytes", "semanticTokens", "folding", "symbols" });
    for (cases.items[0..3]) |c| {
        const tokens_ns = try requestNs(gpa, io, c.text, "textDocument/semanticTokens/full", "", c.reps);
        const folds_ns = try requestNs(gpa, io, c.text, "textDocument/foldingRange", "", c.reps);
        const symbols_ns = try requestNs(gpa, io, c.text, "textDocument/documentSymbol", "", c.reps);
        mahina.io.print("{s: <30} {d: >9} {d: >14.2} {d: >10.2} {d: >10.2}\n", .{
            c.name, c.text.len, ms(tokens_ns), ms(folds_ns), ms(symbols_ns),
        });
    }

    // The cursor past the last line: the worst case for the requests that lex
    // from the start of the document to the cursor (doc 74 §7.3).
    mahina.io.print(
        \\
        \\library requests with the cursor at the end of the document (doc 74 §7.3; best of N, ms)
        \\
        \\{s: <30} {s: >9} {s: >10} {s: >14} {s: >12}
        \\
    , .{ "case", "bytes", "hover", "signatureHelp", "completion" });
    for (cases.items[0..3]) |c| {
        var lines: usize = 0;
        for (c.text) |ch| lines += @intFromBool(ch == '\n');
        const tail = try std.fmt.allocPrint(gpa, ",\"position\":{{\"line\":{d},\"character\":0}}", .{lines});
        defer gpa.free(tail);
        const hover_ns = try requestNs(gpa, io, c.text, "textDocument/hover", tail, c.reps);
        const sig_ns = try requestNs(gpa, io, c.text, "textDocument/signatureHelp", tail, c.reps);
        const complete_ns = try requestNs(gpa, io, c.text, "textDocument/completion", tail, c.reps);
        mahina.io.print("{s: <30} {d: >9} {d: >10.2} {d: >14.2} {d: >12.2}\n", .{
            c.name, c.text.len, ms(hover_ns), ms(sig_ns), ms(complete_ns),
        });
    }

    mahina.io.print(
        \\
        \\cross-file: a literal require per block, half resolving nowhere, real disk (doc 74 §7.4; best of N, ms)
        \\
        \\{s: <30} {s: >9} {s: >9} {s: >10} {s: >10} {s: >8}
        \\
    , .{ "case", "bytes", "requires", "no disk", "disk", "added" });
    try writeModules(io);
    defer std.Io.Dir.cwd().deleteTree(io, cross_dir) catch {};
    const cross = [_]struct { name: []const u8, lines: usize, reps: usize }{
        .{ .name = "1k lines", .lines = 1_000, .reps = 20 },
        .{ .name = "10k lines", .lines = 10_000, .reps = 10 },
        .{ .name = "100k lines", .lines = 100_000, .reps = 5 },
    };
    for (cross) |c| {
        const text = try realistic(gpa, c.lines, 0, true);
        defer gpa.free(text);
        const no_disk = try crossFile(gpa, io, text, null, c.reps);
        const disk = try crossFile(gpa, io, text, lsp.host_stdio.disk, c.reps);
        mahina.io.print("{s: <30} {d: >9} {d: >9} {d: >10.2} {d: >10.2} {d: >8.2}\n", .{
            c.name,
            text.len,
            std.mem.count(u8, text, "require("),
            ms(no_disk),
            ms(disk),
            ms(disk) - ms(no_disk),
        });
    }

    mahina.io.print(
        \\
        \\module members: completion after `m.` for a module on disk exporting every block's function (doc 74 §7.4; best of N, ms)
        \\
        \\{s: <30} {s: >9} {s: >9} {s: >10} {s: >10}
        \\
    , .{ "module", "bytes", "exports", "cold", "warm" });
    for (cross) |c| {
        const n = try writeBigModule(gpa, io, c.lines);
        const got = try moduleMembers(gpa, io, c.reps);
        const stat = try std.Io.Dir.cwd().statFile(io, cross_dir ++ "/big.mah", .{});
        mahina.io.print("{s: <30} {d: >9} {d: >9} {d: >10.2} {d: >10.2}\n", .{ c.name, stat.size, n, ms(got.cold), ms(got.warm) });
    }

    const base = cases.items[1].text;
    mahina.io.print("\nedit burst: 200 one-character edits + the one analysis they cost (10k lines): {d:.2} ms\n", .{ms(try editBurst(gpa, io, base))});
    const small = cases.items[0].text;
    const many = try manyDocuments(gpa, io, small);
    mahina.io.print("50 open documents of 1k lines, one tick analysing the 49 new ones: {d:.2} ms, peak {d:.1} MiB\n", .{
        ms(many.ns),
        @as(f64, @floatFromInt(many.peak)) / (1024.0 * 1024.0),
    });
}
