//! The stdlib knowledge table (doc 74 §7.3): what hover, `lib.` completion and
//! signature help read. One entry per row of `docs/lua-stdlib-inventory.csv`
//! (Rule Z-5: the CSV is the canonical map), parsed at compile time, so the
//! table cannot drift from the inventory. A row's system group comes from the
//! native registered under the same name (`interp.base_natives`), so
//! availability has one source too.
//!
//! The cross-check tests below hold both directions: every native is in the
//! inventory, and every implemented row is a native, a constant or a value.

const std = @import("std");
const testing = std.testing;
const csv = @import("stdlib_inventory").csv;
const function = @import("../function.zig");
const interp = @import("../interp.zig");
const system = @import("../system.zig");

pub const Entry = struct {
    /// The name as a program writes it: `string.format`, `print`, `file:read`.
    name: []const u8,
    /// Lua-manual call form, optional parameters in `[...]`; empty for a value.
    signature: []const u8,
    /// The inventory's description (some are implementation notes).
    description: []const u8,
    tier: []const u8,
    /// `implemented`, `partial`, `not-started` or `n/a`.
    status: []const u8,
    /// The system group a native installs under (doc 65 §5.2); `.none` for one
    /// every VM has, and for a value.
    groups: system.Groups,
};

/// Every inventory row, in inventory order.
pub const entries: []const Entry = blk: {
    @setEvalBranchQuota(1_000_000);
    var count: usize = 0;
    var rows = std.mem.tokenizeScalar(u8, csv, '\n');
    _ = rows.next(); // the header
    while (rows.next()) |_| count += 1;

    var out: [count]Entry = undefined;
    rows = std.mem.tokenizeScalar(u8, csv, '\n');
    _ = rows.next();
    var k: usize = 0;
    while (rows.next()) |line| : (k += 1) {
        const f = fields(line);
        out[k] = .{
            .name = f[1],
            .tier = f[2],
            .status = f[3],
            .description = f[4],
            .signature = f[5],
            .groups = groupsOf(f[1]),
        };
    }
    const final = out;
    break :blk &final;
};

/// The entry named `name` (`string.format`, `print`), or null if the inventory
/// has none.
pub fn lookup(name: []const u8) ?*const Entry {
    for (entries) |*e| {
        if (std.mem.eql(u8, e.name, name)) return e;
    }
    return null;
}

/// The name a signature starts with: `table.insert` for
/// `table.insert(list [, pos], value)`.
pub fn nameOf(signature: []const u8) []const u8 {
    return signature[0 .. std.mem.findScalar(u8, signature, '(') orelse signature.len];
}

pub const Param = struct {
    name: []const u8,
    /// Written inside `[...]`, so it may be left out.
    optional: bool,
};

/// The parameters of `signature`, in order, into `buf`; any past `buf.len`
/// are dropped. A `[` that comes before a parameter's name, or any `[` still
/// open around it, makes it optional.
pub fn params(signature: []const u8, buf: []Param) []Param {
    const open = std.mem.findScalar(u8, signature, '(') orelse return buf[0..0];
    const close = std.mem.findScalarLast(u8, signature, ')') orelse signature.len;
    const inner = signature[open + 1 .. close];
    var n: usize = 0;
    var depth: usize = 0;
    var seg_start: usize = 0;
    var seg_depth: usize = 0;
    var i: usize = 0;
    while (i <= inner.len) : (i += 1) {
        if (i < inner.len and inner[i] != ',') {
            switch (inner[i]) {
                '[' => depth += 1,
                ']' => depth -|= 1,
                else => {},
            }
            continue;
        }
        const seg = inner[seg_start..i];
        var s: usize = 0;
        var optional = seg_depth > 0;
        while (s < seg.len and (seg[s] == ' ' or seg[s] == '[')) : (s += 1) {
            if (seg[s] == '[') optional = true;
        }
        const name = std.mem.trim(u8, seg[s..], " []");
        if (name.len > 0 and n < buf.len) {
            buf[n] = .{ .name = name, .optional = optional };
            n += 1;
        }
        seg_start = i + 1;
        seg_depth = depth;
    }
    return buf[0..n];
}

/// Splits one CSV row into its six fields. Quotes wrap a field, and `""` inside
/// one is a quote; a comma inside quotes does not split.
fn fields(comptime line: []const u8) [6][]const u8 {
    var out: [6][]const u8 = undefined;
    var n: usize = 0;
    var start: usize = 0;
    var quoted = false;
    for (line, 0..) |c, i| {
        if (c == '"') quoted = !quoted;
        if (c == ',' and !quoted) {
            if (n >= out.len) @compileError("stdlib inventory row has more than six fields: " ++ line);
            out[n] = unquote(line[start..i]);
            n += 1;
            start = i + 1;
        }
    }
    if (n != out.len - 1) @compileError("stdlib inventory row has fewer than six fields: " ++ line);
    out[n] = unquote(line[start..]);
    return out;
}

