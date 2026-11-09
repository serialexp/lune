//! Doc 83 §10 — `zig build bench-fmt` (ReleaseFast).
//!
//! The formatter's performance budget: 100 ms for a 5,000-line file, linear in
//! input size, over realistic code and the adversarial shapes the design names
//! (50,000 lines of wide argument lists, long operator chains and dense
//! comments; one 1 MB line; nesting of depth 200 of tables and calls). Each
//! case reports best-of-reps time, the output size and peak memory; the
//! nesting series reports time per level so a quadratic printer shows up as a
//! growing column. Informational, not a gate (global Rule #22): run it
//! deliberately, on a quiet machine, and compare against itself.

const std = @import("std");
const mahina = @import("mahina");

const format = mahina.format;

fn now(io: std.Io) i96 {
    return std.Io.Timestamp.now(io, .awake).nanoseconds;
}

fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
}

// ---- corpus -----------------------------------------------------------------

fn realistic(gpa: std.mem.Allocator, lines: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var line: usize = 0;
    var i: usize = 0;
    while (line < lines) : (i += 1) {
        try out.print(gpa,
            \\-- block {d}: totals for the items
            \\local function work_{d}(items, scale)
            \\  local total = 0
            \\  for idx = 1, #items do
            \\    local item = items[idx] -- the current one
            \\    if item.kind == "a" then
            \\      total = total + item.value * scale
            \\    else
            \\      total = total - (item.value or 0)
            \\    end
            \\  end
            \\  local cache = {{ total = total, label = "block_{d}", parts = {{ 1, 2, 3 }}, nested = {{ x = 1, f = function() return 1 end }} }}
            \\  return function(extra) return cache.total + extra + #cache.parts end
            \\end
            \\
        , .{ i, i, i });
        line += 15;
    }
    return out.toOwnedSlice(gpa);
}

/// `lines` lines of one call with `args` arguments each.
fn wideCalls(gpa: std.mem.Allocator, lines: usize, args: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (0..lines) |l| {
        try out.print(gpa, "call_{d}(", .{l});
        for (0..args) |a| {
            if (a != 0) try out.appendSlice(gpa, ", ");
            try out.print(gpa, "argument_{d}", .{a});
        }
        try out.appendSlice(gpa, ")\n");
    }
    return out.toOwnedSlice(gpa);
}

fn longChains(gpa: std.mem.Allocator, lines: usize, terms: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (0..lines) |l| {
        try out.print(gpa, "local x_{d} = ", .{l});
        for (0..terms) |t| {
            if (t != 0) try out.appendSlice(gpa, " + ");
            try out.print(gpa, "term_{d}", .{t});
        }
        try out.appendSlice(gpa, "\n");
    }
    return out.toOwnedSlice(gpa);
}

fn denseComments(gpa: std.mem.Allocator, lines: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (0..lines / 3) |l| {
        try out.print(gpa, "-- a leading comment for {d}\n-- and a second line\nlocal v_{d} = {d} -- trailing\n", .{ l, l, l });
    }
    return out.toOwnedSlice(gpa);
}

fn oneLine(gpa: std.mem.Allocator, bytes: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "local t = { ");
    var n: usize = 0;
    while (out.items.len < bytes) : (n += 1) try out.print(gpa, "{d}, ", .{n});
    try out.appendSlice(gpa, "}\n");
    return out.toOwnedSlice(gpa);
}

fn nestedTables(gpa: std.mem.Allocator, depth: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "return ");
    for (0..depth) |_| try out.appendSlice(gpa, "{ a = ");
    try out.appendSlice(gpa, "1");
    for (0..depth) |_| try out.appendSlice(gpa, " }");
    try out.appendSlice(gpa, "\n");
    return out.toOwnedSlice(gpa);
}

fn nestedCalls(gpa: std.mem.Allocator, depth: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "return ");
    for (0..depth) |_| try out.appendSlice(gpa, "f(x, ");
    try out.appendSlice(gpa, "1");
    for (0..depth) |_| try out.appendSlice(gpa, ")");
    try out.appendSlice(gpa, "\n");
    return out.toOwnedSlice(gpa);
}

// ---- measuring --------------------------------------------------------------

const Measure = struct { best_ns: u64, out_bytes: usize, peak: usize, bd: format.Breakdown };

