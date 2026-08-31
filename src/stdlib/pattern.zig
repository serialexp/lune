//! mahina stdlib — the Lua pattern-matching engine (pure, host-free).
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
//! upper-case complements), matching mahina's fixed locale; the `%z` legacy class
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
    //
    // Doc 29 A1: the two-table design from LuaJIT (`lib_string.c:210-228`,
    // `lj_char.c`). `char_bits` is built AT COMPTIME by evaluating the same
    // predicates the old switch-based `matchClass` used, so the table is
    // definitionally equal to the previous semantics; the exhaustive 256×256
    // parity test below pins it against an independent reference copy.

    /// Primitive class bits. Composites: alpha = upper|lower, alnum =
    /// alpha|digit, graph = alnum|punct (punct is "printable, non-space,
    /// non-alnum", so the union is exactly "printable, non-space").
    const bits_cntrl: u8 = 0x01;
    const bits_space: u8 = 0x02;
    const bits_punct: u8 = 0x04;
    const bits_digit: u8 = 0x08;
    const bits_xdigit: u8 = 0x10;
    const bits_upper: u8 = 0x20;
    const bits_lower: u8 = 0x40;
    const bits_alpha: u8 = bits_upper | bits_lower;
    const bits_alnum: u8 = bits_alpha | bits_digit;
    const bits_graph: u8 = bits_alnum | bits_punct;

    /// Per-byte class bits. Bytes ≥ 0x80 carry no bits — mahina's classes are
    /// ASCII-only (the S-D rule); complements of high bytes are handled by
    /// the callers' `< 0x80` guards (and `%f`'s deliberate lack of one).
    const char_bits: [256]u8 = blk: {
        var t: [256]u8 = @splat(0);
        for (0..0x80) |i| {
            const c: u8 = @intCast(i);
            var b: u8 = 0;
            if (std.ascii.isControl(c)) b |= bits_cntrl;
            if (std.ascii.isWhitespace(c)) b |= bits_space;
            if ((c > 0x20 and c < 0x7f) and !std.ascii.isAlphanumeric(c)) b |= bits_punct;
            if (std.ascii.isDigit(c)) b |= bits_digit;
            if (std.ascii.isHex(c)) b |= bits_xdigit;
            if (std.ascii.isUpper(c)) b |= bits_upper;
            if (std.ascii.isLower(c)) b |= bits_lower;
            t[i] = b;
        }
        break :blk t;
    };

    /// `cl & 0x1f` → bit mask for the 10 class letters (case-folded by
    /// construction: 'a' and 'A' share an index). 0 = not a class letter.
    const class_map: [32]u8 = blk: {
        var m: [32]u8 = @splat(0);
        m['a' & 0x1f] = bits_alpha;
        m['c' & 0x1f] = bits_cntrl;
        m['d' & 0x1f] = bits_digit;
        m['g' & 0x1f] = bits_graph;
        m['l' & 0x1f] = bits_lower;
        m['p' & 0x1f] = bits_punct;
        m['s' & 0x1f] = bits_space;
        m['u' & 0x1f] = bits_upper;
        m['w' & 0x1f] = bits_alnum;
        m['x' & 0x1f] = bits_xdigit;
        break :blk m;
    };

    /// `match_class(c, cl)` — does byte `c` belong to class letter `cl`? A
    /// non-class letter matches itself (so `%z` is a literal `z`, per 5.4). An
    /// upper-case class letter is the complement of its lower-case form.
    /// One table load + two masks, no branch on the class letter (doc 29 A1).
    fn matchClass(c: u8, cl: u8) bool {
        if ((cl & 0xc0) == 0x40) { // an ASCII letter, either case
            const t = class_map[cl & 0x1f];
            if (t != 0) {
                const res = (char_bits[c] & t) != 0;
                // bit 0x20 set = lowercase letter = positive class.
                return if ((cl & 0x20) != 0) res else !res;
            }
        }
        return cl == c; // not a class letter → literal
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
            else => {
                // A literal pattern item. ASCII → one byte (`pp == p + 1`). A
                // UTF-8 lead byte (≥0x80) groups its continuation bytes so a
                // multibyte literal is ONE item and a following quantifier binds
                // the whole character (`é*`, `é+`, `(é)`). The pattern is NOT
                // guaranteed valid UTF-8 (it can be `string.char`/`decode`-built),
                // so `catch 1` + the `@min` clamp keep `classEnd` total on a
                // truncated/lone-continuation tail (degrades to a 1-byte literal).
                if (c < 0x80) return pp;
                const n: usize = std.unicode.utf8ByteSequenceLength(c) catch 1;
                return @min(p + n, pat.len);
            },
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

    /// Byte width of the UTF-8 code point starting at subject offset `s` (S-D).
    /// `src` is always valid UTF-8 (the S-B invariant), so the lead byte is
    /// well-formed; `catch 1` is a total-function backstop. Never returns 0 and
    /// never overshoots `src.len`, so advancing `s += seqLen(s)` from a code-point
    /// boundary always lands on the next boundary and reaches `src.len` exactly —
    /// keeping every `s == src.len` / `s < src.len` end-check valid. `pub` because
    /// the `string.zig` outer scans (`find`/`gmatch`/`gsub`) step by it too.
    pub fn seqLen(self: *const MatchState, s: usize) usize {
        if (s >= self.src.len) return 0;
        const b = self.src[s];
        if (b < 0x80) return 1; // doc 29 A3: ASCII fast path
        const n: usize = std.unicode.utf8ByteSequenceLength(b) catch 1;
        return @min(n, self.src.len - s);
    }

    /// `singlematch(s, p, ep)` — does the single pattern item at `[p, ep)` match
    /// the code point at subject offset `s`? (S-D: takes a subject offset, not a
    /// pre-read byte, so the literal arm can compare a whole multibyte sequence.)
    /// `.` matches any one code point; a `%`-class / bracket set matches exactly
    /// one **ASCII** byte — the `src[s] < 0x80` guard is load-bearing, not an
    /// optimization: without it a UTF-8 continuation/lead byte (≥0x80) would
    /// wrongly satisfy a *complement* class (`%A`/`%D`/`%S`, `[^…]`), which test
    /// `!isAlphabetic(b)` etc. and so return true for a high byte.
    fn singleMatch(self: *const MatchState, s: usize, p: usize, ep: usize) bool {
        if (s >= self.src.len) return false;
        const c = self.src[s];
        return switch (self.pat[p]) {
            '.' => true,
            l_esc => c < 0x80 and matchClass(c, self.pat[p + 1]),
            '[' => c < 0x80 and self.matchBracket(c, p, ep - 1),
            // Doc 29 A2: a 1-byte literal item is a single compare (the
            // overwhelmingly common case); multibyte items keep the slice
            // compare. Identical semantics — litEq on a 1-byte item is
            // exactly this compare.
            else => if (ep - p == 1) c == self.pat[p] else self.litEq(s, p, ep),
        };
    }

    /// A literal pattern item spans `pat[p..ep)` — one byte for an ASCII literal,
    /// the whole lead+continuation run for a multibyte literal (grouped by
    /// `classEnd`). It matches iff the subject sequence at `s` is byte-identical,
    /// which for valid UTF-8 is equivalent to a code-point compare (the encoding
    /// is canonical/prefix-free).
    fn litEq(self: *const MatchState, s: usize, p: usize, ep: usize) bool {
        const item = self.pat[p..ep];
        return self.src.len - s >= item.len and
            std.mem.eql(u8, self.src[s .. s + item.len], item);
    }

    /// Byte width consumed by a *successful* `singleMatch` of the item at `p`
    /// starting at `s`. `.` consumes the whole subject code point; a class/
    /// bracket consume exactly one byte (the `singleMatch` guard proved it
    /// ASCII); a *valid* literal item consumes its own byte length (doc 29 A3
    /// — byte-equality of valid UTF-8 proves equal encoded width, so no
    /// re-decode). Carve-out (doc 29 review M3): a malformed 1-byte item with
    /// a high lead byte (`classEnd`'s degraded-tail case) keeps the subject-
    /// width `seqLen` so the defensive boundary-alignment contract holds.
    fn matchWidth(self: *const MatchState, s: usize, p: usize, ep: usize) usize {
        return switch (self.pat[p]) {
            l_esc, '[' => 1,
            '.' => self.seqLen(s),
            else => blk: {
                const w = ep - p;
                if (w == 1 and self.pat[p] >= 0x80) break :blk self.seqLen(s);
                break :blk w;
            },
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

    /// Doc 29 A4: the greedy counting loop with the item-kind switch hoisted
    /// OUT of the per-byte loop (LuaJIT's `max_expand` calls `singlematch`
    /// per iteration and relies on the C compiler to specialize; this makes
    /// the specialization explicit). Returns the furthest boundary `cur ≥ s0`
    /// such that every item repetition in `[s0, cur)` matches — exactly the
    /// old `while (singleMatch) cur += matchWidth` outcome, pinned per-kind
    /// by directed tests.
    fn countRun(self: *const MatchState, s0: usize, p: usize, ep: usize) usize {
        const src = self.src;
        var cur = s0;
        switch (self.pat[p]) {
            // Every code point matches '.', and `src` is valid UTF-8 at the
            // matcher boundary (S-B), so the run ends exactly at src.len.
            '.' => return src.len,
            l_esc => {
                const cl = self.pat[p + 1];
                if ((cl & 0xc0) == 0x40 and class_map[cl & 0x1f] != 0) {
                    const t = class_map[cl & 0x1f];
                    const positive = (cl & 0x20) != 0;
                    // A class item matches exactly one ASCII byte (the
                    // load-bearing `< 0x80` guard) — width is constant 1.
                    while (cur < src.len and src[cur] < 0x80 and
                        ((char_bits[src[cur]] & t) != 0) == positive) cur += 1;
                } else {
                    // Review M2: an escaped LITERAL item (`%z+`, `%%+`,
                    // `%q*` — matchClass's fallthrough): repeated 1-byte
                    // equality. A `cl >= 0x80` never matches (the old
                    // `< 0x80` guard), which this compare reproduces.
                    while (cur < src.len and src[cur] < 0x80 and src[cur] == cl) cur += 1;
                }
                return cur;
            },
            '[' => {
                while (cur < src.len and src[cur] < 0x80 and
                    self.matchBracket(src[cur], p, ep - 1)) cur += 1;
                return cur;
            },
            else => {
                const w = ep - p;
                if (w == 1 and self.pat[p] >= 0x80) {
                    // Malformed 1-byte high item (review M3): keep the old
                    // byte-test + subject-width advance exactly.
                    while (self.singleMatch(cur, p, ep)) cur += self.matchWidth(cur, p, ep);
                    return cur;
                }
                if (w == 1) {
                    const b = self.pat[p];
                    while (cur < src.len and src[cur] == b) cur += 1;
                    return cur;
                }
                const item = self.pat[p..ep];
                while (src.len - cur >= item.len and
                    std.mem.eql(u8, src[cur .. cur + item.len], item)) cur += item.len;
                return cur;
            },
        }
    }

    fn maxExpand(self: *MatchState, s: usize, p: usize, ep: usize) Error!?usize {
        // Greedily consume matching code points (S-D: the run counter steps by
        // item width — doc 29 A4 hoists the item-kind dispatch out of the loop).
        var cur = self.countRun(s, p, ep);
        // Greedy: try the longest run first, backing off ONE code point at a time.
        // Stepping `cur` back to the previous boundary is an O(1) backward scan
        // over continuation bytes (valid because `src` is valid UTF-8) — so no
        // scratch buffer / allocation is needed to undo variable-width repetitions.
        while (true) {
            if (try self.match(cur, ep + 1)) |r| return r;
            if (cur == s) return null;
            cur -= 1;
            while (cur > s and (self.src[cur] & 0xC0) == 0x80) cur -= 1;
        }
    }

    fn minExpand(self: *MatchState, s0: usize, p: usize, ep: usize) Error!?usize {
        var s = s0;
        while (true) {
            if (try self.match(s, ep + 1)) |r| return r;
            if (self.singleMatch(s, p, ep)) {
                s += self.matchWidth(s, p, ep); // one more repetition, by code point
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

            // dflt: a single pattern item, possibly with a quantifier. (S-D: the
            // subject advances by the matched item's code-point width, not 1 byte.)
            const ep = try self.classEnd(p);
            const m = self.singleMatch(s, p, ep);
            const w = if (m) self.matchWidth(s, p, ep) else 0;
            const q: u8 = if (ep < pat.len) pat[ep] else 0;
            switch (q) {
                '?' => {
                    if (m) {
                        if (try self.match(s + w, ep + 1)) |r| return r;
                    }
                    p = ep + 1;
                    continue; // goto init
                },
                '*' => return try self.maxExpand(s, p, ep),
                '+' => return if (m) try self.maxExpand(s + w, p, ep) else null,
                '-' => return try self.minExpand(s, p, ep),
                else => {
                    if (m) {
                        s += w;
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
// Doc 30 P3: the ONE pure locate step, shared by the tier-0 wrappers
// (`string.zig` find/match/gmatch), the recorder's record-time outcome
// computation, and the native callout shims. No `*Vm`, no `Value`, no
// interning — the matcher allocates nothing.
// ---------------------------------------------------------------------------

/// A located match: `[start, end)` byte offsets into `ms.src`. The completed
/// `MatchState` (captures) travels alongside — the caller owns `ms`.
pub const Span = struct {
    start: usize,
    end: usize,
};

/// The anchored-scan loop of `find`/`match`/`gmatch`: try `ms.match` at
/// `from`, then at each successive code-point boundary, until a match or
/// end-of-subject. `consume_anchor` is the find/match flavor — a leading `^`
/// pins the single attempt at `from` (gmatch passes false: its `^` is an
/// ordinary literal item, exactly as tier-0's `gmatchAuxCore` always ran it).
/// On success `ms` holds the winning attempt's captures. `from > src.len`
/// (a gmatch cursor past the end) locates nothing.
pub fn locateMatch(ms: *MatchState, from: usize, consume_anchor: bool) Error!?Span {
    if (from > ms.src.len) return null;
    var pp: usize = 0;
    var anchor = false;
    if (consume_anchor and ms.pat.len > 0 and ms.pat[0] == '^') {
        anchor = true;
        pp = 1;
    }
    var sp = from;
    while (true) {
        ms.reset();
        if (try ms.match(sp, pp)) |e| return .{ .start = sp, .end = e };
        if (sp >= ms.src.len or anchor) break;
        sp += ms.seqLen(sp); // S-D: advance the scan by a whole code point
    }
    return null;
}

// ---------------------------------------------------------------------------
// Doc 30 P1: the static pattern census.
// ---------------------------------------------------------------------------

/// What kind of value capture `k` produces (`push_onecapture`'s split).
pub const CapKind = enum(u8) {
    /// `(...)` — a byte span, interned to a string.
    span,
    /// `()` — a 1-based character position, an integer.
    position,
};

/// The statically-known shape of a pattern: everything the trace recorder
/// needs to fix a match op's projection list at record time (doc 30 P1).
pub const Census = struct {
    /// Total captures a successful match produces (Lua patterns have no
    /// alternation and no quantifiable groups, so every syntactic capture
    /// opens on ANY successful full-pattern match — `ms.level == ncap`).
    ncap: u8 = 0,
    kinds: [max_captures]CapKind = @splat(.span),
    /// Leading `^` (meaningful to find/match, where the caller consumes it).
    anchored: bool = false,
    /// `hasSpecials(pat)` — false selects find's plain-substring bypass.
    specials: bool = false,
};

/// Walk `pat` with the SAME item stepping the matcher uses (`classEnd`) and
/// return its census, or null when the pattern cannot be statically
/// validated: trailing `%`, unbalanced `[`/captures, `%b` missing its two
/// chars, `%f` without a class, more than `max_captures`. Null means the
/// recorder aborts and the call stays tier-0 (fail-closed). Runtime-only
/// errors — back-reference validity, `PatternTooComplex` depth — remain the
/// callout shim's negative-status channel (doc 30 M03).
pub fn census(pat: []const u8) ?Census {
    var out = Census{ .specials = hasSpecials(pat) };
    const ms = MatchState.init(&.{}, pat); // classEnd reads only `pat`
    var p: usize = 0;
    if (pat.len > 0 and pat[0] == '^') {
        out.anchored = true;
        p = 1;
    }
    var depth: usize = 0;
    while (p < pat.len) {
        switch (pat[p]) {
            '(' => {
                if (out.ncap >= max_captures) return null;
                if (p + 1 < pat.len and pat[p + 1] == ')') {
                    out.kinds[out.ncap] = .position;
                    p += 2;
                } else {
                    out.kinds[out.ncap] = .span;
                    depth += 1;
                    p += 1;
                }
                out.ncap += 1;
            },
            ')' => {
                if (depth == 0) return null; // close with nothing open
                depth -= 1;
                p += 1;
            },
            l_esc => {
                if (p + 1 >= pat.len) return null; // ends with '%'
                switch (pat[p + 1]) {
                    'b' => {
                        if (p + 4 > pat.len) return null; // %b needs two chars
                        p += 4;
                    },
                    'f' => {
                        if (p + 2 >= pat.len or pat[p + 2] != '[') return null;
                        p = ms.classEnd(p + 2) catch return null;
                    },
                    else => p += 2, // class letter, escaped literal, or %1-%9
                }
            },
            else => p = ms.classEnd(p) catch return null,
        }
    }
    if (depth != 0) return null; // unfinished capture
    return out;
}

// ---------------------------------------------------------------------------
// Tests — pure, on raw byte slices (no Vm).
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Find the first match of `pat` in `src` scanning from offset 0 (honoring a
/// leading `^` anchor). Returns `(start, end)` 0-based offsets, or null.
/// Since doc 30 this rides the shared `locateMatch` core, so every test below
/// exercises the same loop the wrappers, the recorder, and the shims run.
fn firstMatch(src: []const u8, pat: []const u8) !?[2]usize {
    var ms = MatchState.init(src, pat);
    const span = (try locateMatch(&ms, 0, true)) orelse return null;
    return [2]usize{ span.start, span.end };
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

// ---------------------------------------------------------------------------
// S-D — the subject steps by code point. Byte-offset asserts (the boundary in
// string.zig converts to character indices). "é" = C3 A9 (2 bytes), "ß" = C3 9F,
// "€" = E2 82 AC (3 bytes). All returned offsets land on code-point boundaries.
// ---------------------------------------------------------------------------

test "S-D: '.' matches one whole code point" {
    // "é" is 2 bytes; '.' consumes the whole character, not one byte.
    try testing.expectEqual(@as(?[2]usize, .{ 0, 2 }), try firstMatch("é", "."));
    // 'b' after "aé": '.' over the 'é' lands the literal 'b' at the right byte.
    try testing.expectEqual(@as(?[2]usize, .{ 0, 4 }), try firstMatch("aéb", "a.b"));
}

test "S-D: '(.)' captures a whole multibyte code point" {
    var ms = MatchState.init("é", "(.)");
    ms.reset();
    const e = (try ms.match(0, 0)).?;
    try testing.expectEqual(@as(usize, 2), e);
    try testing.expectEqual(Capture{ .init = 0, .len = 2 }, ms.captures[0]); // whole "é"
}

test "S-D: greedy/lazy quantifiers over mixed ASCII+multibyte" {
    // '.*' greedy consumes everything, ending exactly at the byte length.
    try testing.expectEqual(@as(?[2]usize, .{ 0, 5 }), try firstMatch("aé b", ".*"));
    // '.*b' backtracks by whole code points to land 'b'.
    try testing.expectEqual(@as(?[2]usize, .{ 0, 4 }), try firstMatch("aéb", ".*b"));
    // '.-c' lazy: shortest run, stepping by code point.
    try testing.expectEqual(@as(?[2]usize, .{ 0, 5 }), try firstMatch("aébc", ".-c"));
}

test "S-D: a literal multibyte char is one item under a quantifier" {
    // 'é+' must quantify the whole 2-byte char, not split it (classEnd grouping).
    try testing.expectEqual(@as(?[2]usize, .{ 0, 6 }), try firstMatch("ééé", "é+"));
    try testing.expectEqual(@as(?[2]usize, .{ 0, 4 }), try firstMatch("ééx", "é+"));
    // 'é?' optional: zero repetitions at a non-é subject is an empty match.
    try testing.expectEqual(@as(?[2]usize, .{ 0, 0 }), try firstMatch("x", "é?"));
    // '€*' with a 3-byte char.
    try testing.expectEqual(@as(?[2]usize, .{ 0, 6 }), try firstMatch("€€a", "€*"));
}

test "S-D: ASCII classes stop at a non-ASCII byte and never match high bytes" {
    // '%a+' consumes ASCII letters then stops before é's lead byte (0xC3).
    try testing.expectEqual(@as(?[2]usize, .{ 0, 2 }), try firstMatch("abéc", "%a+"));
    // A complement class '%A' must NOT match a UTF-8 lead/continuation byte: an
    // all-multibyte subject has no %A match at all (the load-bearing <0x80 guard).
    try testing.expectEqual(@as(?[2]usize, null), try firstMatch("éé", "%A"));
    // '%s' / '%d' likewise never match high bytes.
    try testing.expectEqual(@as(?[2]usize, null), try firstMatch("é", "%d"));
}

test "S-D: anchors, %b, and back-references with multibyte" {
    try testing.expectEqual(@as(?[2]usize, .{ 0, 2 }), try firstMatch("éabc", "^é"));
    // %b() with ASCII delimiters and a multibyte body.
    try testing.expectEqual(@as(?[2]usize, .{ 0, 5 }), try firstMatch("(aé)x", "%b()"));
    // Back-reference re-matches a captured multibyte span byte-for-byte.
    try testing.expectEqual(@as(?[2]usize, .{ 0, 4 }), try firstMatch("éé", "(é)%1"));
    try testing.expectEqual(@as(?[2]usize, null), try firstMatch("éx", "(é)%1"));
}

test "S-D: %f frontier classifies a multibyte char by its (non-ASCII) bytes" {
    // `%f` is the one matcher path that feeds subject bytes to an ASCII bracket
    // set WITHOUT the `singleMatch` `< 0x80` guard — deliberately: it is
    // zero-width (consumes nothing, so it can never split a code point) and is a
    // byte-for-byte port of Lua 5.4's frontier (`prev = src[s-1]`, `cur = src[s]`).
    // Under mahina's ASCII-only classes a multibyte char is NOT an ASCII letter, so
    // every one of its bytes reads as `%A` (non-alpha). The frontier therefore
    // fires entering a multibyte char from an ASCII letter — consistent with the
    // documented "classes stay ASCII" rule, not a leak of the guard. Pinned so the
    // decision is explicit.
    // 'a' then a frontier INTO a non-ASCII-alpha region (the 'é'): fires, so the
    // zero-width match ends right after the 'a' (byte 1).
    try testing.expectEqual(@as(?[2]usize, .{ 0, 1 }), try firstMatch("aé", "a%f[%A]"));
    // Between two ASCII letters there is no %A frontier: no match anywhere.
    try testing.expectEqual(@as(?[2]usize, null), try firstMatch("ab", "a%f[%A]"));
    // Symmetric: a frontier INTO ASCII-alpha fires at the boundary after the 'é'.
    try testing.expectEqual(@as(?[2]usize, .{ 2, 3 }), try firstMatch("éb", "%f[%a]%a"));
}

// ---------------------------------------------------------------------------
// Doc 29 A-series pins.
// ---------------------------------------------------------------------------

/// Independent reference copy of the pre-doc-29 switch-based `matchClass` —
/// deliberately NOT derived from the table or its generator (review M4: a
/// table checked against its own source is tautological).
fn refMatchClass(c: u8, cl: u8) bool {
    const lower = std.ascii.toLower(cl);
    const res = switch (lower) {
        'a' => std.ascii.isAlphabetic(c),
        'c' => std.ascii.isControl(c),
        'd' => std.ascii.isDigit(c),
        'g' => c > 0x20 and c < 0x7f,
        'l' => std.ascii.isLower(c),
        'p' => (c > 0x20 and c < 0x7f) and !std.ascii.isAlphanumeric(c),
        's' => std.ascii.isWhitespace(c),
        'u' => std.ascii.isUpper(c),
        'w' => std.ascii.isAlphanumeric(c),
        'x' => std.ascii.isHex(c),
        else => return cl == c,
    };
    return if (std.ascii.isUpper(cl)) !res else res;
}

test "doc 29 A1: matchClass table parity — full 256x256 cross-product" {
    var c: usize = 0;
    while (c < 256) : (c += 1) {
        var cl: usize = 0;
        while (cl < 256) : (cl += 1) {
            const want = refMatchClass(@intCast(c), @intCast(cl));
            const got = MatchState.matchClass(@intCast(c), @intCast(cl));
            if (want != got) {
                std.debug.print("matchClass parity fail: c=0x{x} cl=0x{x} want={} got={}\n", .{ c, cl, want, got });
                return error.TestUnexpectedResult;
            }
        }
    }
    // Explicit pins (review M4): %s on VT/FF, %c on DEL, high bytes bitless.
    try testing.expect(MatchState.matchClass(0x0B, 's'));
    try testing.expect(MatchState.matchClass(0x0C, 's'));
    try testing.expect(MatchState.matchClass(0x7F, 'c'));
    try testing.expect(!MatchState.matchClass(0xC3, 'a'));
    try testing.expect(MatchState.matchClass(0xC3, 'A')); // complement of a bitless byte
}

/// Reference counting loop — the pre-doc-29 `maxExpand` head, verbatim.
fn refCountRun(ms: *const MatchState, s0: usize, p: usize, ep: usize) usize {
    var cur = s0;
    while (ms.singleMatch(cur, p, ep)) cur += ms.matchWidth(cur, p, ep);
    return cur;
}

test "doc 29 A4: countRun equals the old loop for every item kind" {
    // (subject, pattern, item offset) triples; classEnd(p) supplies ep.
    const cases = [_]struct { src: []const u8, pat: []const u8 }{
        .{ .src = "aaabé cd", .pat = "a" }, // 1-byte literal
        .{ .src = "ééxé", .pat = "é" }, // multibyte literal
        .{ .src = "abé12 x", .pat = "." }, // dot: whole subject
        .{ .src = "123abc", .pat = "%d" }, // class positive
        .{ .src = "abc123", .pat = "%D" }, // class complement
        .{ .src = "é123", .pat = "%D" }, // complement at a multibyte boundary
        .{ .src = "zzzab", .pat = "%z" }, // escaped literal (not a class, 5.4)
        .{ .src = "%%%a", .pat = "%%" }, // escaped '%'
        .{ .src = "qqqx", .pat = "%q" }, // escaped plain letter
        .{ .src = "abc,def", .pat = "[^,]" }, // bracket complement
        .{ .src = "a-b-c", .pat = "[a-c-]" }, // bracket with range + literal '-'
        .{ .src = "", .pat = "%d" }, // empty subject
        .{ .src = "ééé", .pat = "%A" }, // complement class over pure multibyte (never matches: <0x80 guard)
        .{ .src = "é", .pat = "\xC3" }, // malformed 1-byte high item (M3 carve-out)
    };
    for (cases) |tc| {
        var ms = MatchState.init(tc.src, tc.pat);
        ms.reset();
        const ep = try ms.classEnd(0);
        // From offset 0 and from every code-point boundary.
        var s: usize = 0;
        while (true) {
            try testing.expectEqual(refCountRun(&ms, s, 0, ep), ms.countRun(s, 0, ep));
            if (s >= tc.src.len) break;
            s += ms.seqLen(s);
        }
    }
}

test "doc 29 A4: escaped-literal quantifiers behave as before" {
    // %z is a literal 'z' per 5.4 (the class was dropped) — quantified.
    try testing.expectEqual(@as(?[2]usize, .{ 0, 3 }), try firstMatch("zzzab", "%z+"));
    try testing.expectEqual(@as(?[2]usize, .{ 0, 0 }), try firstMatch("abc", "%z*"));
    // %% quantified: a run of literal percent signs.
    try testing.expectEqual(@as(?[2]usize, .{ 1, 3 }), try firstMatch("a%%b", "%%+"));
    // %q (escaped plain letter) quantified.
    try testing.expectEqual(@as(?[2]usize, .{ 0, 2 }), try firstMatch("qqx", "%q+"));
}

test "S-D: classEnd is total on a truncated multibyte pattern tail" {
    // Defensive: the matcher accepts arbitrary []const u8, but every *real* mahina
    // string (subject AND pattern) is valid UTF-8 (the S-B invariant), so a
    // pattern with a lone lead byte 0xC3 is unreachable in practice. We only
    // require totality here: classEnd must not read past pat.len and match must
    // return a boundary-aligned result without panicking. (The degenerate
    // outcome — the 1-byte literal byte-matches é's lead byte and then advances
    // by the whole code point — is not a contract, just "no crash".)
    var ms = MatchState.init("é", "\xC3");
    ms.reset();
    const r = try ms.match(0, 0); // must not panic / read OOB
    if (r) |e| try testing.expect(e == 0 or e == 2); // boundary-aligned if it matched
}

// ---------------------------------------------------------------------------
// Doc 30 c1 — locateMatch and census.
// ---------------------------------------------------------------------------

test "doc 30: locateMatch honors from and the gmatch (non-consuming) flavor" {
    // Continue-from-position: the second "ab" is found when from skips the first.
    var ms = MatchState.init("ab ab", "ab");
    const s1 = (try locateMatch(&ms, 0, true)).?;
    try testing.expectEqual(Span{ .start = 0, .end = 2 }, s1);
    const s2 = (try locateMatch(&ms, 1, true)).?;
    try testing.expectEqual(Span{ .start = 3, .end = 5 }, s2);
    // from past the end (a gmatch cursor after an empty-match bump at EOS).
    try testing.expectEqual(@as(?Span, null), try locateMatch(&ms, 6, false));
    // from == src.len: the empty pattern still matches at end-of-string.
    var ms2 = MatchState.init("ab", "");
    const s3 = (try locateMatch(&ms2, 2, false)).?;
    try testing.expectEqual(Span{ .start = 2, .end = 2 }, s3);
    // gmatch flavor: '^' is a literal item, not an anchor.
    var ms3 = MatchState.init("x^y", "^y");
    const s4 = (try locateMatch(&ms3, 0, false)).?;
    try testing.expectEqual(Span{ .start = 1, .end = 3 }, s4);
    // find/match flavor: same pattern anchors and fails off-position.
    var ms4 = MatchState.init("x^y", "^y");
    try testing.expectEqual(@as(?Span, null), try locateMatch(&ms4, 0, true));
}

test "doc 30: census counts and kinds agree with the matcher on a corpus" {
    // For every pattern that census accepts and that matches the subject, the
    // completed MatchState must agree: level == ncap, and each capture's
    // position-ness matches kinds[k].
    const cases = [_]struct { src: []const u8, pat: []const u8 }{
        .{ .src = "abc123", .pat = "%d+" },
        .{ .src = "key=val", .pat = "(%a+)=(%a+)" },
        .{ .src = "abc", .pat = "()" },
        .{ .src = "abc", .pat = "a()c?b?()" },
        .{ .src = "aXb", .pat = "((a)X)" },
        .{ .src = "(x)", .pat = "%((%a)%)" },
        .{ .src = "do end", .pat = "%bde" },
        .{ .src = " word", .pat = "%f[%a]%a+" },
        .{ .src = "a,b,,c", .pat = "[^,]+" },
        .{ .src = "x]y", .pat = "[]x]+" },
        .{ .src = "resumé!", .pat = "é" },
        .{ .src = "resumé!", .pat = "(é)!" },
        .{ .src = "abcabc", .pat = "^a(b)c" },
        .{ .src = "%d", .pat = "%%d" },
        .{ .src = "1;2", .pat = "(%d)();" },
    };
    for (cases) |tc| {
        const c = census(tc.pat) orelse {
            std.debug.print("census rejected valid pattern [{s}]\n", .{tc.pat});
            return error.TestUnexpectedResult;
        };
        var ms = MatchState.init(tc.src, tc.pat);
        const span = (try locateMatch(&ms, 0, true)) orelse {
            std.debug.print("corpus pattern [{s}] failed to match [{s}]\n", .{ tc.pat, tc.src });
            return error.TestUnexpectedResult;
        };
        _ = span;
        try testing.expectEqual(@as(usize, c.ncap), ms.level);
        var k: usize = 0;
        while (k < ms.level) : (k += 1) {
            const is_pos = ms.captures[k].len == cap_position;
            try testing.expectEqual(c.kinds[k] == .position, is_pos);
        }
    }
}

test "doc 30: census anchored/specials flags" {
    try testing.expect(census("^%d+").?.anchored);
    try testing.expect(!census("%d+").?.anchored);
    try testing.expect(census("%d+").?.specials);
    try testing.expect(!census("abc").?.specials);
    try testing.expectEqual(@as(u8, 0), census("abc").?.ncap);
}

test "doc 30: census rejects what it cannot statically validate" {
    // Malformed / unpinnable shapes -> null (recorder aborts, stays tier-0).
    const rejects = [_][]const u8{
        "%", // trailing escape
        "(", // unfinished capture
        "(()", // nested unfinished
        ")", // close with nothing open
        "[abc", // unbalanced set
        "[^", // unbalanced complement set
        "%b", // %b missing both chars
        "%bx", // %b missing one char
        "%f", // %f missing class
        "%fx", // %f not followed by a set
        "(%a", // unfinished with content
    };
    for (rejects) |pat| {
        if (census(pat) != null) {
            std.debug.print("census accepted malformed [{s}]\n", .{pat});
            return error.TestUnexpectedResult;
        }
    }
    // And the matcher agrees these are errors (or unreachable-at-close):
    // firstMatch on a few of them must error, never succeed silently.
    try testing.expectError(error.MalformedPattern, firstMatch("abc", "%"));
    try testing.expectError(error.MalformedPattern, firstMatch("abc", "[abc"));
}

test "doc 30: census capture-count cap" {
    // 33 captures: one over max_captures -> null.
    var buf: [33 * 2]u8 = undefined;
    for (0..33) |i| {
        buf[2 * i] = '(';
        buf[2 * i + 1] = ')';
    }
    try testing.expect(census(buf[0 .. 32 * 2]) != null);
    try testing.expect(census(&buf) == null);
}
