//! String-literal decoding (S-B, design doc 06): the one decoder of a
//! literal's source text, shared by the compiler and the debugger's
//! evaluator (doc 86 §7.3), so the two can never read a literal
//! differently. A decoded literal is always valid UTF-8. A malformed one
//! yields the diagnostic code to report; locating it is the caller's job.

const std = @import("std");
const diag = @import("diag.zig");

const Allocator = std.mem.Allocator;

/// A decoded literal's bytes, or the diagnostic that rejects it.
pub const Decoded = union(enum) {
    ok: []const u8,
    bad: diag.Code,
};

fn bad(code: diag.Code) Decoded {
    return .{ .bad = code };
}

/// Decode a string literal `raw`, as the lexer delimits it: quoted, or a
/// long bracket. `\u{XXXX}` encodes a code point to UTF-8; `\xNN` and
/// `\ddd` are restricted to ASCII (`<= 0x7F`).
pub fn decodeString(arena: Allocator, raw: []const u8) Allocator.Error!Decoded {
    std.debug.assert(raw.len >= 2);
    // Long-bracket string: `[` `=`{n} `[` ... `]` `=`{n} `]`. A normal string
    // always opens with `"`/`'`, so a leading `[` is an unambiguous marker.
    // No escapes; one leading newline is dropped (Lua 5.4 §3.1).
    if (raw[0] == '[') return decodeLongString(arena, raw);
    return decodeEscapes(arena, raw[1 .. raw.len - 1], false);
}

/// Decode one text chunk of a backtick template (doc 82 §3): `inner` is
/// the source between the delimiters.
pub fn decodeTemplateChunk(arena: Allocator, inner: []const u8) Allocator.Error!Decoded {
    return decodeEscapes(arena, inner, true);
}

pub fn decodeEscapes(arena: Allocator, inner: []const u8, template: bool) Allocator.Error!Decoded {
    var buf: std.ArrayList(u8) = .empty;
    try buf.ensureTotalCapacity(arena, inner.len);

    var i: usize = 0;
    while (i < inner.len) {
        const ch = inner[i];
        if (ch != '\\') {
            i += 1;
            if (template and (ch == '\n' or ch == '\r')) {
                if (i < inner.len and (inner[i] == '\n' or inner[i] == '\r') and inner[i] != ch) i += 1;
                try buf.append(arena, '\n');
            } else try buf.append(arena, ch);
            continue;
        }
        i += 1;
        if (i >= inner.len) break; // trailing backslash (lexer should prevent)
        const esc = inner[i];
        i += 1;
        switch (esc) {
            'n' => try buf.append(arena, '\n'),
            't' => try buf.append(arena, '\t'),
            'r' => try buf.append(arena, '\r'),
            'a' => try buf.append(arena, 7),
            'b' => try buf.append(arena, 8),
            'f' => try buf.append(arena, 12),
            'v' => try buf.append(arena, 11),
            '\\' => try buf.append(arena, '\\'),
            '"' => try buf.append(arena, '"'),
            '\'' => try buf.append(arena, '\''),
            '`', '{', '}' => if (template) try buf.append(arena, esc) else return bad(.invalid_escape),
            // A backslash before a newline (LF, CR, CRLF or LFCR) is one `\n`.
            '\n', '\r' => {
                if (i < inner.len and (inner[i] == '\n' or inner[i] == '\r') and inner[i] != esc) i += 1;
                try buf.append(arena, '\n');
            },
            // `\z` skips the whitespace after it, newlines included.
            'z' => while (i < inner.len and std.mem.indexOfScalar(u8, " \t\n\r\x0B\x0C", inner[i]) != null) {
                i += 1;
            },
            'x' => {
                var val: u16 = 0;
                var digits: usize = 0;
                while (digits < 2 and i < inner.len and isHex(inner[i])) : (digits += 1) {
                    val = val * 16 + hexValue(inner[i]);
                    i += 1;
                }
                if (digits != 2) return bad(.hex_escape_digits);
                if (val > 0x7F) return bad(.hex_escape_not_ascii);
                try buf.append(arena, @intCast(val));
            },
            '0'...'9' => {
                var val: u16 = esc - '0';
                var digits: usize = 1;
                while (digits < 3 and i < inner.len and inner[i] >= '0' and inner[i] <= '9') : (digits += 1) {
                    val = val * 10 + (inner[i] - '0');
                    i += 1;
                }
                if (val > 0x7F) return bad(.decimal_escape_not_ascii);
                try buf.append(arena, @intCast(val));
            },
            'u' => {
                // `\u{XXXX}` — a Unicode code point encoded to UTF-8.
                if (i >= inner.len or inner[i] != '{') return bad(.unicode_escape_open_brace);
                i += 1;
                var cp: u32 = 0;
                var digits: usize = 0;
                while (i < inner.len and isHex(inner[i])) : (digits += 1) {
                    cp = cp * 16 + hexValue(inner[i]);
                    i += 1;
                    if (cp > 0x10FFFF) return bad(.unicode_escape_out_of_range);
                }
                if (digits == 0) return bad(.unicode_escape_no_digits);
                if (i >= inner.len or inner[i] != '}') return bad(.unicode_escape_close_brace);
                i += 1;
                var tmp: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(@intCast(cp), &tmp) catch
                    return bad(.unicode_escape_invalid);
                try buf.appendSlice(arena, tmp[0..n]);
            },
            else => return bad(.invalid_escape),
        }
    }
    if (!std.unicode.utf8ValidateSlice(buf.items)) return bad(.invalid_utf8);
    return .{ .ok = buf.items };
}

