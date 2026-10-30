//! Definition, references, highlights and rename, read off the resolver's
//! binding index (doc 74 §7.2).
//!
//! Everything here is LSP-free: byte spans in, byte spans out. The cost of a
//! request is one pass over the occurrence array (sorted by position, so the
//! rename checks binary-search into it), never a walk of the tree.

const std = @import("std");
const ast = @import("../ast.zig");
const resolve = @import("../resolve.zig");
const token = @import("../token.zig");
const analysis_mod = @import("analysis.zig");

const Span = ast.Span;
const Analysis = analysis_mod.Analysis;
const Occurrence = resolve.Occurrence;
const BindingId = resolve.BindingId;

/// The name token under the cursor (anywhere in it, or just after it).
pub fn occurrenceAt(an: *const Analysis, offset: u32) ?*const Occurrence {
    return an.res.occurrenceCovering(offset);
}

fn writes(access: resolve.Access) bool {
    return access == .write or access == .read_write;
}

/// Where the name is declared. A global is declared where it is first
/// assigned; one nothing assigns (a host built-in, a typo) has no definition.
pub fn definition(an: *const Analysis, occ: *const Occurrence) ?Span {
    const b = an.res.binding(occ.binding);
    if (b.kind != .global) return b.decl_span;
    const first = an.res.occurrenceAt(b.decl_span.start) orelse return null;
    return if (writes(first.access)) first.span else null;
}

/// Whether `occ` is the occurrence that declares its binding.
fn declares(an: *const Analysis, occ: *const Occurrence) bool {
    const b = an.res.binding(occ.binding);
    if (b.kind != .global) return occ.access == .declare;
    return occ.span.start == b.decl_span.start and writes(occ.access);
}

/// Every occurrence of `binding`, in source order. The implicit `self` of a
/// method has a zero-width declaration, which is left out: there is no text to
/// point at or edit.
pub fn references(
    a: std.mem.Allocator,
    an: *const Analysis,
    binding: BindingId,
    include_declaration: bool,
) std.mem.Allocator.Error![]const Occurrence {
    var out: std.ArrayList(Occurrence) = .empty;
    for (an.res.occurrences.items) |*o| {
        if (o.binding != binding or o.span.end == o.span.start) continue;
        if (!include_declaration and declares(an, o)) continue;
        try out.append(a, o.*);
    }
    return out.toOwnedSlice(a);
}

/// The global called `name`, if the file uses one.
pub fn globalNamed(an: *const Analysis, name: []const u8) ?BindingId {
    for (an.res.bindings.items, 0..) |b, i| {
        if (b.kind == .global and std.mem.eql(u8, b.name, name)) return @intCast(i);
    }
    return null;
}

// ---- rename ------------------------------------------------------------------

pub const Refusal = enum {
    /// The cursor is not on a name the resolver knows.
    not_a_name,
    /// `self` of `function a:m()` has no parameter in the text to rename.
    implicit_self,
    /// A global the host installs.
    builtin,
    invalid_name,
    keyword,
    /// A use of the renamed name would start meaning another declaration;
    /// `at` is that use.
    would_capture,
    /// Another declaration's use would start meaning the renamed one; `at` is
    /// that use.
    would_be_captured,
};

pub const Check = union(enum) {
    ok,
    refused: struct { reason: Refusal, at: ?Span = null },
};

/// Whether `s` is spelled like an identifier (ASCII, like the lexer's).
pub fn isIdentifier(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s, 0..) |c, i| {
        const alpha = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
        const digit = c >= '0' and c <= '9';
        if (!(alpha or (digit and i > 0))) return false;
    }
    return true;
}

