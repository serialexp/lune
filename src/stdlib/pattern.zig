//! lune stdlib — the Lua pattern-matching engine (pure, host-free).
//!
//! A faithful port of LuaJIT's `lib_string.c` matcher (`match`, `classend`,
//! `singlematch`, `matchbracketclass`, `match_class`, `matchbalance`,
//! `max_expand`/`min_expand`, the capture machinery) to Zig, operating on raw
//! byte slices and **offsets** rather than pointers. It knows nothing about the
//! VM, the heap, or `Value` — it answers one question: starting at offset `s`,
//! does pattern offset `p` match, and where does it end? Capture spans land in a
//! fixed array as `(init, len)` offset pairs with Lua's `CAP_POSITION` /
//! `CAP_UNFINISHED` sentinels.
//!
//! Keeping the algorithm pure (no `Vm`, no allocation, no `Value`) is the
//! architectural point: it is unit-testable on plain `[]const u8`, and the
//! host-binding glue (`Value` construction, interning, the multi-result ABI,
//! the `gmatch` state table) lives entirely in `stdlib/string.zig`. Determinism
//! is automatic — a deterministic function of its byte inputs, no host effects.
//!
//! Char classes are C-locale ASCII (`%a %d %s %w %l %u %p %c %x %g` and their
//! upper-case complements), matching lune's fixed locale; the `%z` legacy class
//! is dropped per Lua 5.4 (so `%z` is a literal `z`).

const std = @import("std");

/// `LUA_MAXCAPTURES` — the capture-array bound.
pub const max_captures = 32;
/// `LJ_MAX_XLEVEL` / `MAXCCALLS` — recursion-depth guard for `match`.
const max_depth = 200;

/// `%`-escape introducer.
const l_esc = '%';

/// A located capture span. `len >= 0` is a closed string capture of that many
/// bytes at `init`; the two negatives are Lua's transient sentinels.
pub const Capture = struct {
    init: usize,
    len: isize,
};

/// Closed-but-positional capture (`()`): push `init + 1` as an integer.
pub const cap_position: isize = -2;
/// Open capture, not yet closed by its `)`.
pub const cap_unfinished: isize = -1;

pub const Error = error{
    /// Malformed pattern: unbalanced `[`, trailing `%`, `%b` missing its two
    /// chars, `%f` without a class, or an unfinished capture at use.
    MalformedPattern,
    /// More than `max_captures` open captures.
    TooManyCaptures,
    /// A back-reference (`%1`–`%9`) to a capture that doesn't exist / isn't closed.
    InvalidCapture,
    /// Recursion exceeded `max_depth` (pathological pattern).
    PatternTooComplex,
};

