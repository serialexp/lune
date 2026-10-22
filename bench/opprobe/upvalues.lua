-- Doc 71 probes: one upvalue read or write per iteration.
local which, n = arg[1], tonumber(arg[2])
local P = {}
P.base = function(n) local s = 0 for i = 1, n do s = s + i end return s end
-- A closed cell: `u`'s frame has returned.
local function mkget() local u = 3 return function(n) local s = 0 for i = 1, n do local b = u s = s + i end return s end end
P.ugetc = mkget()
-- An open cell: `u`'s frame is still live below the reader's.
P.ugeto = function(n) local u = 3 local function f(n) local s = 0 for i = 1, n do local b = u s = s + i end return s end return f(n) end
-- A write to a closed cell, from a local.
local function mkset() local u = 3 return function(n) local s = 0 for i = 1, n do u = i s = s + i end return s end end
P.usetc = mkset()
print(P[which](n))
