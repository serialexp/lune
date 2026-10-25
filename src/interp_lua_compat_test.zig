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

test "a store with a nil or NaN key says so, through __newindex chains and t[i][j]" {
    try expectProgram(
        \\local t = {{}}
        \\local k
        \\print(pcall(function() t[k] = 1 end))
        \\print(pcall(function() t[0/0] = 1 end))
        \\print(pcall(function() t[1][k] = 1 end))
    , "false\tmain:3: table index is nil\nfalse\tmain:4: table index is NaN\n" ++
        "false\tmain:5: table index is nil\n");
    try expectProgram(
        \\local t, k = {{}}, nil
        \\print(pcall(function() t[2][1] = 1 end))
        \\print(pcall(function() return t[2][1] end))
        \\print(pcall(function() setmetatable({}, {__newindex = {}})[k] = 1 end))
        \\print(pcall(function() setmetatable({}, {__newindex = function() end})[k] = 1 end))
        \\local g = {{1, 2}, {3, 4}}
        \\g[1][1] = 7
        \\print(pcall(function() return g[5][1] end))
    , "false\tmain:2: attempt to index a nil value\nfalse\tmain:3: attempt to index a nil value\n" ++
        "false\tmain:4: table index is nil\ntrue\nfalse\tmain:8: attempt to index a nil value\n");
}

test "an __index or __newindex that is not a function is indexed in turn" {
    try expectProgram(
        \\print(setmetatable({}, {__index = "abc"}).len == string.len)
        \\print(pcall(function() return setmetatable({}, {__index = true}).x end))
        \\print(pcall(function() setmetatable({}, {__newindex = 5}).x = 1 end))
        \\local seen
        \\local inner = setmetatable({}, {__newindex = function(_, k, v) seen = k .. v end})
        \\setmetatable({}, {__newindex = inner}).x = 1
        \\print(seen, rawget(inner, "x"))
    , "true\nfalse\tmain:2: attempt to index a boolean value\n" ++
        "false\tmain:3: attempt to index a number value\nx1\tnil\n");
}

test "table.insert, remove, concat and gsub raise Lua's messages" {
    try expectProgram(
        \\print(pcall(function() table.insert({1}, 5, 2) end))
        \\print(pcall(function() table.insert({1}, 1, 2, 3) end))
        \\print(pcall(function() table.remove({1, 2}, 7) end))
        \\print(pcall(function() return table.concat({1, {}, 3}) end))
    , "false\tmain:1: bad argument #2 to 'insert' (position out of bounds)\n" ++
        "false\tmain:2: wrong number of arguments to 'insert'\n" ++
        "false\tmain:3: bad argument #2 to 'remove' (position out of bounds)\n" ++
        "false\tmain:4: invalid value (table) at index 2 in table for 'concat'\n");
    try expectProgram(
        \\print(pcall(function() return table.concat({1, 2}, {}) end))
        \\print(pcall(function() return table.concat({1, 2}, ",", 1, 3) end))
        \\print(pcall(function() return ("abc"):gsub("b", {b = {}}) end))
        \\print(pcall(function() return ("abc"):gsub("b", function() return true end) end))
    , "false\tmain:1: bad argument #2 to 'concat' (string expected, got table)\n" ++
        "false\tmain:2: invalid value (nil) at index 3 in table for 'concat'\n" ++
        "false\tmain:3: invalid replacement value (a table)\n" ++
        "false\tmain:4: invalid replacement value (a boolean)\n");
}

test "print, warn, table.insert and table.sort return nothing" {
    try expectProgram(
        \\print(select("#", print()), select("#", warn("@off")))
        \\print(select("#", table.insert({}, 1)), select("#", table.sort({2, 1})))
        \\print(select("#", pcall(print)), select("#", pcall(table.insert, {}, 1)))
        \\local function f() return table.insert({}, 1, 2) end
        \\local a, b = f()
        \\print(select("#", f()), a, b)
    , "\n0\t0\n0\t0\n\n1\t1\n0\tnil\tnil\n");
}

test "assert raises its message with the caller's position" {
    try expectProgram(
        \\print(pcall(function() assert(false, "boom") end))
        \\print(pcall(function() assert(nil) end))
        \\print(pcall(function() assert(false, 42) end))
    , "false\tmain:1: boom\nfalse\tmain:2: assertion failed!\nfalse\t42\n");
}


test "require returns the loader data and treats a false cache entry as unloaded" {
    try expectProgram(
        \\package.preload.m = function(n, d) return {n = n, d = d} end
        \\local a, b = require("m")
        \\print(a.n, a.d, b, select("#", require("m")))
        \\package.loaded.x = false
        \\package.preload.x = function() return 7 end
        \\print(require("x"))
        \\package.preload.y = function() end
        \\print(require("y"), package.loaded.y)
    , "m\t:preload:\t:preload:\t1\n7\t:preload:\ntrue\ttrue\n");
}

