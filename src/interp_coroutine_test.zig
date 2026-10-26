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
