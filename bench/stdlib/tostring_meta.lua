-- `tostring` of an object whose `__tostring` is a Lua function (doc 68 §10):
-- each call is a call from the `tostring` activation (§7.5), through a
-- plain method-style handler, a handler that reads its object, and a handler
-- answering a number (converted). Integer checksum over result lengths, so
-- the output is the same on every correct implementation.
--
--   mahina              bench/stdlib/tostring_meta.lua 200000   # tier-0
--   mahina --jit-native bench/stdlib/tostring_meta.lua 200000   # tier-1b
--   luajit              bench/stdlib/tostring_meta.lua 200000   # reference
--
-- @bench args="200000" luajit=compatible

local tostring = tostring

local A = setmetatable({}, {
    __tostring = function()
        return "A"
    end,
})
local B = setmetatable(
    { name = "bee" },
    {
        __tostring = function(o)
            return o.name
        end,
    }
)
local C = setmetatable({}, {
    __tostring = function()
        return 12345
    end,
})

local function run(n)
    local acc = 0
    for i = 1, n do
        acc = acc + #tostring(A) + #tostring(B) + #tostring(C)
    end
    return acc
end

local n = tonumber(arg and arg[1]) or 200000
print(run(n))