/// Decode a long-bracket string literal `raw` = `[` `=`{n} `[` body `]` `=`{n} `]`.
/// The content is verbatim (no escape interpretation); if the body begins with
/// a newline it is dropped (Lua 5.4 §3.1: a `\r\n`/`\n\r`/`\r`/`\n` immediately
/// after the opening bracket is not part of the string), and every other
/// newline sequence reads as one `\n`, as in Lua. A body without a `\r`
/// borrows `raw`; one with a `\r` is rebuilt in the arena. UTF-8 validated like
/// every mahina string literal.
pub fn decodeLongString(arena: Allocator, raw: []const u8) Allocator.Error!Decoded {
    std.debug.assert(raw[0] == '[');
    var level: usize = 0;
    while (raw[1 + level] == '=') level += 1;
    const delim = level + 2; // length of `[` `=`{level} `[` and of the close
    std.debug.assert(raw.len >= 2 * delim);
    var inner = raw[delim .. raw.len - delim];
    // Drop a single leading end-of-line (any of \n, \r, \r\n, \n\r).
    if (inner.len > 0 and (inner[0] == '\n' or inner[0] == '\r')) {
        const first = inner[0];
        inner = inner[1..];
        if (inner.len > 0 and (inner[0] == '\n' or inner[0] == '\r') and inner[0] != first) {
            inner = inner[1..];
        }
    }
    if (!std.unicode.utf8ValidateSlice(inner)) return bad(.invalid_utf8);
    if (std.mem.indexOfScalar(u8, inner, '\r') == null) return .{ .ok = inner };
    var buf: std.ArrayList(u8) = .empty;
    try buf.ensureTotalCapacity(arena, inner.len);
    var i: usize = 0;
    while (i < inner.len) : (i += 1) {
        const ch = inner[i];
        if (ch != '\n' and ch != '\r') {
            buf.appendAssumeCapacity(ch);
            continue;
        }
        if (i + 1 < inner.len and (inner[i + 1] == '\n' or inner[i + 1] == '\r') and inner[i + 1] != ch) i += 1;
        buf.appendAssumeCapacity('\n');
    }
    return .{ .ok = buf.items };
}

fn isHex(ch: u8) bool {
    return (ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f') or (ch >= 'A' and ch <= 'F');
}

fn hexValue(ch: u8) u8 {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'a'...'f' => ch - 'a' + 10,
        'A'...'F' => ch - 'A' + 10,
        else => 0,
    };
}

test "strlit: escapes, long brackets and rejections" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("a\nb\u{e9}", (try decodeString(a, "\"a\\nb\\u{e9}\"")).ok);
    try std.testing.expectEqualStrings("x\ny", (try decodeString(a, "[[\nx\r\ny]]")).ok);
    try std.testing.expectEqual(diag.Code.hex_escape_not_ascii, (try decodeString(a, "'\\xff'")).bad);
    try std.testing.expectEqual(diag.Code.invalid_escape, (try decodeString(a, "'\\{'")).bad);
    try std.testing.expectEqualStrings("{", (try decodeTemplateChunk(a, "\\{")).ok);
}
