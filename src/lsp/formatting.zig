//! `textDocument/formatting` and `rangeFormatting` (doc 83 §8.2): the
//! formatter's output turned into line-sized edits.
//!
//! The whole file is always formatted; what a range request returns is the
//! subset of the changed hunks that touch the range, so the answer is exactly
//! what whole-document formatting would produce there. Hunks come from a line
//! diff (Myers, bounded) so the editor keeps cursors and undo history on the
//! lines that did not change.

const std = @import("std");
const Allocator = std.mem.Allocator;
const position = @import("position.zig");
const protocol = @import("protocol.zig");

/// The most edit steps the diff explores before it gives up and replaces the
/// whole differing middle in one edit. Bounds time and memory (both
/// quadratic in this) at a few MB however large the file.
pub const max_edit_steps: usize = 1000;

/// A changed region: old lines `[a_start, a_end)` become new lines
/// `[b_start, b_end)`.
pub const Hunk = struct { a_start: usize, a_end: usize, b_start: usize, b_end: usize };

/// Lines of `text`, each keeping its `\n`, so a missing final newline is a
/// difference like any other.
fn splitLines(a: Allocator, text: []const u8) Allocator.Error![][]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var start: usize = 0;
    while (start < text.len) {
        const end = if (std.mem.indexOfScalarPos(u8, text, start, '\n')) |nl| nl + 1 else text.len;
        try lines.append(a, text[start..end]);
        start = end;
    }
    return lines.items;
}

/// The hunks that turn `old` into `new`, in order. Allocates in `a` (an
/// arena: the diff's working memory is not freed piecemeal).
pub fn diff(a: Allocator, old_all: []const []const u8, new_all: []const []const u8, max_steps: usize) Allocator.Error![]Hunk {
    var prefix: usize = 0;
    while (prefix < old_all.len and prefix < new_all.len and std.mem.eql(u8, old_all[prefix], new_all[prefix])) prefix += 1;
    var suffix: usize = 0;
    while (suffix < old_all.len - prefix and suffix < new_all.len - prefix and
        std.mem.eql(u8, old_all[old_all.len - 1 - suffix], new_all[new_all.len - 1 - suffix])) suffix += 1;
    const old = old_all[prefix .. old_all.len - suffix];
    const new = new_all[prefix .. new_all.len - suffix];
    const n = old.len;
    const m = new.len;
    var hunks: std.ArrayList(Hunk) = .empty;
    if (n == 0 and m == 0) return hunks.items;

    const whole = Hunk{ .a_start = prefix, .a_end = prefix + n, .b_start = prefix, .b_end = prefix + m };
    if (n == 0 or m == 0) {
        try hunks.append(a, whole);
        return hunks.items;
    }

    const limit = @min(n + m, max_steps);
    const off: isize = @intCast(limit + 1);
    const v = try a.alloc(isize, 2 * limit + 3);
    @memset(v, 0);
    var trace: std.ArrayList([]isize) = .empty;
    var found_d: ?usize = null;
    var d: usize = 0;
    search: while (d <= limit) : (d += 1) {
        const di: isize = @intCast(d);
        // The state before this round, for the walk back.
        try trace.append(a, try a.dupe(isize, v[@intCast(off - di - 1)..@intCast(off + di + 2)]));
        var k: isize = -di;
        while (k <= di) : (k += 2) {
            const ki: usize = @intCast(off + k);
            var x: isize = if (k == -di or (k != di and v[ki - 1] < v[ki + 1])) v[ki + 1] else v[ki - 1] + 1;
            var y = x - k;
            while (x < n and y < m and std.mem.eql(u8, old[@intCast(x)], new[@intCast(y)])) {
                x += 1;
                y += 1;
            }
            v[ki] = x;
            if (x >= n and y >= m) {
                found_d = d;
                break :search;
            }
        }
    }
    const last = found_d orelse {
        try hunks.append(a, whole);
        return hunks.items;
    };

    // Walk back, marking the deleted old lines and the inserted new ones.
    const del = try a.alloc(bool, n);
    const ins = try a.alloc(bool, m);
    @memset(del, false);
    @memset(ins, false);
    var x: isize = @intCast(n);
    var y: isize = @intCast(m);
    var step = last;
    while (step > 0) : (step -= 1) {
        const di: isize = @intCast(step);
        const snap = trace.items[step]; // v before round `step`, from k = -step-1
        const at = struct {
            fn f(s: []const isize, dd: isize, kk: isize) isize {
                return s[@intCast(kk + dd + 1)];
            }
        }.f;
        const k = x - y;
        const down = k == -di or (k != di and at(snap, di, k - 1) < at(snap, di, k + 1));
        const prev_k = if (down) k + 1 else k - 1;
        const prev_x = at(snap, di, prev_k);
        const prev_y = prev_x - prev_k;
        if (down) ins[@intCast(prev_y)] = true else del[@intCast(prev_x)] = true;
        x = prev_x;
        y = prev_y;
    }

    var i: usize = 0;
    var j: usize = 0;
    while (i < n or j < m) {
        if (i < n and j < m and !del[i] and !ins[j]) {
            i += 1;
            j += 1;
            continue;
        }
        const si = i;
        const sj = j;
        while ((i < n and del[i]) or (j < m and ins[j])) {
            if (i < n and del[i]) i += 1;
            if (j < m and ins[j]) j += 1;
        }
        try hunks.append(a, .{ .a_start = prefix + si, .a_end = prefix + i, .b_start = prefix + sj, .b_end = prefix + j });
    }
    return hunks.items;
}

