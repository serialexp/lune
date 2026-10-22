-- Doc 70 probes: one call of a common builtin per iteration, each callee in
-- a local (no upvalue or field load in the measured construct).
local which, n = arg[1], tonumber(arg[2])
local P = {}
P.base = function(n) local s = 0 for i = 1, n do s = s + i end return s end
P.type = function(n) local f = type local s = 0 for i = 1, n do local b = f(i) s = s + i end return s end
P.floor = function(n) local f = math.floor local s = 0 for i = 1, n do local b = f(i * 0.5) s = s + i end return s end
P.abs = function(n) local f = math.abs local s = 0 for i = 1, n do local b = f(i) s = s + i end return s end
P.sqrt = function(n) local f = math.sqrt local s = 0 for i = 1, n do local b = f(i) s = s + i end return s end
P.max = function(n) local f = math.max local s = 0 for i = 1, n do local b = f(i, 7) s = s + i end return s end
P.rawget = function(n) local f, t = rawget, { 1, 2, 3 } local s = 0 for i = 1, n do local b = f(t, 2) s = s + i end return s end
P.rawequal = function(n) local f = rawequal local s = 0 for i = 1, n do local b = f(i, s) s = s + i end return s end
P.slen = function(n) local f, x = string.len, "hello" local s = 0 for i = 1, n do local b = f(x) s = s + i end return s end
P.selectn = function(n)
  local f = select
  local function count(...) return f("#", ...) end
  local s = 0
  for i = 1, n do local b = count(i, i) s = s + i end
  return s
end
print(P[which](n))