/// The matcher state: the subject and pattern bytes plus the in-progress
/// captures. One `MatchState` is reused across the anchored-scan attempts of a
/// single `find`/`match`/`gmatch`/`gsub` call; `reset` clears the per-attempt
/// bookkeeping (`level`, `depth`).
pub const MatchState = struct {
    src: []const u8,
    pat: []const u8,
    level: usize = 0,
    depth: u32 = 0,
    captures: [max_captures]Capture = undefined,

    pub fn init(src: []const u8, pat: []const u8) MatchState {
        return .{ .src = src, .pat = pat };
    }

    /// Clear per-attempt state before each scan position.
    pub fn reset(self: *MatchState) void {
        self.level = 0;
        self.depth = 0;
    }

    // -- character classes --------------------------------------------------

    /// `match_class(c, cl)` — does byte `c` belong to class letter `cl`? A
    /// non-class letter matches itself (so `%z` is a literal `z`, per 5.4). An
    /// upper-case class letter is the complement of its lower-case form.
    fn matchClass(c: u8, cl: u8) bool {
        const lower = std.ascii.toLower(cl);
        const res = switch (lower) {
            'a' => std.ascii.isAlphabetic(c),
            'c' => std.ascii.isControl(c),
            'd' => std.ascii.isDigit(c),
            'g' => c > 0x20 and c < 0x7f, // graph: printable, non-space
            'l' => std.ascii.isLower(c),
            'p' => (c > 0x20 and c < 0x7f) and !std.ascii.isAlphanumeric(c), // punct
            's' => std.ascii.isWhitespace(c),
            'u' => std.ascii.isUpper(c),
            'w' => std.ascii.isAlphanumeric(c),
            'x' => std.ascii.isHex(c),
            else => return cl == c, // not a class letter → literal
        };
        return if (std.ascii.isUpper(cl)) !res else res;
    }

    /// `classend(p)` — offset of the pattern item *after* the one at `p`.
    fn classEnd(self: *const MatchState, p: usize) Error!usize {
        const pat = self.pat;
        const c = pat[p];
        var pp = p + 1;
        switch (c) {
            l_esc => {
                if (pp >= pat.len) return error.MalformedPattern; // ends with '%'
                return pp + 1;
            },
            '[' => {
                if (pp < pat.len and pat[pp] == '^') pp += 1;
                // Scan to the closing ']' (mirrors the C do/while, with escapes).
                while (true) {
                    if (pp >= pat.len) return error.MalformedPattern; // missing ']'
                    const ch = pat[pp];
                    pp += 1;
                    if (ch == l_esc and pp < pat.len) pp += 1; // skip escaped char
                    if (pp < pat.len and pat[pp] == ']') break;
                }
                return pp + 1;
            },
            else => return pp,
        }
    }

    /// `matchbracketclass(c, p, ec)` — `p` at the `[`, `ec` at the closing `]`.
    fn matchBracket(self: *const MatchState, c: u8, p0: usize, ec: usize) bool {
        const pat = self.pat;
        var sig = true;
        var p = p0;
        if (pat[p + 1] == '^') {
            sig = false;
            p += 1; // skip the '^'
        }
        while (true) {
            p += 1;
            if (p >= ec) break;
            if (pat[p] == l_esc) {
                p += 1;
                if (matchClass(c, pat[p])) return sig;
            } else if (pat[p + 1] == '-' and p + 2 < ec) {
                p += 2;
                if (pat[p - 2] <= c and c <= pat[p]) return sig;
            } else if (pat[p] == c) {
                return sig;
            }
        }
        return !sig;
    }

    /// `singlematch(c, p, ep)` — does byte `c` match the single pattern item at
    /// `[p, ep)`?
    fn singleMatch(self: *const MatchState, c: u8, p: usize, ep: usize) bool {
        return switch (self.pat[p]) {
            '.' => true,
            l_esc => matchClass(c, self.pat[p + 1]),
            '[' => self.matchBracket(c, p, ep - 1),
            else => self.pat[p] == c,
        };
    }

    // -- captures -----------------------------------------------------------

    fn captureToClose(self: *MatchState) Error!usize {
        var level = self.level;
        while (level > 0) {
            level -= 1;
            if (self.captures[level].len == cap_unfinished) return level;
        }
        return error.MalformedPattern; // invalid pattern capture
    }

    fn checkCapture(self: *const MatchState, l: u8) Error!usize {
        // l is the digit char ('1'..'9'); index = l - '1'.
        if (l < '1') return error.InvalidCapture;
        const idx: usize = l - '1';
        if (idx >= self.level or self.captures[idx].len == cap_unfinished)
            return error.InvalidCapture;
        return idx;
    }

    fn startCapture(self: *MatchState, s: usize, p: usize, what: isize) Error!?usize {
        if (self.level >= max_captures) return error.TooManyCaptures;
        self.captures[self.level] = .{ .init = s, .len = what };
        self.level += 1;
        const res = try self.match(s, p);
        if (res == null) self.level -= 1; // undo capture
        return res;
    }

    fn endCapture(self: *MatchState, s: usize, p: usize) Error!?usize {
        const l = try self.captureToClose();
        self.captures[l].len = @intCast(s - self.captures[l].init); // close
        const res = try self.match(s, p);
        if (res == null) self.captures[l].len = cap_unfinished; // undo
        return res;
    }

    fn matchCapture(self: *MatchState, s: usize, l: u8) Error!?usize {
        const idx = try self.checkCapture(l);
        const cap = self.captures[idx];
        const len: usize = @intCast(cap.len);
        if (self.src.len - s >= len and
            std.mem.eql(u8, self.src[cap.init .. cap.init + len], self.src[s .. s + len]))
            return s + len;
        return null;
    }

    fn matchBalance(self: *MatchState, s: usize, p: usize) Error!?usize {
        const pat = self.pat;
        if (p + 1 >= pat.len) return error.MalformedPattern; // missing args to '%b'
        if (s >= self.src.len or self.src[s] != pat[p]) return null;
        const b = pat[p];
        const e = pat[p + 1];
        var cont: usize = 1;
        var ss = s;
        while (ss + 1 < self.src.len) {
            ss += 1;
            if (self.src[ss] == e) {
                cont -= 1;
                if (cont == 0) return ss + 1;
            } else if (self.src[ss] == b) {
                cont += 1;
            }
        }
        return null; // unbalanced
    }

    fn maxExpand(self: *MatchState, s: usize, p: usize, ep: usize) Error!?usize {
        var i: usize = 0;
        while (s + i < self.src.len and self.singleMatch(self.src[s + i], p, ep)) i += 1;
        // Greedy: try the longest run first, backing off one repetition at a time.
        while (true) {
            if (try self.match(s + i, ep + 1)) |r| return r;
            if (i == 0) return null;
            i -= 1;
        }
    }

    fn minExpand(self: *MatchState, s0: usize, p: usize, ep: usize) Error!?usize {
        var s = s0;
        while (true) {
            if (try self.match(s, ep + 1)) |r| return r;
            if (s < self.src.len and self.singleMatch(self.src[s], p, ep)) {
                s += 1; // one more repetition
            } else {
                return null;
            }
        }
    }

    // -- the matcher ---------------------------------------------------------

    /// `match(s, p)` — try to match pattern offset `p` at subject offset `s`.
    /// Returns the subject offset just past the match, or `null` on no match.
    /// `goto init` from the C is preserved as `continue` so literal runs don't
    /// consume recursion depth.
    pub fn match(self: *MatchState, s0: usize, p0: usize) Error!?usize {
        self.depth += 1;
        if (self.depth > max_depth) return error.PatternTooComplex;
        defer self.depth -= 1;

        const pat = self.pat;
        const src = self.src;
        var s = s0;
        var p = p0;

        while (true) {
            if (p >= pat.len) return s; // '\0' end of pattern → success

            dflt: {
                switch (pat[p]) {
                    '(' => {
                        if (p + 1 < pat.len and pat[p + 1] == ')')
                            return try self.startCapture(s, p + 2, cap_position) // position capture
                        else
                            return try self.startCapture(s, p + 1, cap_unfinished);
                    },
                    ')' => return try self.endCapture(s, p + 1),
                    '$' => {
                        if (p + 1 == pat.len) // '$' as last char → anchor to end
                            return if (s == src.len) s else null;
                        break :dflt; // a literal '$' mid-pattern
                    },
                    l_esc => {
                        const nx: u8 = if (p + 1 < pat.len) pat[p + 1] else 0;
                        switch (nx) {
                            'b' => {
                                const r = try self.matchBalance(s, p + 2);
                                if (r == null) return null;
                                s = r.?;
                                p += 4;
                                continue; // goto init
                            },
                            'f' => {
                                p += 2;
                                if (p >= pat.len or pat[p] != '[') return error.MalformedPattern; // missing '[' after %f
                                const ep = try self.classEnd(p);
                                const prev: u8 = if (s == 0) 0 else src[s - 1];
                                const cur: u8 = if (s < src.len) src[s] else 0;
                                if (self.matchBracket(prev, p, ep - 1) or
                                    !self.matchBracket(cur, p, ep - 1)) return null;
                                p = ep;
                                continue; // goto init
                            },
                            '0'...'9' => {
                                const r = try self.matchCapture(s, nx);
                                if (r == null) return null;
                                s = r.?;
                                p += 2;
                                continue; // goto init
                            },
                            else => break :dflt, // %x literal class item
                        }
                    },
                    else => break :dflt,
                }
            }

            // dflt: a single pattern item, possibly with a quantifier.
            const ep = try self.classEnd(p);
            const m = s < src.len and self.singleMatch(src[s], p, ep);
            const q: u8 = if (ep < pat.len) pat[ep] else 0;
            switch (q) {
                '?' => {
                    if (m) {
                        if (try self.match(s + 1, ep + 1)) |r| return r;
                    }
                    p = ep + 1;
                    continue; // goto init
                },
                '*' => return try self.maxExpand(s, p, ep),
                '+' => return if (m) try self.maxExpand(s + 1, p, ep) else null,
                '-' => return try self.minExpand(s, p, ep),
                else => {
                    if (m) {
                        s += 1;
                        p = ep;
                        continue; // goto init
                    }
                    return null;
                },
            }
        }
    }
};

