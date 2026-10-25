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

test "float modulo is fmod with Lua's sign correction" {
    try expectProgram(
        \\print(5 % math.huge, -5 % math.huge, 3 % -math.huge, -3 % -math.huge)
        \\print(1e300 % 7, -5.5 % 2, 5.5 % -2, -5.5 % -2, -6.0 % 3)
        \\local s = 0.0
        \\for i = 1, 300 do s = s + (i * 1.5) % 7 + (-i * 0.5) % 4 end
        \\print(s)
    , "5\tinf\t-inf\t-3\n1\t0.5\t-0.5\t-1.5\t-0\n1502\n");
}

test "malformed patterns raise Lua's messages" {
    try expectProgram(
        \\for _, p in ipairs({ "[a", "%", "%b", "%fx", "(a)%2", "%0", string.rep("()", 33) }) do
        \\  print(select(2, pcall(string.find, "a", p)))
        \\end
    , "malformed pattern (missing ']')\nmalformed pattern (ends with '%')\n" ++
        "malformed pattern (missing arguments to '%b')\nmissing '[' after '%f' in pattern\n" ++
        "invalid capture index %2\ninvalid capture index %0\ntoo many captures\n");
}

test "gsub replacements and unclosed captures raise Lua's messages" {
    try expectProgram(
        \\print(select(2, pcall(string.match, "a", "(a")))
        \\for _, r in ipairs({ "%x", "%", "%2" }) do
        \\  print(select(2, pcall(string.gsub, "a", "(a)", r)))
        \\end
        \\print(string.gsub("abc", "(%w)", "%%%1%0"))
    , "unfinished capture\ninvalid use of '%' in replacement string\n" ++
        "invalid use of '%' in replacement string\ninvalid capture index %2\n%aa%bb%cc\t3\n");
}

test "the deprecated %z class matches the NUL byte" {
    try expectProgram(
        \\print(string.find("a\0b", "%z"))
        \\print(string.find("a\0b", "%Z+"))
        \\print(string.gsub("a\0b\0", "[%z]", "-"))
    , "2\t2\n1\t1\na-b-\t2\n");
}

test "select past the end selects nothing" {
    try expectProgram(
        \\print(select('#', select(5, 1, 2)), select(3, 1, 2), select(-2, 1, 2))
        \\print(pcall(select, -3, 1, 2))
    , "0\tnil\t1\t2\nfalse\tbad argument #1 to 'select' (index out of range)\n");
}

test "floor and ceil of a float past the integer range return the float" {
    try expectProgram(
        \\print(math.type(math.floor(2^63)), math.ceil(-1e100) == -1e100, math.floor(1/0))
        \\print(math.type(math.ceil(0/0)), math.floor(-2^63), math.ceil(2^62 + 0.0))
    , "float\ttrue\tinf\nfloat\t-9223372036854775808\t4611686018427387904\n");
}

test "math argument errors name the argument as Lua does" {
    try expectProgram(
        \\for _, f in ipairs({
        \\  function() return math.floor("x") end, function() return math.fmod(1, 0) end,
        \\  function() return math.ult(1.5, 2) end, function() return math.max() end,
        \\}) do print((select(2, pcall(f)):gsub("^[^:]*:%d+: ", ""))) end
    , "bad argument #1 to 'floor' (number expected, got string)\n" ++
        "bad argument #2 to 'fmod' (zero)\n" ++
        "bad argument #1 to 'ult' (number has no integer representation)\n" ++
        "bad argument #1 to 'max' (value expected)\n");
}

test "math.random checks its argument count and blames #1 for an empty interval" {
    try expectProgram(
        \\print(select(2, pcall(math.random, 1, 2, 3)))
        \\print(select(2, pcall(math.random, 2, 1)))
        \\print(math.ult(1.0, 2), select(2, pcall(math.sqrt)))
    , "wrong number of arguments\nbad argument #1 to 'random' (interval is empty)\n" ++
        "true\tbad argument #1 to 'sqrt' (number expected, got no value)\n");
}

test "a missing argument is 'value expected', as in Lua" {
    try expectProgram(
        \\for _, f in ipairs({ tostring, tonumber, getmetatable, type, assert, rawequal }) do
        \\  print((select(2, pcall(f)):gsub("^[^']*", "")))
        \\end
    , "'tostring' (value expected)\n'tonumber' (value expected)\n" ++
        "'getmetatable' (value expected)\n'type' (value expected)\n" ++
        "'assert' (value expected)\n'rawequal' (value expected)\n");
    try expectProgram(
        \\print(select(2, pcall(rawequal, 1)), select(2, pcall(rawget, {})))
    , "bad argument #2 to 'rawequal' (value expected)\t" ++
        "bad argument #2 to 'rawget' (value expected)\n");
}

test "rawset, rawlen and setmetatable check their arguments as Lua does" {
    try expectProgram(
        \\print(select(2, pcall(rawset, {}, 1)))
        \\print(select(2, pcall(rawset, {}, nil, 1)), select(2, pcall(rawset, {}, 0/0, 1)))
        \\print(select(2, pcall(rawlen, 5)))
        \\print(select(2, pcall(setmetatable, {})))
    , "bad argument #3 to 'rawset' (value expected)\ntable index is nil\ttable index is NaN\n" ++
        "bad argument #1 to 'rawlen' (table or string expected, got number)\n" ++
        "bad argument #2 to 'setmetatable' (nil or table expected, got no value)\n");
}

test "assert raises its message with the caller's position" {
    try expectProgram(
        \\print(pcall(function() assert(false, "boom") end))
        \\print(pcall(function() assert(nil) end))
        \\print(pcall(function() assert(false, 42) end))
    , "false\tanonymous:1: boom\nfalse\tanonymous:2: assertion failed!\nfalse\t42\n");
}