/// Whether renaming `binding` to `new_name` keeps every name meaning what it
/// meant. `occs` is `references(.., binding, true)`.
///
/// After the rename a name resolves to the innermost visible declaration of
/// that spelling, so two things can go wrong: an occurrence of the renamed
/// binding finds a nearer declaration already called `new_name` (it is
/// captured), or an occurrence of an outer `new_name` inside the renamed
/// binding's scope finds the renamed binding first.
pub fn checkRename(
    an: *const Analysis,
    known_globals: []const []const u8,
    binding: BindingId,
    occs: []const Occurrence,
    new_name: []const u8,
) Check {
    const b = an.res.binding(binding);
    if (b.kind == .self) return .{ .refused = .{ .reason = .implicit_self } };
    if (b.kind == .global) for (known_globals) |g| {
        if (std.mem.eql(u8, g, b.name)) return .{ .refused = .{ .reason = .builtin } };
    };
    if (!isIdentifier(new_name)) return .{ .refused = .{ .reason = .invalid_name } };
    if (token.keywords.has(new_name)) return .{ .refused = .{ .reason = .keyword } };
    if (std.mem.eql(u8, b.name, new_name)) return .ok;

    // A nearer declaration of the new spelling around one of our occurrences.
    for (an.res.bindings.items, 0..) |c, ci| {
        if (ci == binding or c.kind == .global or c.visible_from <= b.visible_from) continue;
        if (!std.mem.eql(u8, c.name, new_name)) continue;
        var lo: usize = 0;
        var hi: usize = occs.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (occs[mid].span.start < c.visible_from) lo = mid + 1 else hi = mid;
        }
        if (lo < occs.len and occs[lo].span.start < c.scope_end) {
            return .{ .refused = .{ .reason = .would_capture, .at = occs[lo].span } };
        }
    }

    // An outer declaration of the new spelling used inside our scope.
    const all = an.res.occurrences.items;
    var lo: usize = 0;
    var hi: usize = all.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (all[mid].span.start < b.visible_from) lo = mid + 1 else hi = mid;
    }
    for (all[lo..]) |o| {
        if (o.span.start >= b.scope_end) break;
        if (o.binding == binding) continue;
        const c = an.res.binding(o.binding);
        if (c.kind != .global and c.visible_from >= b.visible_from) continue; // nested in our scope
        if (std.mem.eql(u8, c.name, new_name)) {
            return .{ .refused = .{ .reason = .would_be_captured, .at = o.span } };
        }
    }
    return .ok;
}

// ---- tests -------------------------------------------------------------------

const testing = std.testing;
const known = [_][]const u8{"print"};

/// An analysis of `src` and the offset of the `n`-th (0-based) occurrence of
/// `needle`.
const Fixture = struct {
    an: Analysis,
    src: []const u8,

    fn init(src: []const u8) !Fixture {
        return .{ .an = try analysis_mod.analyse(testing.allocator, src, &known, .{}), .src = src };
    }

    fn deinit(self: *Fixture) void {
        self.an.deinit();
    }

    fn at(self: *const Fixture, needle: []const u8, n: usize) u32 {
        var from: usize = 0;
        var left = n;
        while (std.mem.find(u8, self.src[from..], needle)) |i| {
            if (left == 0) return @intCast(from + i);
            left -= 1;
            from += i + 1;
        }
        unreachable;
    }

    fn occ(self: *const Fixture, needle: []const u8, n: usize) *const Occurrence {
        return occurrenceAt(&self.an, self.at(needle, n)).?;
    }

    fn check(self: *const Fixture, needle: []const u8, n: usize, new_name: []const u8) !Check {
        const o = self.occ(needle, n);
        const refs = try references(testing.allocator, &self.an, o.binding, true);
        defer testing.allocator.free(refs);
        return checkRename(&self.an, &known, o.binding, refs, new_name);
    }
};

test "navigation: a local's definition and references follow shadowing" {
    var f = try Fixture.init("local x = 1\nlocal x = x + 1\nprint(x)");
    defer f.deinit();
    // The `x` in `x + 1` is the first one; the one in `print(x)` is the second.
    const first_use = f.occ("x + 1", 0);
    try testing.expectEqual(f.at("x = 1", 0), definition(&f.an, first_use).?.start);
    const last_use = f.occ("x)", 0);
    try testing.expectEqual(f.at("x = x", 0), definition(&f.an, last_use).?.start);

    const refs = try references(testing.allocator, &f.an, last_use.binding, true);
    defer testing.allocator.free(refs);
    try testing.expectEqual(@as(usize, 2), refs.len);
    const without = try references(testing.allocator, &f.an, last_use.binding, false);
    defer testing.allocator.free(without);
    try testing.expectEqual(@as(usize, 1), without.len);
}

