-- Function metamethods on a hot path (doc 68 §10): `__index`, `__newindex`,
-- `__add`, `__eq`, `__lt` and `__concat`, each a Lua function, in one loop.
-- Every operation makes one metamethod call, so the call and return of the
-- handler dominate. Integer checksum.
--
--   mahina bench/stdlib/meta_calls.lua 200000
--
-- @bench args="200000" luajit=compatible

local n = tonumber(arg and arg[1]) or 200000

local V = {}
V.__index = function(t, k)
    return k * 2
end
V.__newindex = function(t, k, v)
    rawset(t, "last", v)
end
V.__add = function(a, b)
    return a.x + b.x
end
V.__eq = function(a, b)
    return a.x == b.x
end
V.__lt = function(a, b)
    return a.x < b.x
end
V.__concat = function(a, b)
    return a.x
end

local p = setmetatable({ x = 1 }, V)
local q = setmetatable({ x = 2 }, V)
local acc = 0
for i = 1, n do
    acc = acc + p[i]
    p[i] = i
    acc = acc + (p + q)
    if p == q then
        acc = acc + 1
    end
    if p < q then
        acc = acc + 3
    end
    acc = acc + (p .. q)
end
print(acc, p.last)
