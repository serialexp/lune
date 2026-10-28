//! Completion of keywords and the names visible at the cursor (doc 74 §7.2).
//!
//! The client filters by the typed prefix, so this returns every candidate. A
//! cursor in a string or comment, on a name being declared, or after `.` / `:`
//! (member access, which needs the stdlib tables of P5) gets nothing.

const std = @import("std");
const lexer = @import("../lexer.zig");
const resolve = @import("../resolve.zig");
const token = @import("../token.zig");
const analysis_mod = @import("analysis.zig");
const navigation = @import("navigation.zig");

const Analysis = analysis_mod.Analysis;

pub const Kind = enum { variable, function, keyword };

pub const Item = struct {
    label: []const u8,
    kind: Kind,
    /// One word on where the name comes from.
    detail: []const u8,
    /// Locals first, then the file's globals, host globals, keywords.
    rank: u8,
};

fn isIdentByte(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

/// The cursor follows `.` or `:` before the identifier it is in: `t.fo|`,
/// `obj:me|`. `..` and `...` are not member access.
fn afterMemberAccess(src: []const u8, offset: u32) bool {
    var i: usize = @min(offset, src.len);
    while (i > 0 and isIdentByte(src[i - 1])) i -= 1;
    if (i == 0) return false;
    return switch (src[i - 1]) {
        ':' => true,
        '.' => !(i >= 2 and src[i - 2] == '.'),
        else => false,
    };
}

fn detailOf(kind: resolve.Kind) []const u8 {
    return switch (kind) {
        .local => "local",
        .param => "parameter",
        .self => "self",
        .for_var => "loop variable",
        .local_function => "local function",
        .global => "global",
    };
}

pub fn complete(
    a: std.mem.Allocator,
    an: *const Analysis,
    known_globals: []const []const u8,
    offset: u32,
) std.mem.Allocator.Error![]const Item {
    switch (try lexer.contextAt(a, an.source, offset)) {
        .code => {},
        .string, .comment => return &.{},
    }
    if (afterMemberAccess(an.source, offset)) return &.{};
    const under = an.res.occurrenceCovering(offset);
    if (under) |o| if (o.access == .declare) return &.{}; // naming something new

    var items: std.ArrayList(Item) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    const bindings = an.res.bindings.items;

    // Locals visible here. A later declaration of a spelling is the nearer one,
    // so walking backwards the first of each name wins. The cursor may sit
    // right at the closing keyword, still inside the block.
    var i = bindings.len;
    while (i > 0) {
        i -= 1;
        const b = bindings[i];
        // Strictly after `visible_from`: a cursor at the end of the value being
        // typed (`local x = fo|`) is still inside the initializer, where `x`
        // is not yet the new local.
        if (b.kind == .global or b.visible_from >= offset or offset > b.scope_end) continue;
        if ((try seen.getOrPut(a, b.name)).found_existing) continue;
        try items.append(a, .{
            .label = b.name,
            .kind = if (b.kind == .local_function) .function else .variable,
            .detail = detailOf(b.kind),
            .rank = 0,
        });
    }

    // Globals the file assigns. One that is only read is a typo as likely as a
    // definition elsewhere, so it is not offered; nor is the name being typed.
    for (bindings, 0..) |b, id| {
        if (b.kind != .global) continue;
        const first = an.res.occurrenceAt(b.decl_span.start) orelse continue;
        if (first.access != .write and first.access != .read_write) continue;
        if (under) |u| if (u.binding == id and onlyOccurrence(an, @intCast(id))) continue;
        if ((try seen.getOrPut(a, b.name)).found_existing) continue;
        try items.append(a, .{ .label = b.name, .kind = .variable, .detail = "global", .rank = 1 });
    }

    for (known_globals) |g| {
        // Some host names are compiler intrinsics (`@codes_iter`) no source can spell.
        if (!navigation.isIdentifier(g)) continue;
        if ((try seen.getOrPut(a, g)).found_existing) continue;
        try items.append(a, .{ .label = g, .kind = .variable, .detail = "built-in global", .rank = 2 });
    }

    for (token.keywords.keys()) |k| {
        if ((try seen.getOrPut(a, k)).found_existing) continue;
        try items.append(a, .{ .label = k, .kind = .keyword, .detail = "keyword", .rank = 3 });
    }
    return items.items;
}

fn onlyOccurrence(an: *const Analysis, binding: resolve.BindingId) bool {
    var n: usize = 0;
    for (an.res.occurrences.items) |o| {
        if (o.binding == binding) n += 1;
        if (n > 1) return false;
    }
    return true;
}

// ---- tests -------------------------------------------------------------------

const testing = std.testing;
const known = [_][]const u8{ "print", "pairs", "@intrinsic" };

/// Complete at the `|` in `marked`; the caller frees nothing (an arena).
fn completeAt(arena: std.mem.Allocator, marked: []const u8) ![]const Item {
    const bar = std.mem.find(u8, marked, "|").?;
    const src = try std.mem.concat(arena, u8, &.{ marked[0..bar], marked[bar + 1 ..] });
    var an = try analysis_mod.analyse(testing.allocator, src, &known, .{});
    defer an.deinit();
    const items = try complete(arena, &an, &known, @intCast(bar));
    // `an` owns the label text of locals; copy it out before it goes.
    const out = try arena.alloc(Item, items.len);
    for (items, out) |it, *slot| {
        slot.* = it;
        slot.label = try arena.dupe(u8, it.label);
    }
    return out;
}

fn find(items: []const Item, label: []const u8) ?Item {
    for (items) |it| if (std.mem.eql(u8, it.label, label)) return it;
    return null;
}

test "completion: locals in scope, nearest shadowing, then globals, host names, keywords" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const items = try completeAt(arena.allocator(),
        \\g = 1
        \\local x = 1
        \\local function f(p)
        \\  local x = 2
        \\  |
        \\end
    );
    try testing.expectEqualStrings("local", find(items, "x").?.detail);
    var xs: usize = 0;
    for (items) |it| {
        if (std.mem.eql(u8, it.label, "x")) xs += 1;
    }
    try testing.expectEqual(@as(usize, 1), xs);
    try testing.expectEqualStrings("parameter", find(items, "p").?.detail);
    try testing.expectEqual(Kind.function, find(items, "f").?.kind);
    try testing.expectEqualStrings("global", find(items, "g").?.detail);
    try testing.expectEqualStrings("built-in global", find(items, "print").?.detail);
    try testing.expect(find(items, "@intrinsic") == null);
    try testing.expectEqual(Kind.keyword, find(items, "while").?.kind);
}

