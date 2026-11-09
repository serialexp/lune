-- Doc 81 probes: one global operation per iteration. Every probe runs in
-- a function, so its loop counter and accumulator are locals, as in
-- `base`; only the probed construct touches the globals table.
local which, n = arg[1], tonumber(arg[2])
G = 3
F = function(x)
    return x
end
local P = {}
P.base = function(n)
    local s = 0
    for i = 1, n do
        s = s + i
    end
    return s
end
-- A global read.
P.gget = function(n)
    local s = 0
    for i = 1, n do
        local b = G
        s = s + i
    end
    return s
end
-- A global store.
P.gset = function(n)
    local s = 0
    for i = 1, n do
        G = i
        s = s + i
    end
    return s
end
-- A global read-modify-write, the `count = count + 1` of script code.
P.grmw = function(n)
    local s = 0
    for i = 1, n do
        G = G + 1
        s = s + i
    end
    return s
end
-- A call through a global function name.
P.gcall = function(n)
    local s = 0
    for i = 1, n do
        F(i)
        s = s + i
    end
    return s
end
-- A library function through its global table: a global read and a field.
P.gfield = function(n)
    local s = 0
    for i = 1, n do
        local b = math.abs(i)
        s = s + i
    end
    return s
end
-- A builtin called by its global name.
P.gbuiltin = function(n)
    local s = 0
    for i = 1, n do
        local b = type(i)
        s = s + i
    end
    return s
end
print(P[which](n))
