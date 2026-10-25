-- Long strings that are built again and again: every concatenation result is
-- already interned, so each one is a hash hit plus a full byte compare, and
-- then a table key. The strings are 70-80 bytes, past the 64 where
-- `std.mem.eql` turned slow on AVX-512 (`src/bytes.zig`). Accumulates an
-- integer checksum, byte-identical to LuaJIT.
--
--   mahina              bench/stdlib/str_long_keys.lua 300000   # tier-0
--   mahina --jit-native bench/stdlib/str_long_keys.lua 300000   # tier-1b
--   luajit              bench/stdlib/str_long_keys.lua 300000   # reference
--
-- @bench args="300000" luajit=compatible

local N = tonumber(arg and arg[1]) or 300000

local prefix = "configuration/section/subsection/entry-with-a-rather-long-name/"
local counts = {}
local acc = 0
for i = 1, N do
  local k = prefix .. tostring(i % 32) .. "/value"
  counts[k] = (counts[k] or 0) + 1
  acc = acc + #k
end

local distinct = 0
for _, c in pairs(counts) do distinct = distinct + c end
print(acc, distinct)
