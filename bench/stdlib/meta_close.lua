-- Lua 5.4 metamethods on a hot path (doc 68 §10): `__len` and a
-- to-be-closed variable whose `__close` is a Lua function, closed once per
-- iteration. LuaJIT has neither (`__len` on tables needs 5.2 compat).
-- Integer checksum.
--
--   mahina bench/stdlib/meta_close.lua 200000
--
-- @bench args="200000" luajit=skip

local n = tonumber(arg and arg[1]) or 200000

local closed = 0
local C = {
  __close = function(o, e) closed = closed + o.w end,
  __len = function(o) return o.w end,
}
local acc = 0
for i = 1, n do
  local o <close> = setmetatable({ w = i % 7 }, C)
  acc = acc + #o
end
print(acc, closed)