/// `raw` without its wrapping quotes, with each doubled quote made single.
fn unquote(comptime raw: []const u8) []const u8 {
    const s = if (raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"') raw[1 .. raw.len - 1] else raw;
    const doubled = std.mem.count(u8, s, "\"\"");
    if (doubled == 0) return s;
    const out = blk: {
        var b: [s.len - doubled]u8 = undefined;
        var i: usize = 0;
        var j: usize = 0;
        while (i < s.len) : (j += 1) {
            b[j] = s[i];
            i += if (s[i] == '"' and i + 1 < s.len and s[i + 1] == '"') 2 else 1;
        }
        break :blk b;
    };
    return &out;
}

/// The system group of the native named `name`, from `interp.base_natives`,
/// or of the value (`io.stdin`) the VM installs with a group.
fn groupsOf(comptime name: []const u8) system.Groups {
    for (interp.base_natives) |bn| {
        if (bn.manual) continue;
        if (std.mem.eql(u8, qualifiedName(bn), name)) return bn.groups;
    }
    for (interp.Vm.system_members) |sm| {
        const m = sm.module orelse continue;
        if (name.len == m.len + 1 + sm.name.len and std.mem.startsWith(u8, name, m) and
            name[m.len] == '.' and std.mem.endsWith(u8, name, sm.name)) return sm.groups;
    }
    return .none;
}

/// A global whose every native is in a system group, and the groups that
/// install it (`aio`).
const GatedGlobal = struct { name: []const u8, groups: system.Groups };

const gated_globals: []const GatedGlobal = blk: {
    @setEvalBranchQuota(100_000);
    var out: []const GatedGlobal = &.{};
    var seen: []const []const u8 = &.{};
    for (interp.base_natives) |bn| {
        if (bn.manual) continue;
        const top = bn.module orelse bn.name;
        if (top[0] == '@') continue;
        const dup = for (seen) |s| {
            if (std.mem.eql(u8, s, top)) break true;
        } else false;
        if (dup) continue;
        seen = seen ++ .{top};
        var groups: system.Groups = .none;
        const free = for (interp.base_natives) |other| {
            if (other.manual or !std.mem.eql(u8, other.module orelse other.name, top)) continue;
            if (other.groups == system.Groups.none) break true;
            groups = groups.unite(other.groups);
        } else false;
        if (!free) out = out ++ .{GatedGlobal{ .name = top, .groups = groups }};
    }
    break :blk out;
};

/// Whether the global `name` exists with `enabled` groups: it does unless every
/// native installing it is in a group none of which is enabled. A name the
/// stdlib does not install (a host's own) is not this table's to judge.
pub fn globalAvailable(name: []const u8, enabled: system.Groups) bool {
    for (gated_globals) |g| {
        if (std.mem.eql(u8, g.name, name)) return g.groups.overlaps(enabled);
    }
    return true;
}

/// Whether `e` is installed with `enabled` groups.
pub fn available(e: *const Entry, enabled: system.Groups) bool {
    return e.groups == system.Groups.none or e.groups.overlaps(enabled);
}

/// A native's inventory name (`inventoryName`, at compile time).
fn qualifiedName(comptime bn: function.BaseNative) []const u8 {
    const m = bn.module orelse return bn.name;
    return if (m[0] == '@') m[1..] ++ ":" ++ bn.field.? else m ++ "." ++ bn.field.?;
}

// ---------------------------------------------------------------------------

/// Inventory names that are values, not callables, so no native backs them.
const values = [_][]const u8{
    "_G",           "_VERSION",        "io.stdin",          "io.stdout",
    "io.stderr",    "package.cpath",   "package.config",    "package.loaded",
    "package.path", "package.preload", "package.searchers",
};

fn isValue(name: []const u8) bool {
    for (values) |v| {
        if (std.mem.eql(u8, v, name)) return true;
    }
    return false;
}

/// The inventory name of a native, allocated in `gpa`: `module.field`, or the
/// bare `name`. A hidden module (`@file`) holds methods, which the inventory
/// writes as `file:read`.
fn inventoryName(gpa: std.mem.Allocator, bn: function.BaseNative) ![]u8 {
    const m = bn.module orelse return gpa.dupe(u8, bn.name);
    if (m[0] == '@') return std.fmt.allocPrint(gpa, "{s}:{s}", .{ m[1..], bn.field.? });
    return std.fmt.allocPrint(gpa, "{s}.{s}", .{ m, bn.field.? });
}

test "the table parses every inventory row, with the fields in place" {
    try testing.expect(entries.len > 100);
    const f = lookup("string.format").?;
    try testing.expectEqualStrings("core", f.tier);
    try testing.expectEqualStrings("implemented", f.status);
    try testing.expectEqualStrings("string.format(formatstring, ...)", f.signature);
    try testing.expect(std.mem.indexOf(u8, f.description, "printf-style") != null);
}

test "a doubled quote in a description is one quote" {
    // The aio.read description quotes its "b" argument as ""b"" in the CSV.
    const e = lookup("aio.read").?;
    try testing.expect(std.mem.indexOf(u8, e.description, "\"b\"") != null);
    try testing.expect(std.mem.indexOf(u8, e.description, "\"\"b\"\"") == null);
}

test "availability: a global or a member in a system group needs that group" {
    try testing.expect(globalAvailable("print", .none));
    try testing.expect(globalAvailable("io", .none));
    try testing.expect(!globalAvailable("aio", .none));
    try testing.expect(globalAvailable("aio", .{ .clock = true }));
    try testing.expect(globalAvailable("spawn", .none));
    try testing.expect(!available(lookup("io.open").?, .{ .stdio = true }));
    try testing.expect(available(lookup("io.open").?, .{ .files = true }));
    try testing.expect(available(lookup("io.write").?, .none));
    // A value installed with a group.
    try testing.expect(!available(lookup("io.stdin").?, .none));
}

test "a native's system group comes from its registration" {
    try testing.expectEqual(system.Groups.none, lookup("string.format").?.groups);
    const read = lookup("aio.read").?;
    try testing.expect(read.groups.files);
    try testing.expect(!read.groups.stdio);
}

test "every signature starts with its entry's name" {
    for (entries) |e| {
        if (e.signature.len == 0) continue;
        try testing.expectEqualStrings(e.name, nameOf(e.signature));
    }
}

test "params: required, optional, and a bracket that opens before a name" {
    var buf: [8]Param = undefined;

    const insert = params("table.insert(list [, pos], value)", &buf);
    try testing.expectEqual(@as(usize, 3), insert.len);
    try testing.expectEqualStrings("list", insert[0].name);
    try testing.expect(!insert[0].optional);
    try testing.expectEqualStrings("pos", insert[1].name);
    try testing.expect(insert[1].optional);
    try testing.expectEqualStrings("value", insert[2].name);
    try testing.expect(!insert[2].optional);

    const dofile = params("dofile([filename])", &buf);
    try testing.expectEqual(@as(usize, 1), dofile.len);
    try testing.expectEqualStrings("filename", dofile[0].name);
    try testing.expect(dofile[0].optional);

    const random = params("math.random([m [, n]])", &buf);
    try testing.expectEqual(@as(usize, 2), random.len);
    try testing.expect(random[0].optional);
    try testing.expect(random[1].optional);

    try testing.expectEqual(@as(usize, 0), params("math.pi", &buf).len);
}

test "params: a short buffer keeps the first parameters" {
    var buf: [1]Param = undefined;
    const got = params("string.sub(s, i [, j])", &buf);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqualStrings("s", got[0].name);
}

test "every non-method native is inventoried, and every inventoried callable is registered" {
    const gpa = testing.allocator;
    // Native → row. An internal iterator native (`@…` by name) is not a library name.
    for (interp.base_natives) |bn| {
        if (bn.manual or bn.name.len == 0 or bn.name[0] == '@') continue;
        const name = try inventoryName(gpa, bn);
        defer gpa.free(name);
        if (lookup(name) == null) {
            std.debug.print("native `{s}` has no row in docs/lua-stdlib-inventory.csv\n", .{name});
            return error.NotInventoried;
        }
    }
    // Row → native, constant, or value.
    for (entries) |e| {
        if (!(std.mem.eql(u8, e.status, "implemented") or std.mem.eql(u8, e.status, "partial"))) continue;
        if (isValue(e.name)) continue;
        var found = false;
        for (interp.base_natives) |bn| {
            if (bn.manual) continue;
            const name = try inventoryName(gpa, bn);
            defer gpa.free(name);
            if (std.mem.eql(u8, name, e.name)) found = true;
        }
        for (interp.base_constants) |c| {
            const name = try std.fmt.allocPrint(gpa, "{s}.{s}", .{ c.module, c.field });
            defer gpa.free(name);
            if (std.mem.eql(u8, name, e.name)) found = true;
        }
        if (!found) {
            std.debug.print("inventory row `{s}` is implemented but has no native, constant or value\n", .{e.name});
            return error.NotRegistered;
        }
    }
}
