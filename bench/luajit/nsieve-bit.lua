-- @bench args="6" luajit=compatible luajit_src=_ref/nsieve-bit.lua name=nsieve-bit
-- Adapted from LuaJIT/bench/nsieve-bit.lua (Computer Language Benchmarks Game
-- port). The upstream packs the sieve into 32-bit words with LuaJIT's BitOp
-- library (`band`/`bxor`/`rshift`/`rol`, int32 semantics). Here the sieve is
-- repacked into native 64-bit words using mahina's native bitwise operators. The
-- output is a count of primes, which is independent of word size, so it is
-- byte-identical to the upstream `bit.*` version (which LuaJIT runs via
-- `luajit_src`). Two differences from a literal port: shift counts are masked
-- explicitly (`& 63`) because mahina does not mask them the way BitOp does, and the
-- workload uses `1 << k` instead of `2^k` to stay in the integer domain (mahina's
-- bitwise ops are strict integer-only — they do not coerce floats).

local function nsieve(p, m)
  local count = 0
  for i = 0, (m >> 6) do p[i] = -1 end
  for i = 2, m do
    if ((p[i >> 6] >> (i & 63)) & 1) ~= 0 then
      count = count + 1
      for j = i + i, m, i do
        local jx = j >> 6
        p[jx] = p[jx] & ~(1 << (j & 63))
      end
    end
  end
  return count
end

local N = tonumber(arg and arg[1]) or 1
if N < 2 then N = 2 end
local primes = {}
for i = 0, 2 do
  local m = (1 << (N - i)) * 10000
  io.write(string.format("Primes up to %8d %8d\n", m, nsieve(primes, m)))
end
