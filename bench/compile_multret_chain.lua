-- @bench args="200 2000" luajit=skip
-- Compile-time stress for bytecode liveness over a long chain of multret
-- calls, `f(f(f(...f(1)...)))`: every call but the outermost is both the
-- consumer of the call inside it and the producer for the call around it
-- (doc 61 §5, the producer→consumer survivor sets). The liveness pass must
-- stay linear in the chain length (Rule #20): a per-producer re-walk of the
-- chain made a 2,800-deep chain spend ~0.09 s in `bc_liveness`. Depth 2000
-- is near the deepest chain that still gets a liveness table
-- (`max_table_words`). luajit=skip: LuaJIT caps syntax nesting at 200.
local n = tonumber(arg and arg[1]) or 200
local depth = tonumber(arg and arg[2]) or 2000

local parts = { "local function f(...) return ... end\nreturn " }
for _ = 1, depth do parts[#parts + 1] = "f(" end
parts[#parts + 1] = "1"
for _ = 1, depth do parts[#parts + 1] = ")" end
local src = table.concat(parts)

local sum = 0
for _ = 1, n do
  local chunk = assert(load(src))
  sum = sum + chunk()
end
print(sum)
