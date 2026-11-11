-- Two helpers with a loop each, called in turn from an outer loop: the cost
-- of getting from the end of one loop to the start of the next across a
-- return and a call (doc 87). Every row runs 1.28 M iterations of each
-- helper's loop; only the number of rounds differs, so the difference
-- between the rows is what a round costs outside the loop bodies. At 16
-- trips a round is the larger part of the run. Integer checksum,
-- byte-identical to LuaJIT.
--
--   mahina              bench/loop_ring.lua 20000 64   # tier-0
--   mahina --jit-native bench/loop_ring.lua 20000 64   # tier-1b
--   luajit              bench/loop_ring.lua 20000 64   # reference
-- @bench args="20000 64" luajit=compatible
-- @bench args="80000 16" luajit=compatible name=loop_ring_16

local N = tonumber(arg and arg[1]) or 20000
local TRIPS = tonumber(arg and arg[2]) or 64

local data = {}
for i = 1, TRIPS do
    data[i] = i % 13
end

local function sum(t)
    local s = 0
    for i = 1, #t do
        s = s + t[i]
    end
    return s
end

local function weigh(t)
    local s = 0
    for i = 1, #t do
        s = s + t[i] * i
    end
    return s
end

local check = 0
for round = 1, N do
    check = (check * 31 + sum(data) + weigh(data)) % 1000000007
    data[round % TRIPS + 1] = round % 13
end
print(check)
