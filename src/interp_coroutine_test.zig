//! Tests for doc 73's coroutines: the `coroutine` library over the VM's
//! stack switch. Every program runs on the full GC × trace-mode matrix
//! (`expectProgram`), so each also checks the collector walks suspended
//! stacks and that traces stay transparent around a switch.

const std = @import("std");
const util = @import("interp_testutil.zig");
const expectProgram = util.expectProgram;

test "coroutine: values pass both ways through resume and yield" {
    try expectProgram(
        \\local co = coroutine.create(function(a, b)
        \\  local c = coroutine.yield(a + b)
        \\  local d, e = coroutine.yield(c * 2)
        \\  return d .. e, 99
        \\end)
        \\print(coroutine.status(co))
        \\print(coroutine.resume(co, 1, 2))
        \\print(coroutine.resume(co, 10))
        \\print(coroutine.resume(co, "x", "y"))
        \\print(coroutine.status(co))
        \\print(coroutine.resume(co))
    , "suspended\ntrue\t3\ntrue\t20\ntrue\txy\t99\ndead\nfalse\tcannot resume dead coroutine\n");
}

test "coroutine: a generator's hot loop yields every iteration" {
    try expectProgram(
        \\local function gen(n)
        \\  return coroutine.create(function()
        \\    for i = 1, n do coroutine.yield(i) end
        \\    return nil
        \\  end)
        \\end
        \\local total = 0
        \\for round = 1, 3 do
        \\  local g = gen(200)
        \\  while true do
        \\    local _, v = coroutine.resume(g)
        \\    if v == nil then break end
        \\    total = total + v
        \\  end
        \\end
        \\print(total)
    , "60300\n");
}

test "coroutine: an error kills it and its resume returns false and the error" {
    try expectProgram(
        \\local a = coroutine.create(function() error("boom") end)
        \\print(coroutine.resume(a))
        \\print(coroutine.status(a))
        \\local b = coroutine.create(function() error({code = 7}) end)
        \\local ok, e = coroutine.resume(b)
        \\print(ok, e.code)
        \\local c = coroutine.create(function() local t = nil; return t + 1 end)
        \\print((coroutine.resume(c)))
        \\print(coroutine.close(a))
    , "false\tmain:1: boom\ndead\nfalse\t7\nfalse\nfalse\tmain:1: boom\n");
}

test "coroutine: pcall inside a coroutine catches there, across yields" {
    try expectProgram(
        \\local co = coroutine.create(function()
        \\  local ok, err = pcall(function()
        \\    coroutine.yield("in pcall")
        \\    error("inner", 0)
        \\  end)
        \\  coroutine.yield(ok, err)
        \\  return "fine"
        \\end)
        \\print(coroutine.resume(co))
        \\print(coroutine.resume(co))
        \\print(coroutine.resume(co))
    , "true\tin pcall\ntrue\tfalse\tinner\ntrue\tfine\n");
}

test "coroutine: coroutines resume coroutines" {
    try expectProgram(
        \\local outer = coroutine.create(function()
        \\  local inner = coroutine.create(function()
        \\    coroutine.yield("i1")
        \\    return "i-done"
        \\  end)
        \\  print("o", coroutine.resume(inner))
        \\  print(coroutine.status(inner), coroutine.status(coroutine.running()))
        \\  coroutine.yield("o1")
        \\  print("o", coroutine.resume(inner))
        \\  return "o-done"
        \\end)
        \\print(coroutine.resume(outer))
        \\print(coroutine.resume(outer))
    , "o\ttrue\ti1\nsuspended\trunning\ntrue\to1\no\ttrue\ti-done\ntrue\to-done\n");
}

