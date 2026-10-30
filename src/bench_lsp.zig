//! Doc 74 §9 — `zig build bench-lsp` (ReleaseFast).
//!
//! The language server's performance budget, measured per stage and end to
//! end: from a change arriving to the diagnostics message being encoded
//! (debounce excluded), over realistic files at 1k / 10k / 100k lines and the
//! adversarial corpus (one 1 MB line of astral characters, 60k distinct
//! constants, 500-deep nesting, a file broken every 20 lines, an edit burst of
//! 200 changes, 50 open documents), the cost `require` resolution adds
//! against the real disk, and member completion on a required module, cold and
//! from the module cache, and the workspace symbol index over 1k, 10k and
//! 100k files on disk: built cold and from its saved copy, and searched
//! (doc 74 §7.4).
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

const symbols_dir = "/tmp/mahina-bench-lsp-symbols";
const symbols_cache = "/tmp/mahina-bench-lsp-cache";

/// `files` files of about 100 lines each, 100 to a directory, under
/// `symbols_dir`; file `k` defines `w<k>_0` … `w<k>_7`. Every file first
/// calls the global `shared_log`, and one in 100 then writes the global
/// `shared_total`.
fn writeWorkspace(gpa: std.mem.Allocator, io: std.Io, files: usize) !void {
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, symbols_dir) catch {};
    const text = try realistic(gpa, 100, 0, false);
    defer gpa.free(text);
    for (0..files) |k| {
        var buf: [128]u8 = undefined;
        const dir = try std.fmt.bufPrint(&buf, symbols_dir ++ "/d_{d}", .{k / 100});
        if (k % 100 == 0) try cwd.createDirPath(io, dir);
        var pbuf: [160]u8 = undefined;
        const path = try std.fmt.bufPrint(&pbuf, "{s}/f_{d}.mah", .{ dir, k });
        var nbuf: [32]u8 = undefined;
        const own = try std.mem.replaceOwned(u8, gpa, text, "work_", try std.fmt.bufPrint(&nbuf, "w{d}_", .{k}));
        defer gpa.free(own);
        var hbuf: [96]u8 = undefined;
        const head = try std.fmt.bufPrint(&hbuf, "shared_log(\"f_{d}\")\n{s}", .{ k, if (k % 100 == 0) "shared_total = (shared_total or 0) + 1\n" else "" });
        const whole = try std.mem.concat(gpa, u8, &.{ head, own });
        defer gpa.free(whole);
        try cwd.writeFile(io, .{ .sub_path = path, .data = whole });
    }
}

const WorkspaceSymbols = struct {
    /// Initialize to an idle index: no saved index, then from the saved one.
    cold: u64,
    restart: u64,
    /// `workspace/symbol` for a watching client: a narrow query, a broad one
    /// (every name matches), and the narrow one after one file is rewritten
    /// and reported.
    narrow: u64,
    broad: u64,
    changed: u64,
    /// For a client that cannot watch, so the index polls: the narrow
    /// query, and what an idle second costs on average over `max_check_ms`
    /// (a round of directory stamps and the files that came due), in time
    /// and in stamps.
    unwatched: u64,
    idle: u64,
    idle_stamps: u64,
    /// From an open file: references to and a rename of the global one in
    /// 100 files write, and references to the one every file calls.
    refs_some: u64,
    rename_some: u64,
    refs_all: u64,
    rename_all: u64,
    symbols: usize,
    live: usize,
    peak: usize,
    saved_bytes: u64,
};

fn symbolServer(ta: std.mem.Allocator, store: *lsp.host_stdio.DiskStore, out: *server.Outbox) !server.Server {
    var core = server.Server.init(ta, .{});
    core.files = lsp.host_stdio.disk;
    core.store = store.store();
    try core.handle(0, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"capabilities\":{\"workspace\":{\"didChangeWatchedFiles\":{\"dynamicRegistration\":true}}},\"rootUri\":\"file://" ++ symbols_dir ++ "\"}}", out);
    try core.handle(0, "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}", out);
    return core;
}