fn measure(gpa: std.mem.Allocator, io: std.Io, text: []const u8, reps: usize) !Measure {
    var best: u64 = std.math.maxInt(u64);
    var out_bytes: usize = 0;
    for (0..reps) |_| {
        var diags = mahina.diag.Diagnostics.init(gpa);
        defer diags.deinit();
        const t0 = now(io);
        const out = try format.format(gpa, text, &diags);
        const t1 = now(io);
        out_bytes = out.len;
        gpa.free(out);
        best = @min(best, @as(u64, @intCast(t1 - t0)));
    }
    var tracker = mahina.mem.TrackingAllocator.init(gpa);
    var diags = mahina.diag.Diagnostics.init(tracker.allocator());
    defer diags.deinit();
    var bd: format.Breakdown = .{};
    const out = try format.formatMeasured(tracker.allocator(), text, &diags, &bd);
    tracker.allocator().free(out);
    return .{ .best_ns = best, .out_bytes = out_bytes, .peak = tracker.stats.peak_bytes, .bd = bd };
}

fn lineCount(text: []const u8) usize {
    return std.mem.count(u8, text, "\n");
}

fn report(gpa: std.mem.Allocator, io: std.Io, name: []const u8, text: []const u8, reps: usize) !void {
    const m = try measure(gpa, io, text, reps);
    mahina.io.print("{s:<34} {d:>9} B {d:>7} lines  {d:>9.2} ms  out {d:>9} B  peak {d:>7.1} MB\n", .{
        name,
        text.len,
        lineCount(text),
        ms(m.best_ns),
        m.out_bytes,
        @as(f64, @floatFromInt(m.peak)) / (1024.0 * 1024.0),
    });
    // Each phase as a multiple of the input size.
    const in: f64 = @floatFromInt(@max(text.len, 1));
    const x = struct {
        fn f(n: usize, d: f64) f64 {
            return @as(f64, @floatFromInt(n)) / d;
        }
    }.f;
    mahina.io.print("{s:<34} peak {d:.1}x = parse {d:.1}x (tokens {d:.1}x) + trivia {d:.1}x + doc {d:.1}x + printer {d:.1}x + out {d:.1}x\n", .{
        "",
        x(m.peak, in),
        x(m.bd.parse_arena, in),
        x(m.bd.tokens, in),
        x(m.bd.trivia, in),
        x(m.bd.doc_arena, in),
        x(m.bd.printer.work_bytes, in),
        x(m.bd.output, in),
    });
}

pub fn main(init: std.process.Init) u8 {
    run(init.gpa, init.io) catch |e| {
        mahina.io.eprint("bench-fmt: error: {s}\n", .{@errorName(e)});
        return 1;
    };
    return 0;
}

fn run(gpa: std.mem.Allocator, io: std.Io) !void {
    mahina.io.print("budget (doc 83 §10): <= 100 ms for 5,000 lines, linear in input size\n\n", .{});
    {
        const t = try realistic(gpa, 5_000);
        defer gpa.free(t);
        try report(gpa, io, "realistic 5k lines (budget)", t, 10);
    }
    {
        const t = try realistic(gpa, 50_000);
        defer gpa.free(t);
        try report(gpa, io, "realistic 50k lines", t, 5);
    }
    {
        const t = try wideCalls(gpa, 50_000, 40);
        defer gpa.free(t);
        try report(gpa, io, "50k lines of 40-argument calls", t, 3);
    }
    {
        const t = try longChains(gpa, 50_000, 40);
        defer gpa.free(t);
        try report(gpa, io, "50k lines of 40-term chains", t, 3);
    }
    {
        const t = try denseComments(gpa, 50_000);
        defer gpa.free(t);
        try report(gpa, io, "50k lines, dense comments", t, 3);
    }
    {
        const t = try oneLine(gpa, 1 << 20);
        defer gpa.free(t);
        try report(gpa, io, "one 1 MB line (array literal)", t, 3);
    }

    mahina.io.print("\nnesting: time per level should stay flat as depth grows\n", .{});
    // The parser stops at `parser.max_depth` (200) levels, so the series ends below it.
    for ([_]usize{ 25, 50, 100, 190 }) |depth| {
        const t = try nestedTables(gpa, depth);
        defer gpa.free(t);
        var buf: [48]u8 = undefined;
        try report(gpa, io, try std.fmt.bufPrint(&buf, "nested tables, depth {d}", .{depth}), t, 20);
    }
    for ([_]usize{ 25, 50, 100, 190 }) |depth| {
        const t = try nestedCalls(gpa, depth);
        defer gpa.free(t);
        var buf: [48]u8 = undefined;
        try report(gpa, io, try std.fmt.bufPrint(&buf, "nested calls, depth {d}", .{depth}), t, 20);
    }
}
