-- @bench args="300000" luajit=compatible luajit_src=_ref/euler14-bit.lua name=euler14-bit
-- Adapted from LuaJIT/bench/euler14-bit.lua (Computer Language Benchmarks Game
-- port). The upstream uses LuaJIT's BitOp library (`bit.band`/`bor`/`lshift`/…,
-- int32 semantics); here those calls are rewritten to lune's native 64-bit
-- bitwise operators. The branchless Collatz step is unchanged in meaning, so the
-- output is byte-identical to the upstream `bit.*` version (which LuaJIT runs via
-- `luajit_src`). lune's 64-bit ops never truncate; the cached chains land on the
-- same answer (e.g. N=1e6 → "Found 837799").

local N = tonumber(arg and arg[1]) or 10000000
local cache, m, n = { 1 }, 1, 1
for i = 2, N do
  local j = i
  for len = 1, 1000000000 do
    -- Branchless Collatz: when j is even, (j&1)-1 == -1 (all ones) selects j>>1;
    -- when odd, ~((j&1)-1) == -1 selects 3j+1 (== (j<<1)+j+1). One side is 0.
    j = (((j >> 1) & ((j & 1) - 1)) | (((j << 1) + j + 1) & ~((j & 1) - 1)))
    local x = cache[j]; if x then j = x + len; break end
  end
  cache[i] = j
  if j > m then m, n = j, i end
end
io.write("Found ", n, " (chain length: ", m, ")\n")
