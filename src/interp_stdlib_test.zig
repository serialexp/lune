//! Tests for `interp.zig` — stdlib.
//!
//! Extracted verbatim from `interp.zig`; bodies are unchanged.
//! Shared harness lives in `interp_testutil.zig`.

const interp = @import("interp.zig");
const std = @import("std");
const bytecode = @import("bytecode.zig");
const arith = @import("arith.zig");
const value = @import("value.zig");
const regwindow = @import("regwindow.zig");
const gc = @import("gc.zig");
const object = @import("object.zig");
const string = @import("string.zig");
const table = @import("table.zig");
const array = @import("array.zig");
const function = @import("function.zig");
const trace = @import("trace.zig");
const irinterp = @import("irinterp.zig");
const execlog = @import("execlog.zig");
const compiler = @import("compiler.zig");
const io = @import("io.zig");
const stdmath = @import("stdlib/math.zig");
const stdtable = @import("stdlib/table.zig");
const stdbase = @import("stdlib/base.zig");
const stdbasic = @import("stdlib/basic.zig");
const stdstring = @import("stdlib/string.zig");
const stderrors = @import("stdlib/errors.zig");
const stddebug = @import("stdlib/debug.zig");
const stdload = @import("stdlib/load.zig");
const stdpackage = @import("stdlib/package.zig");
const unicode_case = @import("gen/unicode_case.zig");
const Value = value.Value;
const Proto = bytecode.Proto;
const Instr = bytecode.Instr;
const Closure = function.Closure;
const RegWindow = regwindow.RegWindow;
const testing = std.testing;

const util = @import("interp_testutil.zig");
const runOut = util.runOut;
const expectProgram = util.expectProgram;

// ---------------------------------------------------------------------------
// Minimal host stdlib — tonumber / string.format / io.write / arg.
// Driven through the full front end so the module-table dispatch
// (get_global → get_index → call) and the lint-known globals are exercised.
// ---------------------------------------------------------------------------

test "stdlib: tonumber parses ints, floats, hex, explicit base; passes numbers; nil otherwise" {
    var buf: [128]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    try runOut(
        \\print(tonumber("42"))
        \\print(tonumber("  3.5 "))
        \\print(tonumber("0x1F"))
        \\print(tonumber("777", 8))
        \\print(tonumber(123))
        \\print(tonumber("abc"))
        \\print(tonumber(nil))
    , &sink);
    try testing.expectEqualStrings("42\n3.5\n31\n511\n123\nnil\nnil\n", sink.buffered());
}

test "stdlib: string.format covers d/width/justify/zero, float, hex, string precision, q, %%" {
    var buf: [256]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    try runOut(
        \\print(string.format("%d", 42))
        \\print(string.format("[%8d]", 40000))
        \\print(string.format("[%-8d]", 42))
        \\print(string.format("[%08d]", 42))
        \\print(string.format("%d", 3.0))
        \\print(string.format("[%5.2f]", 3.14159))
        \\print(string.format("%x/%X", 255, 255))
        \\print(string.format("[%.3s]", "hello"))
        \\print(string.format("%q", "a\"b"))
        \\print(string.format("100%%"))
    , &sink);
    try testing.expectEqualStrings(
        "42\n" ++
            "[   40000]\n" ++
            "[42      ]\n" ++
            "[00000042]\n" ++
            "3\n" ++
            "[ 3.14]\n" ++
            "ff/FF\n" ++
            "[hel]\n" ++
            "\"a\\\"b\"\n" ++
            "100%\n",
        sink.buffered(),
    );
}

test "stdlib: io.write emits args with no separators and no trailing newline" {
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    try runOut(
        \\io.write("a", 1, "b")
        \\io.write("!")
    , &sink);
    try testing.expectEqualStrings("a1b!", sink.buffered());
}

test "stdlib: the exact nsieve format line matches LuaJIT byte-for-byte" {
    var buf: [64]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    try runOut(
        \\io.write(string.format("Primes up to %8d %8d\n", 40000, 4203))
    , &sink);
    try testing.expectEqualStrings("Primes up to    40000     4203\n", sink.buffered());
}

test "stdlib: arg is an empty table by default (no host args)" {
    var buf: [32]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    try runOut(
        \\print(arg[1])
        \\print(tonumber(arg and arg[1]) or 7)
    , &sink);
    // `arg` exists (a table) so `arg and arg[1]` is nil → tonumber(nil) → nil → 7.
    try testing.expectEqualStrings("nil\n7\n", sink.buffered());
}

