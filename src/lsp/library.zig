//! Stdlib knowledge at the cursor (doc 74 §7.3): hover on a library name,
//! `lib.` member completion, and the call a cursor is in, for signature help.
//! Every answer is read from `stdlib_db`. A name whose head is a local is never
//! a library name, since a local can shadow `string`, so nothing is answered
//! for it.

const std = @import("std");
const ast = @import("../ast.zig");
const diag = @import("../diag.zig");
const lexer = @import("../lexer.zig");
const resolve = @import("../resolve.zig");
const system = @import("../system.zig");
const token = @import("../token.zig");
const analysis_mod = @import("analysis.zig");
const stdlib_db = @import("stdlib_db.zig");

const Analysis = analysis_mod.Analysis;

/// A library name at the cursor, and the span of the identifier written there.
pub const Named = struct {
    entry: *const stdlib_db.Entry,
    span: ast.Span,
};

/// One member of a library, offered after `lib.`.
pub const Member = struct {
    /// The member's own name: `format` for `string.format`.
    label: []const u8,
    entry: *const stdlib_db.Entry,
};

/// The call the cursor is inside.
pub const Call = struct {
    entry: *const stdlib_db.Entry,
    /// 0-based index of the argument the cursor is in.
    active: u32,
};

pub fn isIdentByte(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

/// The identifier containing `offset`, or ending at it. Null when there is none,
/// or when the run of identifier bytes is a numeral.
fn identifierAt(src: []const u8, offset: u32) ?ast.Span {
    const at: usize = @min(offset, src.len);
    var s = at;
    while (s > 0 and isIdentByte(src[s - 1])) s -= 1;
    var e = at;
    while (e < src.len and isIdentByte(src[e])) e += 1;
    if (s == e or isDigit(src[s])) return null;
    return .{ .start = @intCast(s), .end = @intCast(e) };
}

/// The identifier that ends at `end`, or null. The head of `head.` is one.
pub fn headEndingAt(src: []const u8, end: usize) ?ast.Span {
    var s = end;
    while (s > 0 and isIdentByte(src[s - 1])) s -= 1;
    if (s == end or isDigit(src[s])) return null;
    return .{ .start = @intCast(s), .end = @intCast(end) };
}

/// The head of the member access the identifier starting at `s` follows:
/// `string` for the `format` of `string.format`. `..` is concatenation, not
/// access.
fn headOfDot(src: []const u8, s: usize) ?ast.Span {
    if (s < 2 or src[s - 1] != '.' or src[s - 2] == '.') return null;
    return headEndingAt(src, s - 1);
}

/// Whether `name` is a local (a local, parameter, loop variable or function) in
/// scope at `pos`. Decided from the bindings, not the occurrences, so it holds
/// in a damaged chunk too: `string.` typed by itself loses the occurrence of
/// `string`, and a local `string` must still shadow the library.
pub fn isLocal(an: *const Analysis, name: []const u8, pos: u32) bool {
    return localAt(an, name, pos) != null;
}

/// The local `name` means at `pos`: of the ones in scope there, the one
/// declared last, which shadows the others. Null when `name` is not a local
/// there.
pub fn localAt(an: *const Analysis, name: []const u8, pos: u32) ?resolve.BindingId {
    var best: ?resolve.BindingId = null;
    for (an.res.bindings.items, 0..) |b, id| {
        if (b.kind == .global or !std.mem.eql(u8, b.name, name)) continue;
        // Strictly after `visible_from`, as completion has it: a local is not
        // yet in scope inside its own initializer.
        if (!(b.visible_from < pos and pos <= b.scope_end)) continue;
        if (best) |cur| if (an.res.binding(cur).visible_from >= b.visible_from) continue;
        best = @intCast(id);
    }
    return best;
}

/// The head of a name or path: `string` of `string.sub`, `file` of `file:read`.
fn headOf(name: []const u8) []const u8 {
    var n: usize = 0;
    while (n < name.len and name[n] != '.' and name[n] != ':') n += 1;
    return name[0..n];
}

/// Whether the inventory offers the entry to a program written today.
fn offered(e: *const stdlib_db.Entry) bool {
    return std.mem.eql(u8, e.status, "implemented") or std.mem.eql(u8, e.status, "partial");
}

/// The name the identifier at `id` is a reference to, as the table spells it:
/// `string.format` for the `format` after `string.`, else the bare name. Null
/// when the head is a local.
fn qualifiedName(a: std.mem.Allocator, an: *const Analysis, id: ast.Span) std.mem.Allocator.Error!?[]const u8 {
    const src = an.source;
    if (headOfDot(src, id.start)) |head| {
        if (isLocal(an, src[head.start..head.end], head.start)) return null;
        return try std.fmt.allocPrint(a, "{s}.{s}", .{ src[head.start..head.end], src[id.start..id.end] });
    }
    if (isLocal(an, src[id.start..id.end], id.start)) return null;
    return src[id.start..id.end];
}

/// The library name under the cursor: `print`, or `string.format` for the
/// `format` in it. Null in a string or a comment, and for a local's name.
pub fn hoverAt(a: std.mem.Allocator, an: *const Analysis, offset: u32) std.mem.Allocator.Error!?Named {
    if (try lexer.contextAt(a, an.source, offset) != .code) return null;
    const id = identifierAt(an.source, offset) orelse return null;
    const name = (try qualifiedName(a, an, id)) orelse return null;
    const entry = stdlib_db.lookup(name) orelse return null;
    return .{ .entry = entry, .span = id };
}

/// The members of the library the cursor follows (`string.fo|`) that a program
/// may use today. Empty after `:`, after a local's `.`, and for a name that is
/// no library.
pub fn members(a: std.mem.Allocator, an: *const Analysis, offset: u32) std.mem.Allocator.Error![]const Member {
    const src = an.source;
    var p: usize = @min(offset, src.len);
    while (p > 0 and isIdentByte(src[p - 1])) p -= 1;
    const head = headOfDot(src, p) orelse return &.{};
    const lib = src[head.start..head.end];
    if (isLocal(an, lib, head.start)) return &.{};
    var out: std.ArrayList(Member) = .empty;
    for (stdlib_db.entries) |*e| {
        if (!offered(e)) continue;
        if (e.name.len <= lib.len + 1) continue;
        if (!std.mem.eql(u8, e.name[0..lib.len], lib) or e.name[lib.len] != '.') continue;
        const label = e.name[lib.len + 1 ..];
        if (std.mem.findScalar(u8, label, '.') != null or std.mem.findScalar(u8, label, ':') != null) continue;
        try out.append(a, .{ .label = label, .entry = e });
    }
    return out.toOwnedSlice(a);
}

/// The callee written directly before the `(` at `paren`: a name or a `.`/`:`
/// path, with no space in it (`string.sub`, `file:read`). Null when there is
/// none, or it is not a path of names.
fn calleeBefore(src: []const u8, paren: usize) ?[]const u8 {
    var s = paren;
    while (s > 0 and (isIdentByte(src[s - 1]) or src[s - 1] == '.' or src[s - 1] == ':')) s -= 1;
    const name = src[s..paren];
    if (name.len == 0 or isDigit(name[0]) or std.mem.find(u8, name, "..") != null) return null;
    if (!isIdentByte(name[name.len - 1]) or name[0] == '.' or name[0] == ':') return null;
    return name;
}

/// An open bracket of the call scan, and the arguments counted in it so far.
const Open = struct {
    tag: token.Token.Tag,
    at: usize,
    commas: u32 = 0,
};

/// The call the cursor is inside, when its callee is a library name. Only the
/// innermost open `(` counts: an unknown callee there answers nothing, rather
/// than the call around it. Commas inside nested brackets and strings are not
/// argument separators.
pub fn callAt(a: std.mem.Allocator, an: *const Analysis, offset: u32) std.mem.Allocator.Error!?Call {
    var diags = diag.Diagnostics.init(a);
    var lx = lexer.Lexer.init(an.source, &diags);
    var stack: std.ArrayList(Open) = .empty;
    while (true) {
        const t = lx.next();
        if (t.tag == .eof or t.start >= offset) break;
        switch (t.tag) {
            .lparen, .lbrace, .lbracket => try stack.append(a, .{ .tag = t.tag, .at = t.start }),
            .rparen, .rbrace, .rbracket => {
                const want: token.Token.Tag = switch (t.tag) {
                    .rparen => .lparen,
                    .rbrace => .lbrace,
                    else => .lbracket,
                };
                // Close the innermost opener of the right kind; a stray closer
                // with none open is ignored.
                var i = stack.items.len;
                while (i > 0) {
                    i -= 1;
                    if (stack.items[i].tag == want) {
                        stack.shrinkRetainingCapacity(i);
                        break;
                    }
                }
            },
            .comma => {
                if (stack.items.len == 0) continue;
                const top = &stack.items[stack.items.len - 1];
                if (top.tag == .lparen) top.commas += 1;
            },
            else => {},
        }
    }
    var i = stack.items.len;
    while (i > 0) {
        i -= 1;
        const open = stack.items[i];
        if (open.tag != .lparen) continue;
        const name = calleeBefore(an.source, open.at) orelse return null;
        if (isLocal(an, headOf(name), @intCast(open.at - name.len))) return null;
        const entry = stdlib_db.lookup(name) orelse return null;
        if (entry.signature.len == 0) return null;
        return .{ .entry = entry, .active = open.commas };
    }
    return null;
}

/// Where each parameter's name sits in `signature`, as the `[start, end]`
/// offsets LSP takes as a label. Names are found after the `(`, in order, so
/// a name spelled inside the callee (`s` of `string`) is not matched.
pub fn paramSpans(a: std.mem.Allocator, signature: []const u8) std.mem.Allocator.Error![]const [2]u32 {
    var buf: [16]stdlib_db.Param = undefined;
    const ps = stdlib_db.params(signature, &buf);
    const out = try a.alloc([2]u32, ps.len);
    var at = std.mem.findScalar(u8, signature, '(') orelse 0;
    for (ps, out) |p, *slot| {
        const start = std.mem.findPos(u8, signature, at, p.name) orelse signature.len;
        slot.* = .{ @intCast(start), @intCast(start + p.name.len) };
        at = start + p.name.len;
    }
    return out;
}

/// The hover text for `entry`: its signature, its description, what its status
/// means for a program written today, and the system groups it needs.
pub fn markdown(a: std.mem.Allocator, entry: *const stdlib_db.Entry) std.mem.Allocator.Error![]const u8 {
    const shown = if (entry.signature.len > 0) entry.signature else entry.name;
    const status: []const u8 = if (std.mem.eql(u8, entry.status, "partial"))
        "\n\n*Partly implemented.*"
    else if (std.mem.eql(u8, entry.status, "not-started"))
        "\n\n*Not implemented yet.*"
    else if (std.mem.eql(u8, entry.status, "n/a"))
        "\n\n*Not provided by mahina.*"
    else
        "";
    var groups: std.ArrayList(u8) = .empty;
    inline for (@typeInfo(system.Group).@"enum".field_names) |name| {
        if (entry.groups.has(@field(system.Group, name))) {
            if (groups.items.len > 0) try groups.appendSlice(a, ", ");
            try groups.appendSlice(a, name);
        }
    }
    const needs: []const u8 = if (groups.items.len == 0)
        ""
    else
        try std.fmt.allocPrint(a, "\n\n*Needs the {s} system group.*", .{groups.items});
    return std.fmt.allocPrint(a, "```mahina\n{s}\n```\n\n{s}{s}{s}", .{ shown, entry.description, status, needs });
}

// ---- tests -------------------------------------------------------------------

const testing = std.testing;
const known = [_][]const u8{ "print", "string" };

/// Analyse `marked` with its `|` removed, into `out`, which the caller deinits.
/// Returns the cursor offset.
fn analyseAt(out: *Analysis, arena: std.mem.Allocator, marked: []const u8) !u32 {
    const bar = std.mem.find(u8, marked, "|").?;
    const src = try std.mem.concat(arena, u8, &.{ marked[0..bar], marked[bar + 1 ..] });
    out.* = try analysis_mod.analyse(testing.allocator, src, &known, .{});
    return @intCast(bar);
}

test "hover: a library name, and the member after its dot" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var an: Analysis = undefined;
    defer an.deinit();
    const off = try analyseAt(&an, a, "print(string.fo|rmat)");
    try testing.expectEqualStrings("string.format", (try hoverAt(a, &an, off)).?.entry.name);
    var an2: Analysis = undefined;
    defer an2.deinit();
    const off2 = try analyseAt(&an2, a, "pr|int(1)");
    try testing.expectEqualStrings("print", (try hoverAt(a, &an2, off2)).?.entry.name);
}

