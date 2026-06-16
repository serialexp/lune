-- Integer-limit sieve of Eratosthenes — the tier-1b *array* native-codegen
-- benchmark (Phase B). This is the canonical `bench/nsieve.lua` shape, but with
-- an INTEGER limit `m` instead of `(2^(N-i))*10000`.
--
-- Why the variant exists: canonical nsieve derives its limit from `2^x`, a float
-- `pow`, so the numeric-for loop variable and limit are floats. lune's tier-1b
-- backend is int/bool-only (no XMM/float support — a deferred phase), so the hot
-- loops bail to tier-1a on `guard_float` and never JIT, *regardless* of the
-- array path being fully supported. With an integer `m`, the loop variables stay
-- int and the array read (`if p[i]`) + write (`for k=i+i,m,i do p[k]=false end`)
-- inner loops compile to native x86-64 against the bool-lane packed array.
--
-- Run head-to-head:
--   lune                 bench/sieve_int.lua 4000000   # tier-0 (bytecode interp)
--   lune --trace         bench/sieve_int.lua 4000000   # tier-1a (IR interp)
--   lune --jit-native    bench/sieve_int.lua 4000000   # tier-1b (native x64)
--   lune --dump-native   bench/sieve_int.lua 4000000   # confirm both traces compile
--   luajit               bench/sieve_int.lua 4000000   # reference
-- Output is byte-identical across all four (and to LuaJIT).

local function nsieve(p, m)
  for i = 2, m do p[i] = true end
  local count = 0
  for i = 2, m do
    if p[i] then
      for k = i + i, m, i do p[k] = false end
      count = count + 1
    end
  end
  return count
end

local N = tonumber(arg and arg[1]) or 4000000
if N < 2 then N = 2 end
io.write(string.format("Primes up to %8d %8d\n", N, nsieve({}, N)))