test "__tostring may return a number but not a table" {
    try expectProgram(
        \\print(tostring(setmetatable({}, {__tostring = function() return 42 end})))
        \\print(pcall(tostring, setmetatable({}, {__tostring = function() return {} end})))
    , "42\nfalse\t'__tostring' must return a string\n");
}

test "string.format checks its specs as Lua does" {
    try expectProgram(
        \\local function e(...) print(select(2, pcall(string.format, ...))) end
        \\e("%d", 3.5)
        \\e("%100d", 1)
        \\e("%#d", 1)
        \\e("%05s", "a")
    , "bad argument #2 to 'format' (number has no integer representation)\n" ++
        "invalid conversion specification: '%100d'\n" ++
        "invalid conversion specification: '%#d'\n" ++
        "invalid conversion specification: '%05s'\n");
    try expectProgram(
        \\local function e(...) print(select(2, pcall(string.format, ...))) end
        \\e("%F", 1)
        \\e("abc%")
        \\e("%5q", "x")
    , "invalid conversion '%F' to 'format'\n" ++
        "bad argument #2 to 'format' (no value)\n" ++
        "specifier '%q' cannot have modifiers\n");
}

test "string.format: %a, the # flag, and %s through __tostring" {
    try expectProgram(
        \\print(string.format("%a %A %.0a %.3a %a", 1.5, 0.1, 1.5, 1, 2^-1074))
        \\print(string.format("%#.0f %#.0e %#.0g %d", 3, 3, 3, 3.0))
        \\local t = setmetatable({}, {__tostring = function() return "TS" end})
        \\print(string.format("[%s][%4s][%-4s]", t, t, t))
        \\print(select(2, pcall(string.format, "%5s", "a\0b")))
    , "0x1.8p+0 0X1.999999999999AP-4 0x2p+0 0x1.000p+0 0x0.0000000000001p-1022\n" ++
        "3. 3.e+00 3. 3\n[TS][  TS][TS  ]\n" ++
        "bad argument #2 to 'format' (string contains zeros)\n");
}

test "string.format %q writes literals that read back exactly" {
    try expectProgram(
        \\print(string.format("%q %q %q", "\0" .. "1", "a\r\t", 1.5))
        \\print(string.format("%q %q %q %q", 1/0, -1/0, 0/0, math.mininteger))
        \\print(select(2, pcall(string.format, "%q", {})))
        \\local v = 1/3
        \\print(load(string.format("return %q", v))() == v)
    , "\"\\0001\" \"a\\13\\9\" 0x1.8p+0\n1e9999 -1e9999 (0/0) 0x8000000000000000\n" ++
        "bad argument #2 to 'format' (value has no literal form)\ntrue\n");
}

test "tonumber reads Lua's numerals" {
    try expectProgram(
        \\print(tonumber("1_000"), tonumber("0b101"), tonumber("0o17"), tonumber("inf"), tonumber("nan"))
        \\print(tonumber("0xffffffffffffffff"), tonumber(" 0x1p4 "), tonumber("0x.8"), tonumber("1e"))
        \\print(tonumber("ffffffffffffffff", 16), tonumber("z", 36), tonumber("2", 2), tonumber("10", nil))
        \\print(select(2, pcall(tonumber, 10, 16)))
        \\print(select(2, pcall(tonumber, "10", 37)))
        \\print(select(2, pcall(tonumber, "10", 2.5)))
    , "nil\tnil\tnil\tnil\tnil\n-1\t16\t0.5\tnil\n-1\t35\tnil\t10\n" ++
        "bad argument #1 to 'tonumber' (string expected, got number)\n" ++
        "bad argument #2 to 'tonumber' (base out of range)\n" ++
        "bad argument #2 to 'tonumber' (number has no integer representation)\n");
}

test "numeric literals: hex floats, wrapping hex, malformed numerals" {
    try expectProgram(
        \\print(0x1.8p+1, 0x.8, 0xA.8P0, 0x1p-3, 0xffffffffffffffff, 9223372036854775808)
        \\print(load("return 3x"))
        \\print(load("return 0x"))
        \\print(load("return 1e+"))
    , "3\t0.5\t10.5\t0.125\t-1\t9223372036854776000\n" ++
        "nil\t(load):1: malformed number\n" ++
        "nil\t(load):1: malformed number\n" ++
        "nil\t(load):1: malformed number\n");
}

test "method calls number arguments from the one after self" {
    try expectProgram(
        \\local function e(f) print((select(2, pcall(f)):gsub("^[^:]*:%d+: ", ""))) end
        \\e(function() return ("a"):rep(2.5) end)
        \\e(function() return string.rep("a", 2.5) end)
        \\e(function() local t = setmetatable({}, {__index = string}) return t:upper() end)
        \\print(select(2, pcall(string.rep)))
    , "bad argument #1 to 'rep' (number has no integer representation)\n" ++
        "bad argument #2 to 'rep' (number has no integer representation)\n" ++
        "calling 'upper' on bad self (string expected, got table)\n" ++
        "bad argument #1 to 'rep' (string expected, got no value)\n");
}