test "coroutine: resume called from Zig runs it to its next stop" {
    try expectProgram(
        \\local co = coroutine.create(function(x)
        \\  local y = coroutine.yield(x + 1)
        \\  local inner = coroutine.create(function() coroutine.yield("deep") end)
        \\  print(coroutine.resume(inner))
        \\  return y * 3
        \\end)
        \\print(pcall(coroutine.resume, co, 4))
        \\print(pcall(coroutine.resume, co, 5))
        \\print(pcall(coroutine.resume, co))
        \\local bad = coroutine.create(function() error("zig side", 0) end)
        \\print(pcall(coroutine.resume, bad))
    , "true\ttrue\t5\ntrue\tdeep\ntrue\ttrue\t15\ntrue\tfalse\tcannot resume dead coroutine\ntrue\tfalse\tzig side\n");
}

test "coroutine: a closure over a suspended coroutine's local shares it" {
    try expectProgram(
        \\local counter
        \\local co = coroutine.create(function()
        \\  local n = 0
        \\  counter = function() n = n + 1; return n end
        \\  coroutine.yield()
        \\  n = n + 10
        \\  return n
        \\end)
        \\coroutine.resume(co)
        \\print(counter(), counter())
        \\print(coroutine.resume(co))
        \\print(counter())
    , "1\t2\ntrue\t12\n13\n");
}

test "coroutine: every value of a multret resume and yield gets across" {
    try expectProgram(
        \\local co = coroutine.create(function(...)
        \\  local t = {coroutine.yield(...)}
        \\  return #t, table.unpack(t)
        \\end)
        \\print(coroutine.resume(co, 1, 2, 3))
        \\print(coroutine.resume(co, "a", "b"))
        \\local function three() return 7, 8, 9 end
        \\local co2 = coroutine.create(function() return coroutine.yield(three()) end)
        \\print(coroutine.resume(co2))
        \\print(coroutine.resume(co2, three()))
    , "true\t1\t2\t3\ntrue\t2\ta\tb\ntrue\t7\t8\t9\ntrue\t7\t8\t9\n");
}

test "coroutine: close, status and the main thread" {
    try expectProgram(
        \\local co = coroutine.create(function() coroutine.yield() end)
        \\coroutine.resume(co)
        \\print(coroutine.close(co), coroutine.status(co))
        \\local m, ismain = coroutine.running()
        \\print(type(m), ismain, coroutine.status(m), coroutine.isyieldable())
        \\local c = coroutine.create(function()
        \\  local me, im = coroutine.running()
        \\  print(im, coroutine.status(me), coroutine.isyieldable(), coroutine.status(m))
        \\  print(coroutine.resume(me))
        \\  print(pcall(coroutine.close, me))
        \\end)
        \\coroutine.resume(c)
        \\print(coroutine.resume(m))
    , "true\tdead\nthread\ttrue\trunning\tfalse\nfalse\trunning\ttrue\tnormal\nfalse\tcannot resume non-suspended coroutine\nfalse\tcannot close a running coroutine\nfalse\tcannot resume non-suspended coroutine\n");
}

test "coroutine: yield only where it can" {
    try expectProgram(
        \\print(pcall(coroutine.yield, 1))
        \\local co = coroutine.create(function()
        \\  table.sort({3, 2, 1}, function(a, b) coroutine.yield() return a < b end)
        \\end)
        \\print(coroutine.resume(co))
        \\local co2 = coroutine.create(function() return pcall(coroutine.yield, 1) end)
        \\print(coroutine.resume(co2))
    , "false\tattempt to yield from outside a coroutine\nfalse\tattempt to yield across a C-call boundary\ntrue\tfalse\tattempt to yield across a C-call boundary\n");
}

test "coroutine: a coroutine resumed inside a Zig callback yields to it" {
    try expectProgram(
        \\local co = coroutine.create(function()
        \\  for i = 1, 100 do coroutine.yield(i) end
        \\end)
        \\local t = {5, 3, 8, 1}
        \\local calls = 0
        \\table.sort(t, function(a, b)
        \\  local _, v = coroutine.resume(co)
        \\  calls = calls + v
        \\  return a < b
        \\end)
        \\print(t[1], t[4], calls > 0)
        \\local bad = coroutine.create(function() error("cb", 0) end)
        \\print(table.concat({string.gsub("ab", "%w", function(c)
        \\  return tostring((coroutine.resume(bad)))
        \\end)}, ","))
    , "1\t8\ttrue\nfalsefalse,2\n");
}

