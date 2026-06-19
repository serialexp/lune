-- basic scalar library throughput + LuaJIT parity probe.
--
-- Exercises type, select('#', ...), tostring, tonumber (incl. a hex literal),
-- rawequal, rawget/rawset, rawlen over a small mixed table. Integer checksum
-- keeps output deterministic and byte-identical to LuaJIT. (math.type lives in
-- lua54.lua — it is Lua 5.4 surface LuaJIT 2.1 lacks.)
--
--   lune              bench/stdlib/scalar.lua 100000   # tier-0
--   lune --jit-native bench/stdlib/scalar.lua 100000   # tier-1b
--   luajit            bench/stdlib/scalar.lua 100000   # reference
--
-- @bench args="100000" luajit=compatible

local type, tostring, tonumber, select = type, tostring, tonumber, select
local rawequal, rawget, rawset = rawequal, rawget, rawset

local function run(n)
  local acc = 0
  local t = { 10, 20, 30 }
  for i = 1, n do
    if type(i) == "number" then acc = acc + 1 end
    if type(t) == "table" then acc = acc + 1 end
    if type(type) == "function" then acc = acc + 1 end
    acc = acc + select("#", 1, 2, 3, 4, 5)
    acc = acc + #tostring(i)
    acc = acc + (tonumber("0x1F") or 0) % 7   -- 31 % 7 = 3
    rawset(t, 1, i % 5)
    acc = acc + rawget(t, 1)
    if rawequal(t, t) then acc = acc + 1 end
    acc = acc + #t
  end
  return acc
end

local N = tonumber(arg and arg[1]) or 100000
io.write(string.format("acc=%d\n", run(N)))
