-- A small function called with two table shapes in turn, from a loop that
-- cannot trace: what a one-shot (head) trace costs a call whose argument it
-- was not recorded for. `inner` is a mixed array (value lane) and `leaf` an
-- integer one, so the head trace recorded on either refuses the other at
-- its entry checks (doc 84 §3.6). The loop compares two distinct tables,
-- which keeps it off the trace, so every call goes through the head-trace
-- entry from tier 0. Integer checksum, byte-identical to LuaJIT.
--
--   mahina              bench/call_two_shapes.lua 500000   # tier-0
--   mahina --jit-native bench/call_two_shapes.lua 500000   # tier-1b
--   luajit              bench/call_two_shapes.lua 500000   # reference
-- @bench args="500000" luajit=compatible

local function weight(node)
    if node[2] then
        return node[1] + 1
    end
    return node[1]
end

local a, b = {}, {}
local inner = {
    3,
    {},
    {},
}
local leaf = { 4 }
local acc = 0
local N = tonumber(arg and arg[1]) or 500000
for i = 1, N do
    if a ~= b then
        acc = acc + weight(inner) + weight(leaf)
    end
end
print(acc)