test "coroutine: a deep recursion overflows its own stack only" {
    try expectProgram(
        \\local function down(n) return down(n + 1) + 1 end
        \\local co = coroutine.create(function() return down(1) end)
        \\local ok, err = coroutine.resume(co)
        \\print(ok, coroutine.status(co))
        \\print(select(2, pcall(down, 1)) ~= nil)
    , "false\tdead\ntrue\n");
}

test "coroutine: abandoned coroutines are collected, a captured one is kept" {
    try expectProgram(
        \\local keep
        \\for i = 1, 300 do
        \\  local co = coroutine.create(function(x)
        \\    local local_x = x
        \\    if i == 150 then keep = function() return local_x end end
        \\    coroutine.yield()
        \\  end)
        \\  coroutine.resume(co, i)
        \\end
        \\for k = 1, 20000 do local junk = {} end
        \\print(keep())
    , "150\n");
}

test "coroutine: dropped suspended coroutines bring the collection forward by their stacks" {
    // 5000 live tables set the collection target near 10k objects. Each
    // dropped coroutine is three objects, so by count alone all 2000 would
    // stay uncollected with their stacks; charged its stack's weight
    // (`Stack.gc_units`) each brings the next collection forward, so only
    // the ones since the last collection are held at the end.
    const gpa = std.testing.allocator;
    var vm = try @import("interp.zig").Vm.init(gpa);
    defer vm.deinit();
    try util.compileRun(gpa, &vm,
        \\live = {}
        \\for i = 1, 5000 do live[i] = {} end
        \\for i = 1, 2000 do
        \\  local co = coroutine.create(function(x) coroutine.yield(x) end)
        \\  coroutine.resume(co, i)
        \\end
    );
    const units = @import("coroutine.zig").Stack.gc_units;
    try std.testing.expect(units > 1);
    try std.testing.expect(vm.heap.thread_count < 2000 / 4);
    try std.testing.expectEqual(vm.heap.thread_count * units, vm.heap.stack_debt);
}

