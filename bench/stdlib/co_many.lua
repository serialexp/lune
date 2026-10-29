-- Many live coroutines at once (doc 73 benchmarks).
--
-- `n` coroutines are created and each is resumed `rounds` times round-robin,
-- so all of them are suspended mid-body together: the memory each live
-- coroutine holds (its stack's touched pages) and the cost of switching
-- between many stacks. Integer checksum.
--
--   mahina bench/stdlib/co_many.lua 10000 4
--
-- @bench args="10000 4" luajit=compatible exclusive=true

local n = tonumber(arg and arg[1]) or 10000
local rounds = tonumber(arg and arg[2]) or 4
local cos = {}
for k = 1, n do
  cos[k] = coroutine.create(function(a)
    local s = a
    while true do s = s + coroutine.yield(s) end
  end)
end
local acc = 0
for r = 1, rounds do
  for k = 1, n do
    local _, v = coroutine.resume(cos[k], k + r)
    acc = (acc + v) % 1000000007
  end
end
print(n, acc)
