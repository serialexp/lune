-- Coroutines (doc 86 P1 corpus): a generator, wrap, a yield across pcall,
-- status changes and values passed both ways.
local function gen(n)
    return coroutine.create(function(a)
        local got = a
        for i = 1, n do
            got = coroutine.yield(i * got)
        end
        return "done", got
    end)
end

local co = gen(4)
local out = {}
local v = 1
while true do
    local ok, x, y = coroutine.resume(co, v)
    if coroutine.status(co) == "dead" then
        out[#out + 1] = tostring(x) .. ":" .. tostring(y)
        break
    end
    out[#out + 1] = tostring(x)
    v = v + 1
end
print("gen", table.concat(out, ","))

local evens = coroutine.wrap(function()
    for i = 2, 10, 2 do
        coroutine.yield(i)
    end
end)
local s = 0
for _ = 1, 5 do
    s = s + evens()
end
print("wrap", s)

local guarded = coroutine.create(function()
    local ok, err = pcall(function()
        coroutine.yield("inside")
        error("boom")
    end)
    coroutine.yield(ok, err)
    return "after"
end)
print("pcall", coroutine.resume(guarded))
print("pcall", coroutine.resume(guarded))
print("pcall", coroutine.resume(guarded))
print("status", coroutine.status(guarded), coroutine.resume(guarded))
