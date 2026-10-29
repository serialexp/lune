//! `file:` URIs and the paths they name (RFC 8089), for `require` resolution
//! (doc 74 §7.4). The server works in paths with `/` separators whatever the
//! OS: a Windows drive path is `C:/x`, written `file:///C:/x`. Other schemes
//! (`untitled:`, a browser's in-memory documents) name no file.

const std = @import("std");

/// The path a `file:` URI names, percent-decoded. Null for another scheme, a
/// remote authority (a UNC share), or a malformed escape.
pub fn toPath(a: std.mem.Allocator, uri: []const u8) std.mem.Allocator.Error!?[]const u8 {
    const prefix = "file://";
    if (!std.ascii.startsWithIgnoreCase(uri, prefix)) return null;
    var rest = uri[prefix.len..];
    const slash = std.mem.findScalar(u8, rest, '/') orelse return null;
    const authority = rest[0..slash];
    if (authority.len != 0 and !std.ascii.eqlIgnoreCase(authority, "localhost")) return null;
    rest = rest[slash..];
    if (std.mem.findAny(u8, rest, "?#")) |q| rest = rest[0..q];

    var out: std.ArrayList(u8) = try .initCapacity(a, rest.len);
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const c = rest[i];
        if (c != '%') {
            out.appendAssumeCapacity(c);
            continue;
        }
        if (i + 2 >= rest.len) return null;
        const byte = std.fmt.parseInt(u8, rest[i + 1 .. i + 3], 16) catch return null;
        out.appendAssumeCapacity(byte);
        i += 2;
    }
    const p = out.items;
    // `/C:/x` is the drive path `C:/x`.
    if (p.len >= 3 and p[0] == '/' and std.ascii.isAlphabetic(p[1]) and p[2] == ':') return p[1..];
    return p;
}

/// The `file:` URI of an absolute path. Bytes other than letters, digits,
/// `-._~`, `/` and `:` are percent-encoded.
pub fn fromPath(a: std.mem.Allocator, path: []const u8) std.mem.Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "file://");
    if (!std.mem.startsWith(u8, path, "/")) try out.append(a, '/');
    for (path) |c| {
        if (std.ascii.isAlphanumeric(c) or std.mem.findScalar(u8, "-._~/:", c) != null) {
            try out.append(a, c);
        } else {
            try out.print(a, "%{X:0>2}", .{c});
        }
    }
    return out.toOwnedSlice(a);
}

// ---- tests -------------------------------------------------------------------

const testing = std.testing;

test "uri: a file URI's path, decoded, and a drive letter loses its slash" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("/home/me/a b.mah", (try toPath(a, "file:///home/me/a%20b.mah")).?);
    try testing.expectEqualStrings("/x/y", (try toPath(a, "file://localhost/x/y")).?);
    try testing.expectEqualStrings("c:/proj/m.mah", (try toPath(a, "file:///c%3A/proj/m.mah")).?);
    try testing.expectEqualStrings("C:/p", (try toPath(a, "FILE:///C:/p?x#y")).?);
}

test "uri: other schemes, remote hosts and bad escapes name no file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect((try toPath(a, "untitled:Untitled-1")) == null);
    try testing.expect((try toPath(a, "file://server/share/x")) == null);
    try testing.expect((try toPath(a, "file:///a%2")) == null);
    try testing.expect((try toPath(a, "file:///a%zz")) == null);
}

test "uri: a path round-trips through its URI" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const u = try fromPath(a, "/home/me/a b#1.mah");
    try testing.expectEqualStrings("file:///home/me/a%20b%231.mah", u);
    try testing.expectEqualStrings("/home/me/a b#1.mah", (try toPath(a, u)).?);
    const w = try fromPath(a, "C:/proj/m.mah");
    try testing.expectEqualStrings("file:///C:/proj/m.mah", w);
    try testing.expectEqualStrings("C:/proj/m.mah", (try toPath(a, w)).?);
}
