-- Mahina-only op probes (syntax LuaJIT lacks). Each adds one construct over `base`.
local which, n = arg[1], tonumber(arg[2])
local P = {}
P.base = function(n) local s = 0 for i = 1, n do s = s + i end return s end
local fx = 0.5
P.fidiv = function(n) local s = 0 for i = 1, n do local b = fx // 0.25 s = s + i end return s end
P.fmod = function(n) local s = 0 for i = 1, n do local b = fx % 0.25 s = s + i end return s end
P.mod = function(n) local s = 0 for i = 1, n do local b = i % 7 s = s + i end return s end
P.idiv = function(n) local s = 0 for i = 1, n do local b = i // 7 s = s + i end return s end
print(P[which](n))
