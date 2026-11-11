-- Metatables (doc 86 P1 corpus): __index chains, __newindex, arithmetic,
-- comparison, __concat, __call, __len, __tostring and __close.
local Vec = {}
Vec.__index = Vec

local function vec(x, y)
    return setmetatable({ x = x, y = y }, Vec)
end

Vec.__add = function(a, b)
    return vec(a.x + b.x, a.y + b.y)
end
Vec.__eq = function(a, b)
    return a.x == b.x and a.y == b.y
end
Vec.__lt = function(a, b)
    return a:len2() < b:len2()
end
Vec.__le = function(a, b)
    return a:len2() <= b:len2()
end
Vec.__tostring = function(v)
    return "(" .. v.x .. "," .. v.y .. ")"
end
Vec.__concat = function(a, b)
    return tostring(a) .. tostring(b)
end
Vec.__len = function()
    return 2
end
Vec.__call = function(v, k)
    return v.x * k
end

function Vec:len2()
    return self.x * self.x + self.y * self.y
end

local a, b = vec(1, 2), vec(3, 4)
print("add", tostring(a + b))
print("cmp", a == vec(1, 2), a < b, b <= a)
print("concat", a .. b, #a, a(10))

local log = {}
local proxy = setmetatable({}, {
    __index = function(_, k)
        return "default-" .. k
    end,
    __newindex = function(t, k, v)
        log[#log + 1] = k
        rawset(t, k, v * 2)
    end,
})
proxy.p = 5
proxy.q = 6
print("proxy", proxy.p, proxy.q, proxy.r, table.concat(log, ","))

local Base = {
    greet = function()
        return "base"
    end,
}
local Mid = setmetatable({}, { __index = Base })
local leaf = setmetatable({}, { __index = Mid })
print("chain", leaf.greet())

do
    local res <close> = setmetatable({}, {
        __close = function()
            print("closed")
        end,
    })
    print("in scope")
end
print("after scope")
