-- string.gmatch throughput + LuaJIT parity probe.
--
-- Tokenises a CSV string with a complement-class pattern in a generic-for loop.
-- NB: mahina's gmatch returns an (iter, state, control) triple rather than Lua's
-- lone closure, but driven by `for ... in` the *visible output* (the tokens) is
-- identical to LuaJIT — which this probe asserts. Integer checksum + last token.
--
--   mahina              bench/stdlib/str_gmatch.lua 80000   # tier-0
--   mahina --jit-native bench/stdlib/str_gmatch.lua 80000   # tier-1b
--   luajit              bench/stdlib/str_gmatch.lua 80000   # reference
--
-- @bench args="80000" luajit=compatible

local gmatch = string.gmatch

local csv = "alpha,beta,gamma,delta,epsilon,zeta,eta,theta"

local function run(n)
  local acc = 0
  local last = ""
  local count = 0
  for i = 1, n do
    for tok in gmatch(csv, "[^,]+") do
      acc = acc + #tok
      last = tok
      count = count + 1
    end
  end
  return acc, last, count
end

local N = tonumber(arg and arg[1]) or 80000
local acc, last, count = run(N)
io.write(string.format("acc=%d count=%d last=%s\n", acc, count, last))
