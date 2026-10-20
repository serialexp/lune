-- pairs/next over hash-part tables + LuaJIT parity probe.
--
-- Traverses string-keyed and sparse-integer-keyed tables of several sizes,
-- then empties one by deleting each key as it is visited (Lua permits that
-- during a traversal). mahina and LuaJIT visit keys in different orders, so
-- the checksum only sums, which keeps output byte-identical to LuaJIT.
--
--   mahina              bench/stdlib/pairs_hash.lua 200   # tier-0
--   mahina --jit-native bench/stdlib/pairs_hash.lua 200   # tier-1b
--   luajit              bench/stdlib/pairs_hash.lua 200   # reference
--
-- @bench args="200" luajit=compatible

local reps = tonumber(arg[1]) or 200

local function build(n)
  local t = {}
  for i = 1, n do t["k" .. i] = i end
  for i = 1, math.floor(n / 4) do t[i * 1000003] = i end
  return t
end

local sizes = { 8, 64, 1000, 20000 }
local tables = {}
for i, n in ipairs(sizes) do tables[i] = build(n) end

local sum = 0
for r = 1, reps do
  local t = tables[(r % #sizes) + 1]
  for k, v in pairs(t) do sum = sum + v end
end

-- Delete while traversing: every key is visited exactly once.
local t = build(20000)
local seen = 0
for k, v in pairs(t) do
  t[k] = nil
  seen = seen + 1
end
print(sum, seen, next(t) == nil)