/// A byte range of the document a range request covers.
pub const Span = struct { start: u32, end: u32 };

/// The edits that turn `text` into `formatted`; with `range`, only those
/// hunks that touch it (a hunk straddling the edge is kept whole). Strings
/// are borrowed from `formatted`; everything else is allocated in `a`.
pub fn edits(
    a: Allocator,
    index: *const position.LineIndex,
    text: []const u8,
    formatted: []const u8,
    enc: position.Encoding,
    range: ?Span,
    max_steps: usize,
) Allocator.Error![]const protocol.TextEdit {
    const old = try splitLines(a, text);
    const new = try splitLines(a, formatted);
    const hunks = try diff(a, old, new, max_steps);
    const old_off = try lineOffsets(a, old);
    const new_off = try lineOffsets(a, new);
    var out: std.ArrayList(protocol.TextEdit) = .empty;
    for (hunks) |h| {
        const s = old_off[h.a_start];
        const e = old_off[h.a_end];
        if (range) |r| {
            const touches = if (s == e) (r.start <= s and s <= r.end) else (s < r.end and e > r.start);
            if (!touches) continue;
        }
        try out.append(a, .{
            .range = index.toRange(text, @intCast(s), @intCast(e), enc),
            .newText = formatted[new_off[h.b_start]..new_off[h.b_end]],
        });
    }
    return out.items;
}

fn lineOffsets(a: Allocator, lines: []const []const u8) Allocator.Error![]usize {
    const offs = try a.alloc(usize, lines.len + 1);
    var at: usize = 0;
    for (lines, 0..) |l, i| {
        offs[i] = at;
        at += l.len;
    }
    offs[lines.len] = at;
    return offs;
}

const testing = std.testing;

fn hunksOf(a: Allocator, old: []const u8, new: []const u8, max_steps: usize) ![]Hunk {
    return diff(a, try splitLines(a, old), try splitLines(a, new), max_steps);
}

test "diff: identical text has no hunks; one changed line is one hunk" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(@as(usize, 0), (try hunksOf(a, "a\nb\nc\n", "a\nb\nc\n", 100)).len);
    const h = try hunksOf(a, "a\nb\nc\n", "a\nB\nc\n", 100);
    try testing.expectEqual(@as(usize, 1), h.len);
    try testing.expectEqual(Hunk{ .a_start = 1, .a_end = 2, .b_start = 1, .b_end = 2 }, h[0]);
}

