//! Program-relative file paths, as the visualiser names a program's files and
//! a `require`/`loadfile`/`dofile` asks for them: relative to the program's
//! directory, `/`-separated. One normalizer, so the wasm entry's in-memory
//! file set, `mahina viz`'s `/project` and `/run`, and the UI
//! (viz/src/paths.ts mirrors this) agree that `./mod.mah` is `mod.mah`.

const std = @import("std");

/// Normalize a relative path lexically into `out`: drop empty and `.`
/// segments, resolve `..` against the segment before it. Null when the path
/// is absolute, climbs above the root, is empty, or doesn't fit. `./mod.mah`,
/// `mod.mah` and `lib/../mod.mah` all become `mod.mah`.
pub fn normalize(out: []u8, path: []const u8) ?[]const u8 {
    if (path.len == 0 or path[0] == '/') return null;
    var len: usize = 0;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (len == 0) return null;
            len = std.mem.lastIndexOfScalar(u8, out[0..len], '/') orelse 0;
            continue;
        }
        const sep: usize = if (len == 0) 0 else 1;
        if (len + sep + seg.len > out.len) return null;
        if (sep == 1) out[len] = '/';
        @memcpy(out[len + sep ..][0..seg.len], seg);
        len += sep + seg.len;
    }
    if (len == 0) return null;
    return out[0..len];
}

/// Room for any path `normalize` is asked to fit in the callers' scratch.
pub const max_len = 1024;

const testing = std.testing;

test "relpath: normalize drops . and empty segments and resolves .." {
    var buf: [max_len]u8 = undefined;
    try testing.expectEqualStrings("mod.mah", normalize(&buf, "./mod.mah").?);
    try testing.expectEqualStrings("mod.mah", normalize(&buf, "mod.mah").?);
    try testing.expectEqualStrings("lib/util.mah", normalize(&buf, "./lib//./util.mah").?);
    try testing.expectEqualStrings("mod.mah", normalize(&buf, "lib/../mod.mah").?);
    try testing.expectEqualStrings("a", normalize(&buf, "a/b/c/../..").?);
}

test "relpath: normalize refuses what isn't inside the program's directory" {
    var buf: [max_len]u8 = undefined;
    try testing.expectEqual(@as(?[]const u8, null), normalize(&buf, ""));
    try testing.expectEqual(@as(?[]const u8, null), normalize(&buf, "."));
    try testing.expectEqual(@as(?[]const u8, null), normalize(&buf, "/etc/passwd"));
    try testing.expectEqual(@as(?[]const u8, null), normalize(&buf, "../x.mah"));
    try testing.expectEqual(@as(?[]const u8, null), normalize(&buf, "a/../../x.mah"));
    var small: [4]u8 = undefined;
    try testing.expectEqual(@as(?[]const u8, null), normalize(&small, "abcde"));
}
