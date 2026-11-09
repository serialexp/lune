-- Coroutine create/finish churn (doc 73 benchmarks).
--
-- `n` short-lived coroutines, each created, resumed twice and finished, so
-- stack allocation and release dominate; only a few are alive at a time, so
-- memory must stay bounded however large `n` is. Integer checksum.
--
--   mahina bench/stdlib/co_churn.lua 50000
--
-- @bench args="50000" luajit=compatible

local n = tonumber(arg and arg[1]) or 50000
local acc = 0
for k = 1, n do
    local co = coroutine.create(function(a)
        local b = coroutine.yield(a + 1)
        return a + b
    end)
    local _, x = coroutine.resume(co, k)
    local _, y = coroutine.resume(co, x)
    acc = (acc + y) % 1000000007
end
print(n, acc)