test "hover: nothing for a local, in a string, or in a comment" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var an: Analysis = undefined;
    defer an.deinit();
    const local = try analyseAt(&an, a, "local string = {}\nstring.fo|rmat(1)");
    try testing.expect((try hoverAt(a, &an, local)) == null);
    var an2: Analysis = undefined;
    defer an2.deinit();
    const quoted = try analyseAt(&an2, a, "x = \"string.fo|rmat\"");
    try testing.expect((try hoverAt(a, &an2, quoted)) == null);
    var an3: Analysis = undefined;
    defer an3.deinit();
    const comment = try analyseAt(&an3, a, "-- pr|int\n");
    try testing.expect((try hoverAt(a, &an3, comment)) == null);
}

test "members: the library's functions a program may use, after its dot" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var an: Analysis = undefined;
    defer an.deinit();
    const off = try analyseAt(&an, a, "x = string.|");
    const ms = try members(a, &an, off);
    var has_format = false;
    for (ms) |m| {
        try testing.expect(std.mem.indexOfScalar(u8, m.label, '.') == null);
        if (std.mem.eql(u8, m.label, "format")) has_format = true;
        // `string.byte` is excluded and `string.pack` not started: neither is offered.
        try testing.expect(!std.mem.eql(u8, m.label, "byte"));
        try testing.expect(!std.mem.eql(u8, m.label, "pack"));
    }
    try testing.expect(has_format);
}