/// Tick until the index is idle, as the host does with nothing to read.
fn settle(core: *server.Server, out: *server.Outbox) !void {
    while (core.nextDeadline() != null) {
        out.reset();
        try core.tick(5, out);
    }
}

fn timedRequest(io: std.Io, core: *server.Server, out: *server.Outbox, body: []const u8) !u64 {
    out.reset();
    const t0 = now(io);
    try core.handle(10, body, out);
    const t1 = now(io);
    if (out.messages().len != 1) return error.NoResponse;
    return @intCast(t1 - t0);
}

fn query(comptime q: []const u8) []const u8 {
    return "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"" ++ q ++ "\"}}";
}

/// `workspace/symbol` over `symbols_dir`, with the index kept under
/// `symbols_cache` (see `WorkspaceSymbols`); best of `reps`, queries best of
/// 10 each.
fn workspaceSymbols(gpa: std.mem.Allocator, io: std.Io, files: usize, reps: usize) !WorkspaceSymbols {
    var tracker = mahina.mem.TrackingAllocator.init(gpa);
    const ta = tracker.allocator();
    var store: lsp.host_stdio.DiskStore = .{ .dir = symbols_cache };
    var r: WorkspaceSymbols = .{
        .cold = std.math.maxInt(u64),
        .restart = std.math.maxInt(u64),
        .narrow = std.math.maxInt(u64),
        .broad = std.math.maxInt(u64),
        .changed = std.math.maxInt(u64),
        .unwatched = std.math.maxInt(u64),
        .idle = std.math.maxInt(u64),
        .idle_stamps = 0,
        .refs_some = std.math.maxInt(u64),
        .rename_some = std.math.maxInt(u64),
        .refs_all = std.math.maxInt(u64),
        .rename_all = std.math.maxInt(u64),
        .symbols = 0,
        .live = 0,
        .peak = 0,
        .saved_bytes = 0,
    };
    const narrow = query("w123_4");
    const broad = query("w");
    const edited = symbols_dir ++ "/d_0/f_0.mah";
    const report = "{\"jsonrpc\":\"2.0\",\"method\":\"workspace/didChangeWatchedFiles\",\"params\":{\"changes\":[{\"uri\":\"file://" ++ edited ++ "\",\"type\":2}]}}";
    for (0..reps) |rep| {
        var out = server.Outbox.init(ta);
        defer out.deinit();
        // No saved index: every file is parsed, and the index saved.
        std.Io.Dir.cwd().deleteTree(io, symbols_cache) catch {};
        {
            tracker.stats.peak_bytes = tracker.stats.live_bytes;
            const t0 = now(io);
            var core = try symbolServer(ta, &store, &out);
            defer core.deinit();
            try settle(&core, &out);
            const t1 = now(io);
            r.cold = @min(r.cold, @as(u64, @intCast(t1 - t0)));
            r.peak = @max(r.peak, tracker.stats.peak_bytes);
            if (core.symbols.truncated) return error.Truncated;
            if (core.symbols.saves != 1) return error.NotSaved;
        }
        // The next session: the saved index loaded, every file stamped, none
        // parsed.
        const t0 = now(io);
        var core = try symbolServer(ta, &store, &out);
        defer core.deinit();
        try settle(&core, &out);
        const t1 = now(io);
        r.restart = @min(r.restart, @as(u64, @intCast(t1 - t0)));
        if (core.symbols.builds != 0) return error.Reparsed;
        r.live = tracker.stats.live_bytes;
        // Before this bench's own edits below.
        if (rep == 0) r.symbols = core.symbols.symbolCount();

        for (0..10) |_| {
            r.narrow = @min(r.narrow, try timedRequest(io, &core, &out, narrow));
            r.broad = @min(r.broad, try timedRequest(io, &core, &out, broad));
        }
        for (0..3) |k| {
            var buf: [64]u8 = undefined;
            const text = try std.fmt.bufPrint(&buf, "function edited_{d}_{d}() end\n", .{ rep, k });
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = edited, .data = text });
            const builds = core.symbols.builds;
            out.reset();
            const t2 = now(io);
            try core.handle(20, report, &out);
            try core.handle(20, narrow, &out);
            const t3 = now(io);
            if (core.symbols.builds != builds + 1) return error.ChangeMissed;
            r.changed = @min(r.changed, @as(u64, @intCast(t3 - t2)));
        }
        // The client takes back its watcher: the folder is walked once more
        // to record its directories, then polled.
        out.reset();
        try core.handle(30, "{\"jsonrpc\":\"2.0\",\"id\":\"mahina/watch-files\",\"error\":{\"code\":-32601,\"message\":\"unsupported\"}}", &out);
        while (core.symbols.busy()) {
            out.reset();
            try core.tick(30, &out);
        }
        for (0..3) |_| r.unwatched = @min(r.unwatched, try timedRequest(io, &core, &out, narrow));
        // Idle for `max_check_ms`, ticked as the host would; meanwhile a
        // file is created (its directory's stamp moves) and a long-unchanged
        // one edited in place (it does not), and both must show.
        const created = symbols_dir ++ "/d_0/created.mah";
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = created, .data = "function created_here() end\n" });
        defer std.Io.Dir.cwd().deleteFile(io, created) catch {};
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = symbols_dir ++ "/d_5/f_500.mah", .data = "function edited_in_place() end\n" });
        const builds = core.symbols.builds;
        const stamps = core.symbols.stamps;
        const seconds = lsp.symbol_index.max_check_ms / 1000;
        const t4 = now(io);
        var clock: u64 = 1000;
        while (clock <= 1000 * @as(u64, seconds)) : (clock += 1000) {
            while (core.nextDeadline()) |due| {
                if (due > clock) break;
                out.reset();
                try core.tick(clock, &out);
            }
        }
        const t5 = now(io);
        // Each parsed when found changed, and once more a second later
        // (`Entry.again`); so is `edited`, reported changed above, once more.
        if (core.symbols.builds != builds + 5) return error.PollMissed;
        r.idle = @min(r.idle, @as(u64, @intCast(t5 - t4)) / seconds);
        r.idle_stamps = (core.symbols.stamps - stamps) / seconds;
        out.reset();

        // Globals across the files, from one of them, open. `f_0` and
        // `f_500` were rewritten above without either global.
        const users = files - 2;
        const writers = files / 100 - 2;
        const opened = symbols_dir ++ "/d_1/f_100.mah";
        const text = try std.Io.Dir.cwd().readFileAlloc(io, opened, gpa, .unlimited);
        defer gpa.free(text);
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        try aw.writer.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://" ++ opened ++ "\",\"version\":1,\"text\":");
        try std.json.Stringify.value(text, .{}, &aw.writer);
        try aw.writer.writeAll("}}}");
        try core.handle(clock, aw.written(), &out);
        const at = "{{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"textDocument/{s}\",\"params\":{{\"textDocument\":{{\"uri\":\"file://" ++ opened ++ "\"}},\"position\":{{\"line\":{d},\"character\":0}}{s}}}}}";
        const all = ",\"context\":{\"includeDeclaration\":true}";
        var qbuf: [512]u8 = undefined;
        const refs_some = try std.fmt.bufPrint(&qbuf, at, .{ "references", 1, all });
        out.reset();
        try core.handle(clock, refs_some, &out); // analyses the document
        for (0..3) |_| {
            r.refs_some = @min(r.refs_some, try timedRequest(io, &core, &out, refs_some));
            if (std.mem.count(u8, out.messages()[0], "\"uri\"") != 2 * writers) return error.ReferencesMissed;
        }
        var rbuf: [512]u8 = undefined;
        const rename_some = try std.fmt.bufPrint(&rbuf, at, .{ "rename", 1, ",\"newName\":\"shared_count\"" });
        for (0..3) |_| {
            r.rename_some = @min(r.rename_some, try timedRequest(io, &core, &out, rename_some));
            if (std.mem.count(u8, out.messages()[0], "\"newText\"") != 2 * writers) return error.RenameMissed;
        }
        var abuf: [512]u8 = undefined;
        const refs_all = try std.fmt.bufPrint(&abuf, at, .{ "references", 0, all });
        r.refs_all = @min(r.refs_all, try timedRequest(io, &core, &out, refs_all));
        if (std.mem.count(u8, out.messages()[0], "\"uri\"") != users) return error.ReferencesMissed;
        var nbuf: [512]u8 = undefined;
        const rename_all = try std.fmt.bufPrint(&nbuf, at, .{ "rename", 0, ",\"newName\":\"shared_trace\"" });
        r.rename_all = @min(r.rename_all, try timedRequest(io, &core, &out, rename_all));
        if (std.mem.count(u8, out.messages()[0], "\"newText\"") != users) return error.RenameMissed;


    }
    var dir = try std.Io.Dir.cwd().openDir(io, symbols_cache, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterateAssumeFirstIteration();
    while (try it.next(io)) |e| {
        const st = try dir.statFile(io, e.name, .{});
        r.saved_bytes += st.size;
    }
    return r;
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

    mahina.io.print(
        \\
        \\workspace symbols: a folder on disk, files of 100 lines, the index kept in a cache directory (doc 74 §7.4; best of N, ms)
        \\  cold / restart: initialize until the index is idle, with no saved index / from the saved one
        \\  narrow / broad: `workspace/symbol` for a watching client, "w123_4" / "w" (every name matches)
        \\  1 change: one file rewritten, reported, and the narrow query
        \\  polling: for a client that cannot watch, the narrow query; idle/s and stamps/s: an idle second's polling, averaged over 5 minutes
        \\  refs 1% / rename 1%: from an open file, references to and a rename of a global one file in 100 writes
        \\  refs all / rename all: references to and a rename of a global every file calls
        \\
        \\{s: <12} {s: >8} {s: >10} {s: >9} {s: >9} {s: >8} {s: >8} {s: >9} {s: >8} {s: >8} {s: >9} {s: >8} {s: >10} {s: >9} {s: >10} {s: >10} {s: >9} {s: >10}
        \\
    , .{ "folder", "files", "symbols", "cold", "restart", "narrow", "broad", "1 change", "polling", "idle/s", "stamps/s", "refs 1%", "rename 1%", "refs all", "rename all", "index MiB", "peak MiB", "saved MiB" });
    defer std.Io.Dir.cwd().deleteTree(io, symbols_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, symbols_cache) catch {};
    const folders = [_]struct { name: []const u8, files: usize, reps: usize }{
        .{ .name = "1k files", .files = 1_000, .reps = 5 },
        .{ .name = "10k files", .files = 10_000, .reps = 3 },
        .{ .name = "100k files", .files = 100_000, .reps = 1 },
    };
    const mib = 1024.0 * 1024.0;
    for (folders) |f| {
        try writeWorkspace(gpa, io, f.files);
        const got = try workspaceSymbols(gpa, io, f.files, f.reps);
        mahina.io.print("{s: <12} {d: >8} {d: >10} {d: >9.1} {d: >9.1} {d: >8.2} {d: >8.2} {d: >9.2} {d: >8.2} {d: >8.2} {d: >9} {d: >8.1} {d: >10.1} {d: >9.1} {d: >10.1} {d: >10.1} {d: >9.1} {d: >10.1}\n", .{
            f.name,
            f.files,
            got.symbols,
            ms(got.cold),
            ms(got.restart),
            ms(got.narrow),
            ms(got.broad),
            ms(got.changed),
            ms(got.unwatched),
            ms(got.idle),
            got.idle_stamps,
            ms(got.refs_some),
            ms(got.rename_some),
            ms(got.refs_all),
            ms(got.rename_all),
            @as(f64, @floatFromInt(got.live)) / mib,
            @as(f64, @floatFromInt(got.peak)) / mib,
            @as(f64, @floatFromInt(got.saved_bytes)) / mib,
        });
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