test "navigation: a global is defined where it is first assigned, a built-in nowhere" {
    var f = try Fixture.init("print(g)\ng = 1\nprint(g)");
    defer f.deinit();
    try testing.expectEqual(f.at("g = 1", 0), definition(&f.an, f.occ("g)", 0)).?.start);
    try testing.expect(definition(&f.an, f.occ("print", 0)) == null);
    const refs = try references(testing.allocator, &f.an, f.occ("g)", 0).binding, false);
    defer testing.allocator.free(refs);
    try testing.expectEqual(@as(usize, 2), refs.len); // the assignment is the declaration
}

test "navigation: the implicit self has no text to list" {
    var f = try Fixture.init("local t = {}\nfunction t:m() return self end");
    defer f.deinit();
    const use = f.occ("self", 0);
    const refs = try references(testing.allocator, &f.an, use.binding, true);
    defer testing.allocator.free(refs);
    try testing.expectEqual(@as(usize, 1), refs.len);
    try testing.expectEqual(Refusal.implicit_self, (try f.check("self", 0, "me")).refused.reason);
}

test "rename: spelling and the names the host owns" {
    var f = try Fixture.init("local a = 1\nprint(a)\nlocal function g() end");
    defer f.deinit();
    try testing.expectEqual(Check.ok, try f.check("a = 1", 0, "b"));
    try testing.expectEqual(Refusal.invalid_name, (try f.check("a = 1", 0, "1b")).refused.reason);
    try testing.expectEqual(Refusal.invalid_name, (try f.check("a = 1", 0, "")).refused.reason);
    try testing.expectEqual(Refusal.invalid_name, (try f.check("a = 1", 0, "a b")).refused.reason);
    try testing.expectEqual(Refusal.keyword, (try f.check("a = 1", 0, "end")).refused.reason);
    try testing.expectEqual(Refusal.builtin, (try f.check("print", 0, "say")).refused.reason);
    try testing.expectEqual(Check.ok, try f.check("a = 1", 0, "a")); // the same name changes nothing
}

test "rename: a nearer declaration of the new name would capture a use" {
    var f = try Fixture.init("local a = 1\ndo\n  local b = 2\n  print(a, b)\nend");
    defer f.deinit();
    const r = try f.check("a = 1", 0, "b");
    try testing.expectEqual(Refusal.would_capture, r.refused.reason);
    try testing.expectEqual(f.at("a, b", 0), r.refused.at.?.start);
    // Where `b` is not yet declared the same rename is fine.
    var g = try Fixture.init("local a = 1\nprint(a)\ndo local b = 2 print(b) end");
    defer g.deinit();
    try testing.expectEqual(Check.ok, try g.check("a = 1", 0, "b"));
}

test "rename: renaming into an outer name would let the renamed local steal its uses" {
    var f = try Fixture.init("local outer = 1\ndo\n  local inner = 2\n  print(outer, inner)\nend");
    defer f.deinit();
    const r = try f.check("inner", 0, "outer");
    try testing.expectEqual(Refusal.would_be_captured, r.refused.reason);
    try testing.expectEqual(f.at("outer, inner", 0), r.refused.at.?.start);
    // Shadowing an outer name nobody uses inside is allowed.
    var g = try Fixture.init("local outer = 1\ndo local inner = 2 print(inner) end");
    defer g.deinit();
    try testing.expectEqual(Check.ok, try g.check("inner", 0, "outer"));
}

test "rename: a global conflicts with a local it would run into, and with another global" {
    var f = try Fixture.init("g = 1\nh = 2\nlocal function f()\n  local t = 3\n  return g + t\nend");
    defer f.deinit();
    try testing.expectEqual(Refusal.would_capture, (try f.check("g", 0, "t")).refused.reason);
    try testing.expectEqual(Refusal.would_be_captured, (try f.check("g", 0, "h")).refused.reason);
    try testing.expectEqual(Check.ok, try f.check("g", 0, "k"));
}

test "rename: a name used by a sibling scope is not a conflict" {
    var f = try Fixture.init("do local a = 1 print(a) end\ndo local b = 2 print(b) end");
    defer f.deinit();
    try testing.expectEqual(Check.ok, try f.check("a = 1", 0, "b"));
}
