-- Suspended coroutines dropped over a large live heap (doc 73 benchmarks).
--
-- `live` small tables stay reachable, so collecting by object count alone
-- would wait ~`live` objects between collections; meanwhile `n` coroutines
-- are each resumed once (left suspended, holding their stacks) and dropped.
-- Peak memory shows whether a dropped coroutine's stack weighs in the
-- collector's pacing. Integer checksum.
--
--   mahina bench/stdlib/co_garbage.lua 200000 150000
--
-- @bench args="200000 150000" luajit=compatible

local live_n = tonumber(arg and arg[1]) or 200000
local n = tonumber(arg and arg[2]) or 150000
local live = {}
for i = 1, live_n do live[i] = {} end
local acc = 0
for i = 1, n do
  local co = coroutine.create(function(a) local b = coroutine.yield(a + 1) return b end)
  local _, v = coroutine.resume(co, i)
  acc = (acc + v) % 1000000007
end
print(#live, acc)
