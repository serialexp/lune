-- `table.sort` that calls Lua for every comparison (doc 68 §10): once with a
-- comparator function, once over objects ordered by a `__lt` function. Each
-- comparison is a call from the sort's activation (doc 68 §5.1). The keys
-- are distinct, so every correct sort gives the same order and checksum.
--
--   mahina              bench/stdlib/sort_cmp.lua 20000   # tier-0
--   mahina --jit-native bench/stdlib/sort_cmp.lua 20000   # tier-1b
--   luajit              bench/stdlib/sort_cmp.lua 20000   # reference
--
-- @bench args="20000" luajit=compatible

local N = tonumber(arg and arg[1]) or 20000

-- 7919 is prime and does not divide N, so this is a permutation of 0..N-1.
local keys = {}
for i = 1, N do keys[i] = (i * 7919) % N end
local V = { __lt = function(a, b) return a.k < b.k end }
local objs = {}
for i = 1, N do objs[i] = setmetatable({ k = keys[i] }, V) end

local function desc(a, b) return a > b end

local acc = 0
for round = 1, 3 do
  local t = {}
  for i = 1, N do t[i] = keys[(i + round * 4099) % N + 1] end
  table.sort(t, desc)
  for i = 1, N, 97 do acc = (acc * 31 + t[i] + i) % 1000000007 end
  local u = {}
  for i = 1, N do u[i] = objs[(i + round * 4099) % N + 1] end
  table.sort(u)
  for i = 1, N, 97 do acc = (acc * 31 + u[i].k + i) % 1000000007 end
end
print(acc)
