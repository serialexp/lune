-- coroutine.resume/yield switch throughput (doc 73 benchmarks).
--
-- A generator yields `n` values; the yield is made `depth` calls deep inside
-- the coroutine, so the switch cost is measured with a shallow and a deep
-- coroutine stack (a switch must not cost more with more frames below it).
-- Integer checksum of what crossed the boundary.
--
--   mahina bench/stdlib/co_pingpong.lua 200000 1
--   luajit bench/stdlib/co_pingpong.lua 200000 1
--
-- @bench args="200000 1" luajit=compatible name=co_pingpong
-- @bench args="200000 20" luajit=compatible name=co_pingpong_d20
-- @bench args="200000 150" luajit=compatible name=co_pingpong_d150

local yield = coroutine.yield

local function deep(d, i)
    if d <= 1 then
        return yield(i)
    end
    return deep(d - 1, i) + 0
end

local function gen(n, depth)
    return coroutine.create(function()
        local back = 0
        for i = 1, n do
            back = back + deep(depth, i)
        end
        return back
    end)
end

local n = tonumber(arg and arg[1]) or 200000
local depth = tonumber(arg and arg[2]) or 1
local co = gen(n, depth)
local resume = coroutine.resume
local acc = 0
local ok, v = resume(co)
while coroutine.status(co) == "suspended" do
    acc = acc + v
    ok, v = resume(co, v % 7)
end
print(acc, v)