test "stdlib: nsieve runs end-to-end and matches LuaJIT (correctness milestone)" {
    // Full program from `~/Projects/LuaJIT/bench/nsieve.lua`. No host args, so
    // `N` defaults to 1 → clamped to 2 → primes up to 40000/20000/10000.
    const nsieve =
        \\local function nsieve(p, m)
        \\  for i=2,m do p[i] = true end
        \\  local count = 0
        \\  for i=2,m do
        \\    if p[i] then
        \\      for k=i+i,m,i do p[k] = false end
        \\      count = count + 1
        \\    end
        \\  end
        \\  return count
        \\end
        \\
        \\local N = tonumber(arg and arg[1]) or 1
        \\if N < 2 then N = 2 end
        \\local primes = {}
        \\
        \\for i=0,2 do
        \\  local m = (2^(N-i))*10000
        \\  io.write(string.format("Primes up to %8d %8d\n", m, nsieve(primes, m)))
        \\end
    ;
    var buf: [256]u8 = undefined;
    var sink = io.Writer.fixed(&buf);
    try runOut(nsieve, &sink);
    try testing.expectEqualStrings(
        "Primes up to    40000     4203\n" ++
            "Primes up to    20000     2262\n" ++
            "Primes up to    10000     1229\n",
        sink.buffered(),
    );
}
test "stdlib: table.sort's default comparator takes __lt, the left operand's first" {
    // Each handler names its owner, so the log shows whose `__lt` ran: in
    // `{{}, b}` the left operand has none, so `b`'s is taken, as `<` takes it.
    try expectProgram(
        \\local log = {}
        \\local mt = {__lt = function(x, y) return x.v < y.v end}
        \\local function obj(v) return setmetatable({v = v}, mt) end
        \\local t = {obj(3), obj(1), obj(2)}
        \\table.sort(t)
        \\print(t[1].v, t[2].v, t[3].v)
        \\local b = {}
        \\setmetatable(b, {__lt = function(x, y) log[#log + 1] = (y == b) and "b" or "?"; return false end})
        \\local u = {{}, b}
        \\table.sort(u)
        \\print(log[1], #log)
        \\
    ,
        "1\t2\t3\nb\t1\n",
    );
}

test "stdlib: table.sort calls its comparator from its activation (doc 68 §5.1)" {
    // In two halves, for the output buffer. A comparator, `__lt`, a sort
    // inside a comparator, a callable table, and nothing returned.
    try expectProgram(
        \\local t = {5, 2, 8, 1, 9, 3, 7}
        \\table.sort(t, function(a, b) return a > b end)
        \\print(table.concat(t, " "))
        \\local V = {__lt = function(a, b) return a.k < b.k end}
        \\local u = {}
        \\for i = 1, 6 do u[i] = setmetatable({ k = (i * 5) % 7 }, V) end
        \\table.sort(u)
        \\local ks = {}
        \\for i = 1, #u do ks[i] = u[i].k end
        \\print(table.concat(ks, " "))
        \\local mixed = {3, 1.5, 2, -1}
        \\table.sort(mixed)
        \\print(table.concat(mixed, " "))
        \\local calls = 0
        \\local w = {4, 3, 2, 1}
        \\table.sort(w, function(a, b)
        \\  calls = calls + 1
        \\  local inner = {b, a}
        \\  table.sort(inner, function(x, y) return x < y end)
        \\  return inner[1] == a and a ~= b
        \\end)
        \\print(table.concat(w, " "), calls)
        \\local cmp = setmetatable({}, {__call = function(self, x, y) return x < y end})
        \\local g = {3, 1, 2}
        \\table.sort(g, cmp)
        \\print(table.concat(g, " "))
        \\print(select("#", table.sort({2, 1}, function(a, b) return a < b end)))
        \\print(pcall(table.sort, {3, 1, 2}, function(a, b) return a < b end))
        \\
    ,
        "9 8 7 5 3 2 1\n1 2 3 4 5 6\n-1 1.5 2 3\n1 2 3 4\t6\n1 2 3\n0\ntrue\n",
    );
}

test "stdlib: table.sort's errors are located as a C function's (doc 68 §5.1)" {
    // `sort` is a level of its own with no location, as in Lua: `error(m,
    // 2)` in the comparator is unlocated. A frozen table is located at the
    // `sort` call; a native comparator's bad argument names it, unlocated;
    // a comparator that is not callable is `sort`'s bad argument.
    try expectProgram(
        \\local e = {3, 1, 2}
        \\print(pcall(function() table.sort(e, function(a, b) error("cmp", 2) end) end))
        \\print(pcall(function() table.sort(e, function(a, b) error("cmp", 3) end) end))
        \\local f = {5, 4, 3, 2, 1}
        \\print(pcall(function()
        \\  table.sort(f, function(a, b) if not table.isfrozen(f) then table.freeze(f) end return a < b end)
        \\end))
        \\print(table.concat(f, " "))
        \\print(pcall(function() table.sort({3, 2, 1}, string.rep) end))
        \\print(pcall(function() table.sort({3, 2, 1}, 7) end))
        \\
    ,
        "false\tcmp\nfalse\tmain:3: cmp\nfalse\tmain:6: attempt to modify a readonly table\n5 4 3 2 1\n" ++
            "false\tbad argument #1 to 'string.rep' (string expected, got number)\n" ++
            "false\tmain:10: bad argument #2 to 'sort' (function expected, got number)\n",
    );
}

test "stdlib: a traceback through table.sort shows it as a C function" {
    // The handler's frame, the comparator's, `sort`'s, the protected one's.
    try expectProgram(
        \\local tb
        \\xpcall(function()
        \\  table.sort({2, 1}, function(a, b) error("z") end)
        \\end, function(m) tb = debug.traceback(m) end)
        \\print(tb)
        \\
    ,
        "main:3: z\nstack traceback:\n\tmain:4: in function 'anonymous'\n\tmain:3: in function 'anonymous'\n" ++
            "\t[C]: in function 'table.sort'\n\tmain:3: in function 'anonymous'\n\tmain:4: in main chunk\n",
    );
}

test "stdlib: gsub calls a function replacement from its activation (doc 68 §7.4)" {
    // Under GC stress in every tier: captures, a kept original (`nil`/`false`),
    // a number result, a gsub inside the replacement, an empty match, an anchor,
    // the limit, a callable that is a native, and the activation returning
    // both results.
    try expectProgram(
        \\print(string.gsub("hello world", "(o)(%s?)", function(a, b) return "<" .. a .. b .. ">" end))
        \\print(string.gsub("abc", "%w", function(c) if c == "b" then return nil end return 7 end))
        \\print(string.gsub("a b", "%a", function(c) return (string.gsub(c, ".", function(x) return x .. x end)) end))
        \\print(string.gsub("ab", "", function() return "-" end))
        \\print(string.gsub("aaa", "^a", function(c) return "X" end))
        \\print(string.gsub("aaaa", "a", function(c) return "b" end, 2))
        \\print(string.gsub("a,b", ",", tostring))
        \\print(select("#", string.gsub("x", "x", function() end)))
        \\print(pcall(string.gsub, "a b", "%a", function(c) return c .. c end))
        \\
    ,
        "hell<o >w<o>rld\t2\n" ++
            "7b7\t3\n" ++
            "aa bb\t2\n" ++
            "-a-b-\t3\n" ++
            "Xaa\t1\n" ++
            "bbaa\t2\n" ++
            "a,b\t1\n" ++
            "2\n" ++
            "true\taa bb\t2\n",
    );
}

test "stdlib: gsub's errors are located as a C function's (doc 68 §7.4)" {
    // A bad replacement value is the caller's line; `error(m, 2)` in the
    // replacement points at `gsub`, a C function, so it has no location; a
    // malformed `%` in a string replacement never reaches the activation; a
    // pattern error mid-way (the callback ran for the first match) is the
    // caller's too.
    try expectProgram(
        \\print(pcall(function() return string.gsub("abc", "b", function() return {} end) end))
        \\print(pcall(function() return string.gsub("abc", "b", function() error("rep", 2) end) end))
        \\print(pcall(function() return string.gsub("abc", "b", function() error("rep", 1) end) end))
        \\print(pcall(function() return string.gsub("ab", "(%a)", function(c) return c end, "x") end))
        \\print(pcall(function() return string.gsub("abc", "%a", function(c) return "%" .. c end) end))
        \\
    ,
        "false\tmain:1: invalid replacement value (a table)\n" ++
            "false\trep\n" ++
            "false\tmain:3: rep\n" ++
            "false\tmain:4: bad argument #4 to 'gsub' (number expected, got string)\n" ++
            "true\t%a%b%c\t3\n",
    );
}

test "stdlib: a traceback through gsub shows it as a C function" {
    try expectProgram(
        \\local tb
        \\xpcall(function()
        \\  string.gsub("a", "a", function(c) error("z") end)
        \\end, function(m) tb = debug.traceback(m) end)
        \\print(tb)
        \\
    ,
        "main:3: z\nstack traceback:\n\tmain:4: in function 'anonymous'\n\tmain:3: in function 'anonymous'\n" ++
            "\t[C]: in function 'string.gsub'\n\tmain:3: in function 'anonymous'\n\tmain:4: in main chunk\n",
    );
}

test "stdlib: table.sort without a comparator or __lt raises Lua's compare error" {
    // Unlocated, as Lua's: the comparison fails inside `sort`, a C function there.
    try expectProgram(
        \\print(pcall(table.sort, {{}, {}}))
        \\print(pcall(table.sort, {1, "a"}))
        \\print(pcall(function() table.sort({{}, {}}) end))
        \\
    ,
        "false\tattempt to compare two table values\n" ++
            "false\tattempt to compare number with string\n" ++
            "false\tattempt to compare two table values\n",
    );
}
