-- Each probe adds exactly one construct over `base` (s = s + i).
local which, n = arg[1], tonumber(arg[2])
local P = {}
P.base = function(n) local s = 0 for i = 1, n do s = s + i end return s end
P.lt = function(n) local s = 0 for i = 1, n do local b = i < n s = s + i end return s end
P.eq = function(n) local s = 0 for i = 1, n do local b = i == n s = s + i end return s end
P.mod = function(n) local s = 0 for i = 1, n do local b = i % 7 s = s + i end return s end
P.le = function(n) local s = 0 for i = 1, n do local b = i <= n s = s + i end return s end
P.ne = function(n) local s = 0 for i = 1, n do local b = i ~= n s = s + i end return s end
local fx = 0.5
P.flt = function(n) local s = 0 for i = 1, n do local b = fx < fx s = s + i end return s end
local sa, sb = "abc", "abd"
P.streq = function(n) local s = 0 for i = 1, n do local b = sa == sb s = s + i end return s end
P.fmod = function(n) local s = 0 for i = 1, n do local b = fx % 0.25 s = s + i end return s end
-- `//` is not LuaJIT syntax: compile it lazily so the file still parses there.
P.idiv = function(n) return load("local n = ... local s = 0 for i = 1, n do local b = i // 7 s = s + i end return s")(n) end
P.sub = function(n) local s = 0 for i = 1, n do local b = i - 7 s = s + i end return s end
P.ifl = function(n) local s = 0 for i = 1, n do if i < 0 then s = 0 end s = s + i end return s end
P.fdiv = function(n) local s = 0 for i = 1, n do local b = i / 7 s = s + i end return s end
local t = { x = 1 }
P.fget = function(n) local s = 0 for i = 1, n do local b = t.x s = s + i end return s end
P.fset = function(n) local s = 0 for i = 1, n do t.x = i s = s + i end return s end
local a = { 1, 2, 3, 4 }
P.aget = function(n) local s = 0 for i = 1, n do local b = a[3] s = s + i end return s end
P.aset = function(n) local s = 0 for i = 1, n do a[3] = i s = s + i end return s end
local function f0() end
P.call0 = function(n) local s = 0 for i = 1, n do f0() s = s + i end return s end
local function f1(x) return x end
P.call1 = function(n) local s = 0 for i = 1, n do local b = f1(i) s = s + i end return s end
P.native = function(n) local s = 0 local ab = math.abs for i = 1, n do local b = ab(i) s = s + i end return s end
P.len = function(n) local s = 0 for i = 1, n do local b = #a s = s + i end return s end
P.newt = function(n) local s = 0 for i = 1, n do local b = {} s = s + i end return s end
P.cat = function(n) local s = 0 local x = "ab" for i = 1, n do local b = x .. x s = s + i end return s end
print(P[which](n))