test "completion: a name is offered only where it is visible" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Before the declaration finishes, and after its block closed.
    try testing.expect(find(try completeAt(a, "local x = fo|"), "x") == null);
    try testing.expect(find(try completeAt(a, "local x = 1\n|"), "x") != null);
    try testing.expect(find(try completeAt(a, "do local inner = 1 end\n|"), "inner") == null);
    // Right up to the closing keyword, and in a sibling branch it is gone.
    try testing.expect(find(try completeAt(a, "do local inner = 1 |end"), "inner") != null);
    try testing.expect(find(try completeAt(a, "if a then local c = 1 else |end"), "c") == null);
    try testing.expect(find(try completeAt(a, "repeat local r = 1 until |r"), "r") != null);
}

test "completion: nothing in strings, comments, declarations or after a member dot" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(@as(usize, 0), (try completeAt(a, "x = \"ab|c\"")).len);
    try testing.expectEqual(@as(usize, 0), (try completeAt(a, "-- note |")).len);
    try testing.expectEqual(@as(usize, 0), (try completeAt(a, "local fo|")).len);
    try testing.expectEqual(@as(usize, 0), (try completeAt(a, "local t = {}\nt.fo|")).len);
    try testing.expectEqual(@as(usize, 0), (try completeAt(a, "obj:|")).len);
    try testing.expect((try completeAt(a, "x = a ..|")).len > 0);
}

test "completion: a global that is only read, or is being typed, is not offered" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect(find(try completeAt(a, "print(typo)\n|"), "typo") == null);
    try testing.expect(find(try completeAt(a, "zzz| = 1\nx = 2"), "zzz") == null);
    try testing.expect(find(try completeAt(a, "x = 1\n|"), "x") != null);
}
