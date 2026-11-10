-- @bench args="2000000" luajit=compatible
-- Operator metamethods whose handlers do not allocate (doc 77 §2.1): an
-- in-place `__add` that updates its left operand and returns it, and
-- comparisons and `__unm` on a field.
local V = {}
V.__index = V
V.__add = function(a, b)
    a.x = a.x + b.x
    a.y = a.y + b.y
    return a
end
V.__lt = function(a, b)
    return a.x < b.x
end
V.__le = function(a, b)
    return a.x <= b.x
end
V.__eq = function(a, b)
    return a.x == b.x
end
V.__unm = function(a)
    return -a.y
end

local function new(x, y)
    return setmetatable({ x = x, y = y }, V)
end

local n = tonumber(arg[1])
local acc, d, lim = new(0, 0), new(1, 2), new(0, 0)
local s = 0
for i = 1, n do
    acc = acc + d
    lim.x = i % 1000
    if acc.x > 1000 then
        acc.x = acc.x - 1000
    end
    if acc.y > 1000 then
        acc.y = acc.y - 1000
    end
    if lim < acc then
        s = s + 1
    end
    if acc <= lim then
        s = s + 2
    end
    if acc == lim then
        s = s + 3
    end
    s = s + -acc
end
print(s, acc.x, acc.y)
