-- @bench args="2000000" luajit=compatible
-- A proxy table: reads through an `__index` function and writes through a
-- `__newindex` function, both closing over the backing store (doc 77 §6.6).
local store = { count = 0 }
local defaults = { step = 3 }
local proxy = setmetatable({}, {
    __index = function(_, k)
        local v = store[k]
        if v == nil then
            v = defaults[k]
        end
        return v
    end,
    __newindex = function(_, k, v)
        store[k] = v
    end,
})

local n = tonumber(arg[1])
local s = 0
for i = 1, n do
    proxy.count = (proxy.count + proxy.step) % 997
    s = s + proxy.count + i % 7
end
print(s, store.count)
