-- `string.gsub` with a function replacement (doc 68 §10): every match is a
-- call from the gsub's activation (§7.4), once with captures, once with the
-- whole match, once keeping the original (`nil`). Integer checksum over
-- result lengths and counts, so the output is the same on every correct
-- implementation.
--
--   mahina              bench/stdlib/gsub_fn.lua 20000   # tier-0
--   mahina --jit-native bench/stdlib/gsub_fn.lua 20000   # tier-1b
--   luajit              bench/stdlib/gsub_fn.lua 20000   # reference
--
-- @bench args="20000" luajit=compatible

local gsub = string.gsub

local text = "the cat sat on the mat with the bat and a hat"

local function upper(w)
    return w:upper()
end

local function pair(a, b)
    return b .. a
end

local function maybe(w)
    if #w == 3 then
        return nil
    end
    return w
end

local function run(n)
    local acc = 0
    for i = 1, n do
        local r1, c1 = gsub(text, "%w+", upper)
        acc = acc + #r1 + c1
        local r2, c2 = gsub(text, "(%w)(%w+)", pair)
        acc = acc + #r2 + c2
        local r3, c3 = gsub(text, "%w+", maybe)
        acc = acc + #r3 + c3
    end
    return acc
end

local n = tonumber(arg and arg[1]) or 20000
print(run(n))
