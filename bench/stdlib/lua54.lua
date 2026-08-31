-- Lua 5.4 stdlib surface that LuaJIT 2.1 does NOT provide — so there is no
-- LuaJIT parity to measure (luajit=skip). The runner still checks that mahina's
-- own tiers (tier-0 / tier-1a / tier-1b) agree byte-for-byte.
--
-- Covers: math.type (integer/float subtype), math.maxinteger/mininteger,
-- rawlen (5.2 surface), table.pack(...).n and table.unpack spread.
--
--   mahina              bench/stdlib/lua54.lua 100000   # tier-0
--   mahina --jit-native bench/stdlib/lua54.lua 100000   # tier-1b
--
-- @bench args="100000" luajit=skip

local mtype = math.type
local pack, unpack, rawlen = table.pack, table.unpack, rawlen
local maxint, minint = math.maxinteger, math.mininteger

local function run(n)
  local acc = 0
  local t = { 5, 6, 7, 8 }
  for i = 1, n do
    if mtype(i) == "integer" then acc = acc + 1 end
    if mtype(i + 0.5) == "float" then acc = acc + 1 end
    if mtype("x") == nil then acc = acc + 1 end
    local p = pack(i, i + 1, i + 2)
    acc = acc + p.n
    local a, b, c = unpack(p, 1, 3)
    acc = acc + a + b + c
    acc = acc + rawlen(t)
    acc = acc + (maxint > minint and 1 or 0)
  end
  return acc
end

local N = tonumber(arg and arg[1]) or 100000
io.write(string.format("acc=%d\n", run(N)))