test "coroutine: a native body runs as the coroutine, as in Lua" {
    // Outputs checked against Lua 5.4: errors raised in the body carry no
    // location at any level, a bad argument names the native by its
    // qualified name, and `yield`, `pcall` and `resume` bodies switch.
    try expectProgram(
        \\print(coroutine.resume(coroutine.create(print), 1, 2))
        \\print(coroutine.resume(coroutine.create(string.rep)))
        \\print(coroutine.resume(coroutine.create(error), "x"))
        \\print(coroutine.resume(coroutine.create(error), "x", 1))
        \\print(coroutine.resume(coroutine.create(error), "x", 2))
        \\local ok, e = coroutine.resume(coroutine.create(error), {k = 1})
        \\print(ok, e.k)
        \\local co = coroutine.create(coroutine.yield)
        \\print(coroutine.resume(co, 1, 2))
        \\print(coroutine.status(co))
        \\print(coroutine.resume(co, 3, 4))
        \\print(coroutine.status(co))
        \\local p = coroutine.create(pcall)
        \\print(coroutine.resume(p, function(a) local b = coroutine.yield(a + 1) return b * 2 end, 10))
        \\print(coroutine.resume(p, 21))
        \\print(coroutine.status(p))
    , "1\t2\ntrue\n" ++
        "false\tbad argument #1 to 'string.rep' (string expected, got no value)\n" ++
        "false\tx\nfalse\tx\nfalse\tx\nfalse\t1\n" ++
        "true\t1\t2\nsuspended\ntrue\t3\t4\ndead\n" ++
        "true\t11\ntrue\ttrue\t42\ndead\n");
    try expectProgram(
        \\local q = coroutine.create(pcall)
        \\print(coroutine.resume(q, error, "boom"))
        \\print(coroutine.resume(coroutine.create(select), "#", 1, 2, 3))
        \\local s = coroutine.create(coroutine.running)
        \\print(select("#", coroutine.resume(s)), coroutine.resume(s))
        \\print(coroutine.resume(coroutine.create(coroutine.isyieldable)))
        \\local u = coroutine.create(coroutine.status)
        \\print(coroutine.resume(u, u))
        \\print(coroutine.close(coroutine.create(print)))
        \\local c2 = coroutine.create(coroutine.yield)
        \\coroutine.resume(c2, 1)
        \\print(coroutine.close(c2), coroutine.status(c2))
        \\local function f() return coroutine.resume(coroutine.create(string.rep), "ab", 3) end
        \\print(f())
        \\print(coroutine.resume(coroutine.create(table.unpack), {1, 2, 3}))
        \\local cc = coroutine.create(coroutine.resume)
        \\local inner = coroutine.create(function(x) coroutine.yield(x * 2) return "fin" end)
        \\print(coroutine.resume(cc, inner, 4))
        \\print(coroutine.status(cc), coroutine.status(inner))
    , "true\tfalse\tboom\ntrue\t3\n" ++
        "3\tfalse\tcannot resume dead coroutine\n" ++
        "true\ttrue\ntrue\trunning\ntrue\ntrue\tdead\n" ++
        "true\tababab\ntrue\t1\t2\t3\n" ++
        "true\ttrue\t8\ndead\tsuspended\n");
}

test "coroutine: a non-coroutine argument is a bad argument naming the library function" {
    // As Lua 5.4.6 prints them.
    try expectProgram(
        \\print(pcall(coroutine.resume, 1))
        \\print(pcall(coroutine.status, {}))
    , "false\tbad argument #1 to 'coroutine.resume' (thread expected, got number)\n" ++
        "false\tbad argument #1 to 'coroutine.status' (thread expected, got table)\n");
    try expectProgram(
        \\print(pcall(coroutine.close))
        \\print(pcall(function() return coroutine.status(true) end))
    , "false\tbad argument #1 to 'coroutine.close' (thread expected, got no value)\n" ++
        "false\tmain:2: bad argument #1 to 'status' (thread expected, got boolean)\n");
}


test "coroutine.wrap: a generator yields and returns its values, as in Lua" {
    // Outputs checked against Lua 5.4.6.
    try expectProgram(
        \\local gen = coroutine.wrap(function(a, b)
        \\  local c = coroutine.yield(a + b)
        \\  local d, e = coroutine.yield(c * 2)
        \\  return d .. e, "end"
        \\end)
        \\print(type(gen), gen(1, 2), gen(10))
        \\print(gen("x", "y"))
        \\print(pcall(gen))
        \\for v in coroutine.wrap(function() for i = 1, 3 do coroutine.yield(i) end end) do io.write(v, " ") end
        \\print(select("#", coroutine.wrap(function() return nil, nil end)()))
        \\print(pcall(coroutine.wrap, 1))
    , "function\t3\t20\nxy\tend\nfalse\tcannot resume dead coroutine\n1 2 3 2\n" ++
        "false\tbad argument #1 to 'coroutine.wrap' (function expected, got number)\n");
}

