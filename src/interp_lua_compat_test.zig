//! Lua 5.4 behaviours the 2026-10-25 divergence audit found mahina getting
//! wrong (TODO.md, "Lua 5.4 divergence audit: bugs"). Each expected output
//! is what `lua5.4` prints for the same program, except where an error
//! message's position prefix or wording is mahina's own.

const util = @import("interp_testutil.zig");
const expectProgram = util.expectProgram;

test "string positions at the integer limits do not overflow" {
    try expectProgram(
        \\print(("hello"):sub(math.mininteger, math.maxinteger))
        \\print(("hello"):sub(math.mininteger, -2), ("hello"):sub(-3, math.maxinteger))
        \\print(("hello"):find("l", math.mininteger), string.codepoint("hi", math.mininteger, 1))
    , "hello\nhell\tllo\n3\t104\n");
}

test "results and sizes past the limits raise Lua's errors instead of overflowing" {
    try expectProgram(
        \\local function fails(msg, f, ...)
        \\  local ok, e = pcall(f, ...)
        \\  print(ok, string.find(e, msg, 1, true) ~= nil)
        \\end
        \\fails("too many results to unpack", table.unpack, {}, math.mininteger, math.maxinteger)
        \\fails("too many results to unpack", table.unpack, {}, 1, 100000000)
        \\fails("destination wrap around", table.move, {}, 1, math.maxinteger, 2)
        \\fails("too many elements to move", table.move, {}, -1, math.maxinteger, 1)
        \\fails("resulting string too large", string.rep, "ab", math.maxinteger)
        \\fails("resulting string too large", string.rep, "ab", math.maxinteger, ",")
        \\print(select('#', table.unpack({}, 1, 60000)), #("ab"):rep(3, ","))
    , "false\ttrue\nfalse\ttrue\nfalse\ttrue\nfalse\ttrue\nfalse\ttrue\nfalse\ttrue\n60000\t8\n");
}

test "multiple assignment evaluates targets, then values, then stores right to left" {
    try expectProgram(
        \\local a, i = {}, 3
        \\i, a[i] = i + 1, 20
        \\print(a[3], a[4], i)
        \\local t, seen = {}, {}
        \\local function k(n) seen[#seen + 1] = n return n end
        \\t[k(1)], t[k(2)] = k(3), k(4)
        \\print(table.concat(seen, " "))
        \\local b = {}
        \\b[1], b[1] = "first", "second"
        \\local x, j = {}, 1
        \\x[j], j = "a", 2
        \\print(b[1], x[1], x[2], j)
        \\local g = {{}}
        \\g[k(1)][k(2)], g[1][3] = 5, 6
        \\local s = {3, 1}
        \\s[1], s[2] = s[2], s[1]
        \\print(g[1][2], g[1][3], s[1], s[2])
    , "20\tnil\t4\n1 2 3 4\nfirst\ta\tnil\t2\n5\t6\t1\t3\n");
}

test "an iterator that is done returns one nil" {
    try expectProgram(
        \\print(select('#', next({})), next({}))
        \\local f, s = ipairs({})
        \\print(select('#', f(s, 0)), f(s, 0))
        \\for k, v in pairs({1, x = 2}) do io.write(tostring(k), "=", v, " ") end
        \\print()
    , "1\tnil\n1\tnil\n1=1 x=2 \n");
}
