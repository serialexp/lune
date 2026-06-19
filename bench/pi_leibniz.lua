-- Leibniz series for π — the tier-1b *float/XMM* native-codegen benchmark
-- (Phase D). The hot loop is pure floating-point: a carried float accumulator,
-- a carried float sign that flips each step, an int→float promotion, and a
-- division — i.e. addsd / mulsd / divsd / cvtsi2sd, plus an integer loop
-- counter and compare. None of the deferred ops (pow, mod, idiv, float neg,
-- guard_number) appear, so the whole body compiles to native x86-64.
--
--   π/4 = Σ_{k≥0} (-1)^k / (2k+1) = 1 - 1/3 + 1/5 - 1/7 + …
--
-- Run head-to-head (output byte-identical across all four, and to LuaJIT):
--   lune                 bench/pi_leibniz.lua 50000000   # tier-0 (bytecode interp)
--   lune --trace         bench/pi_leibniz.lua 50000000   # tier-1a (IR interp)
--   lune --jit-native    bench/pi_leibniz.lua 50000000   # tier-1b (native x64)
--   lune --dump-native   bench/pi_leibniz.lua 50000000   # confirm the loop compiles
--   luajit               bench/pi_leibniz.lua 50000000   # reference
--
-- @bench args="5000000" luajit=compatible

local function leibniz(n)
  local sum = 0.0
  local sign = 1.0
  local k = 0
  while k < n do
    sum = sum + sign / (2.0 * k + 1.0) -- addsd, divsd, mulsd, cvtsi2sd(k)
    sign = sign * -1.0 -- mulsd (sign flip; not a float neg op)
    k = k + 1 -- int counter
  end
  return sum * 4.0
end

local N = tonumber(arg and arg[1]) or 50000000
io.write(string.format("pi ~ %.15g\n", leibniz(N)))