/// `lj_str_haspattern` — does `pat` contain any pattern special? When it
/// doesn't (and `plain` isn't forced), `string.find` does a plain substring
/// search instead of running the matcher.
pub fn hasSpecials(pat: []const u8) bool {
    for (pat) |c| switch (c) {
        '^', '$', '*', '+', '?', '.', '(', '[', '%', '-' => return true,
        else => {},
    };
    return false;
}

// ---------------------------------------------------------------------------
// Tests — pure, on raw byte slices (no Vm).
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Find the first match of `pat` in `src` scanning from offset 0 (honoring a
/// leading `^` anchor). Returns `(start, end)` 0-based offsets, or null.
fn firstMatch(src: []const u8, pat: []const u8) !?[2]usize {
    var ms = MatchState.init(src, pat);
    var pp: usize = 0;
    var anchor = false;
    if (pat.len > 0 and pat[0] == '^') {
        anchor = true;
        pp = 1;
    }
    var s: usize = 0;
    while (true) {
        ms.reset();
        if (try ms.match(s, pp)) |e| return [2]usize{ s, e };
        if (s >= src.len or anchor) break;
        s += 1;
    }
    return null;
}

test "literal and dot match" {
    try testing.expectEqual(@as(?[2]usize, .{ 1, 4 }), try firstMatch("xabcy", "abc"));
    try testing.expectEqual(@as(?[2]usize, .{ 0, 3 }), try firstMatch("abc", "a.c"));
    try testing.expectEqual(@as(?[2]usize, null), try firstMatch("abc", "xyz"));
}

test "anchors ^ and $" {
    try testing.expectEqual(@as(?[2]usize, .{ 0, 3 }), try firstMatch("abcabc", "^abc"));
    try testing.expectEqual(@as(?[2]usize, .{ 3, 6 }), try firstMatch("abcabc", "abc$"));
    try testing.expectEqual(@as(?[2]usize, null), try firstMatch("xabc", "^abc"));
}

test "classes and quantifiers" {
    try testing.expectEqual(@as(?[2]usize, .{ 0, 3 }), try firstMatch("123abc", "%d+"));
    try testing.expectEqual(@as(?[2]usize, .{ 3, 6 }), try firstMatch("123abc", "%a+"));
    // '-' lazy: matches the shortest run (empty here, before 'a').
    try testing.expectEqual(@as(?[2]usize, .{ 0, 0 }), try firstMatch("aaa", "a-"));
    // '*' greedy.
    try testing.expectEqual(@as(?[2]usize, .{ 0, 3 }), try firstMatch("aaa", "a*"));
    // '?' optional.
    try testing.expectEqual(@as(?[2]usize, .{ 0, 2 }), try firstMatch("ab", "ab?"));
    try testing.expectEqual(@as(?[2]usize, .{ 0, 1 }), try firstMatch("ac", "ab?"));
}

test "sets, ranges, complements" {
    try testing.expectEqual(@as(?[2]usize, .{ 0, 3 }), try firstMatch("abc1", "[a-c]+"));
    try testing.expectEqual(@as(?[2]usize, .{ 3, 4 }), try firstMatch("abc1", "[^a-c]"));
    try testing.expectEqual(@as(?[2]usize, .{ 0, 2 }), try firstMatch("a.b", "[.a]+"));
}

test "captures recorded as offset spans" {
    var ms = MatchState.init("key=val", "(%a+)=(%a+)");
    ms.reset();
    const e = (try ms.match(0, 0)).?;
    try testing.expectEqual(@as(usize, 7), e);
    try testing.expectEqual(@as(usize, 2), ms.level);
    try testing.expectEqual(Capture{ .init = 0, .len = 3 }, ms.captures[0]); // "key"
    try testing.expectEqual(Capture{ .init = 4, .len = 3 }, ms.captures[1]); // "val"
}

test "position capture ()" {
    var ms = MatchState.init("abc", "a()c?b?()");
    ms.reset();
    _ = (try ms.match(0, 0)).?;
    try testing.expectEqual(@as(usize, 2), ms.level);
    try testing.expectEqual(cap_position, ms.captures[0].len);
    try testing.expectEqual(@as(usize, 1), ms.captures[0].init); // position 2 (1-based)
}

test "back-reference %1" {
    try testing.expectEqual(@as(?[2]usize, .{ 0, 4 }), try firstMatch("abab", "(ab)%1"));
    try testing.expectEqual(@as(?[2]usize, null), try firstMatch("abcd", "(ab)%1"));
}

test "%b balanced match" {
    try testing.expectEqual(@as(?[2]usize, .{ 0, 6 }), try firstMatch("(a(b))x", "%b()"));
}

test "%f frontier" {
    // First transition from non-letter to letter starting word "THE".
    try testing.expectEqual(@as(?[2]usize, .{ 0, 3 }), try firstMatch("THE (quick)", "%f[%a]%a+"));
}

test "malformed patterns error" {
    var ms = MatchState.init("abc", "[abc");
    ms.reset();
    try testing.expectError(error.MalformedPattern, ms.match(0, 0));

    var ms2 = MatchState.init("abc", "%");
    ms2.reset();
    try testing.expectError(error.MalformedPattern, ms2.match(0, 0));

    var ms3 = MatchState.init("abc", "(ab)%2");
    ms3.reset();
    try testing.expectError(error.InvalidCapture, ms3.match(0, 0));
}

test "hasSpecials" {
    try testing.expect(!hasSpecials("plain text"));
    try testing.expect(hasSpecials("a.b"));
    try testing.expect(hasSpecials("%d"));
    try testing.expect(hasSpecials("[abc]"));
}
