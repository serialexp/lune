-- @bench args="10000000" luajit=skip
-- One `<close>` value reused in a loop: its `__close` runs once per
-- iteration and nothing is allocated (doc 77 §8; bench/stdlib/meta_close.lua
-- builds a new value each time). LuaJIT has no `<close>`, so mahina-only.
local Guard = {
    __close = function(g, _)
        g.closed = g.closed + 1
    end,
}
local g = setmetatable({ closed = 0 }, Guard)

local n = tonumber(arg[1])
local s = 0
for i = 1, n do
    local h <close> = g
    s = s + i % 5
end
print(s, g.closed)
