-- @bench args="200 2000" luajit=skip
-- Compile-time stress for bytecode liveness over chains of multret calls,
-- `f(f(f(...f(1)...)))`: every call but the outermost is both the consumer
-- of the call inside it and the producer for the call around it (doc 61 §5,
-- the producer→consumer survivor sets). The liveness pass must stay linear
-- in the chain length (Rule #20): a per-producer re-walk of the chain made a
-- 2,800-deep chain spend ~0.09 s in `bc_liveness`. A chain nests one level
-- per call, and the parser takes 200 levels (`parser.max_depth`, as Lua and
-- LuaJIT do), so the `calls` are split into chains of 190 in one chunk.
-- luajit=skip: LuaJIT's 250 registers per function stop a chain at 123.
local n = tonumber(arg and arg[1]) or 200
local calls = tonumber(arg and arg[2]) or 2000
local per_chain = 190

local function chain(depth)
    return string.rep("f(", depth) .. "1" .. string.rep(")", depth)
end

local parts = { "local function f(...) return ... end\n" }
local left = calls
local k = 0
while left > per_chain do
    k = k + 1
    parts[#parts + 1] = "local c" .. k .. " = " .. chain(per_chain) .. "\n"
    left = left - per_chain
end
parts[#parts + 1] = "return " .. chain(left)
local src = table.concat(parts)

local sum = 0
for _ = 1, n do
    local chunk = assert(load(src))
    sum = sum + chunk()
end
print(sum)