test "diff: separate changes stay separate hunks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const h = try hunksOf(a, "a\nb\nc\nd\ne\n", "A\nb\nc\nd\nE\n", 100);
    try testing.expectEqual(@as(usize, 2), h.len);
    try testing.expectEqual(Hunk{ .a_start = 0, .a_end = 1, .b_start = 0, .b_end = 1 }, h[0]);
    try testing.expectEqual(Hunk{ .a_start = 4, .a_end = 5, .b_start = 4, .b_end = 5 }, h[1]);
}

test "diff: insertions and deletions in the middle" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ins = try hunksOf(a, "a\nb\nc\nd\ne\nf\n", "a\nb\nX\nc\nd\ne\nf\n", 100);
    try testing.expectEqual(@as(usize, 1), ins.len);
    try testing.expectEqual(Hunk{ .a_start = 2, .a_end = 2, .b_start = 2, .b_end = 3 }, ins[0]);
    const del = try hunksOf(a, "a\nb\nX\nc\nd\n", "a\nb\nc\nd\n", 100);
    try testing.expectEqual(@as(usize, 1), del.len);
    try testing.expectEqual(Hunk{ .a_start = 2, .a_end = 3, .b_start = 2, .b_end = 2 }, del[0]);
}

test "diff: past the step bound it falls back to one hunk over the middle" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const h = try hunksOf(a, "k\na\nb\nc\nd\nz\n", "k\nA\nb\nC\nd\nz\n", 1);
    try testing.expectEqual(@as(usize, 1), h.len);
    try testing.expectEqual(Hunk{ .a_start = 1, .a_end = 4, .b_start = 1, .b_end = 4 }, h[0]);
}

test "diff: applying the hunks to the old text gives the new text" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const old = "1\n2\n3\n4\n5\n6\n7\n8\n9\n";
    const new = "1\nx\n3\n5\n6\ny\nz\n8\n9\n0\n";
    const old_lines = try splitLines(a, old);
    const new_lines = try splitLines(a, new);
    const hs = try diff(a, old_lines, new_lines, 100);
    var rebuilt: std.ArrayList(u8) = .empty;
    var at: usize = 0;
    for (hs) |h| {
        for (old_lines[at..h.a_start]) |l| try rebuilt.appendSlice(a, l);
        for (new_lines[h.b_start..h.b_end]) |l| try rebuilt.appendSlice(a, l);
        at = h.a_end;
    }
    for (old_lines[at..]) |l| try rebuilt.appendSlice(a, l);
    try testing.expectEqualStrings(new, rebuilt.items);
}

test "edits: ranges, positions and range filtering" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = "local a=1\nlocal b = 2\nlocal c=3\n";
    const formatted = "local a = 1\nlocal b = 2\nlocal c = 3\n";
    const index = try position.LineIndex.build(testing.allocator, text);
    defer index.deinit(testing.allocator);
    const all = try edits(a, &index, text, formatted, .utf8, null, 100);
    try testing.expectEqual(@as(usize, 2), all.len);
    try testing.expectEqual(@as(u32, 0), all[0].range.start.line);
    try testing.expectEqual(@as(u32, 1), all[0].range.end.line);
    try testing.expectEqualStrings("local a = 1\n", all[0].newText);
    try testing.expectEqual(@as(u32, 2), all[1].range.start.line);
    // A range inside the last line only gets the last edit.
    const only = try edits(a, &index, text, formatted, .utf8, .{ .start = 25, .end = 27 }, 100);
    try testing.expectEqual(@as(usize, 1), only.len);
    try testing.expectEqualStrings("local c = 3\n", only[0].newText);
}

test "edits: a missing final newline is replaced, end of document included" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const index = try position.LineIndex.build(testing.allocator, "local x = 1");
    defer index.deinit(testing.allocator);
    const e = try edits(a, &index, "local x = 1", "local x = 1\n", .utf8, null, 100);
    try testing.expectEqual(@as(usize, 1), e.len);
    try testing.expectEqual(@as(u32, 11), e[0].range.end.character);
    try testing.expectEqualStrings("local x = 1\n", e[0].newText);
}