test "coroutine.wrap: an error is raised again at the call, located as Lua locates it" {
    try expectProgram(
        \\local bad = coroutine.wrap(function() error("boom") end)
        \\print(pcall(bad))
        \\local function call() return bad() end
        \\print(pcall(call))
        \\local b2 = coroutine.wrap(function() error("b2") end)
        \\print(pcall(function() return b2() end))
        \\local b3 = coroutine.wrap(function() error({code = 7}) end)
        \\local ok, e = pcall(b3)
        \\print(ok, e.code)
    , "false\tmain:1: boom\nfalse\tmain:3: cannot resume dead coroutine\n" ++
        "false\tmain:6: main:5: b2\nfalse\t7\n");
    try expectProgram(
        \\local b4 = coroutine.wrap(function() error("lvl0", 0) end)
        \\print(pcall(function() local r = b4() return r end))
        \\local e1 = coroutine.wrap(function()
        \\  coroutine.wrap(function() error("deep") end)()
        \\end)
        \\print(pcall(e1))
        \\local self
        \\self = coroutine.wrap(function() return self() end)
        \\print(pcall(self))
    , "false\tmain:2: lvl0\nfalse\tmain:4: main:4: deep\n" ++
        "false\tmain:8: cannot resume non-suspended coroutine\n");
}

test "coroutine.wrap: called from Zig, as a body, and nested" {
    try expectProgram(
        \\local g = coroutine.wrap(function() for i = 1, 100 do coroutine.yield(i) end end)
        \\local t = {5, 3, 8, 1}
        \\table.sort(t, function(a, b) g() return a < b end)
        \\print(t[1], t[4], g() > 2)
        \\local mt = {__index = coroutine.wrap(function(t, k)
        \\  while true do t, k = coroutine.yield(k .. "!") end
        \\end)}
        \\local o = setmetatable({}, mt)
        \\print(o.x, o.y)
    , "1\t8\ttrue\nx!\ty!\n");
    try expectProgram(
        \\local co = coroutine.create(coroutine.wrap(function(a)
        \\  local b = coroutine.yield(a * 2)
        \\  return b + 1
        \\end))
        \\print(coroutine.resume(co, 5))
        \\print(coroutine.resume(co, 7))
        \\print(coroutine.status(co))
        \\local outer = coroutine.wrap(function()
        \\  local inner = coroutine.wrap(function() coroutine.yield("in1") coroutine.yield("in2") end)
        \\  coroutine.yield(inner())
        \\  coroutine.yield(inner())
        \\end)
        \\print(outer(), outer())
        \\local w = coroutine.wrap(function() coroutine.yield(coroutine.isyieldable(), coroutine.status(coroutine.running())) end)
        \\print(w())
    , "true\t10\nfalse\tcannot resume dead coroutine\ndead\nin1\tin2\ntrue\trunning\n");
}

test "coroutine.wrap: the collector keeps a wrap function's coroutine" {
    try expectProgram(
        \\local gens = {}
        \\for i = 1, 50 do
        \\  gens[i] = coroutine.wrap(function() for j = 1, 3 do coroutine.yield(i * 10 + j) end end)
        \\end
        \\local s = 0
        \\for r = 1, 3 do
        \\  for i = 1, 50 do s = s + gens[i]() end
        \\  local junk = {}
        \\  for k = 1, 20000 do junk[k] = {k} end
        \\end
        \\local n = 0
        \\for i = 1, 2000 do
        \\  local w = coroutine.wrap(function(x) local y = coroutine.yield(x + 1) return y * 2 end)
        \\  n = n + w(i) + w(3)
        \\end
        \\print(s, n)
    , "38550\t2015000\n");
}

test "debug.traceback in a coroutine: its own stack, a native body as Lua's [C] row" {
    // As Lua 5.4.6 lays the rows out (it names the functions `<main:2>`
    // and `local 'f'`, docs/differences-from-lua.md).
    try expectProgram(
        \\local w = coroutine.wrap(pcall)
        \\w(function() print(debug.traceback("m")) end)
        \\local co = coroutine.create(function() local function f() print(debug.traceback()) end f() end)
        \\coroutine.resume(co)
    , "m\nstack traceback:\n\tmain:2: in function 'anonymous'\n\t[C]: in function 'pcall'\n" ++
        "stack traceback:\n\tmain:3: in function 'f'\n\tmain:3: in function 'anonymous'\n");
}