test "members: nothing for a local's dot, after a colon, or for a name that is no library" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var an: Analysis = undefined;
    defer an.deinit();
    const local = try analyseAt(&an, a, "local string = {}\nstring.|");
    try testing.expectEqual(@as(usize, 0), (try members(a, &an, local)).len);
    var an2: Analysis = undefined;
    defer an2.deinit();
    const colon = try analyseAt(&an2, a, "string:|");
    try testing.expectEqual(@as(usize, 0), (try members(a, &an2, colon)).len);
    var an3: Analysis = undefined;
    defer an3.deinit();
    const unknown = try analyseAt(&an3, a, "zebra.|");
    try testing.expectEqual(@as(usize, 0), (try members(a, &an3, unknown)).len);
}

test "signature help: the call the cursor is in, and its argument" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var an: Analysis = undefined;
    defer an.deinit();
    const off = try analyseAt(&an, a, "string.sub(s, |");
    const c = (try callAt(a, &an, off)).?;
    try testing.expectEqualStrings("string.sub", c.entry.name);
    try testing.expectEqual(@as(u32, 1), c.active);
    // A comma inside a string is no argument separator.
    var an2: Analysis = undefined;
    defer an2.deinit();
    const quoted = try analyseAt(&an2, a, "string.sub(\"a,b\", |");
    try testing.expectEqual(@as(u32, 1), (try callAt(a, &an2, quoted)).?.active);
    // A nested table's commas are not this call's.
    var an3: Analysis = undefined;
    defer an3.deinit();
    const nested = try analyseAt(&an3, a, "string.sub({1, 2}, |");
    try testing.expectEqual(@as(u32, 1), (try callAt(a, &an3, nested)).?.active);
}

test "signature help: nothing after the call closed, for an unknown callee, or for a local" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var an: Analysis = undefined;
    defer an.deinit();
    const closed = try analyseAt(&an, a, "string.sub(s)|");
    try testing.expect((try callAt(a, &an, closed)) == null);
    // The innermost call decides: an unknown `f` answers nothing for `string.sub`.
    var an2: Analysis = undefined;
    defer an2.deinit();
    const inner = try analyseAt(&an2, a, "string.sub(s, f(a, |");
    try testing.expect((try callAt(a, &an2, inner)) == null);
    var an3: Analysis = undefined;
    defer an3.deinit();
    const local = try analyseAt(&an3, a, "local string = {}\nstring.sub(|");
    try testing.expect((try callAt(a, &an3, local)) == null);
}

test "paramSpans: each name's offsets, after the open paren" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sig = "string.sub(s, i [, j])";
    const spans = try paramSpans(a, sig);
    try testing.expectEqual(@as(usize, 3), spans.len);
    try testing.expectEqualStrings("s", sig[spans[0][0]..spans[0][1]]);
    try testing.expectEqualStrings("i", sig[spans[1][0]..spans[1][1]]);
    try testing.expectEqualStrings("j", sig[spans[2][0]..spans[2][1]]);
}
