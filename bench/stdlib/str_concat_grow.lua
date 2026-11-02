-- Growing a string by repeated `..` + LuaJIT parity probe.
--
-- `s = s .. piece` builds each intermediate string in full, so the work is
-- quadratic in the final length in every Lua; what this measures is the
-- constant: the copy, the allocator's handling of big short-lived blocks,
-- and how soon the collector hands them back. Three piece sizes, each grown
-- to the same length, so small and large steps are both covered.
--
--   mahina              bench/stdlib/str_concat_grow.lua 80000   # tier-0
--   mahina --jit-native bench/stdlib/str_concat_grow.lua 80000   # tier-1b
--   luajit              bench/stdlib/str_concat_grow.lua 80000   # reference
--
-- @bench args="80000" luajit=compatible

local n = tonumber(arg[1]) or 80000

local function grow(piece, target)
  local s = ""
  while #s < target do s = s .. piece end
  return s
end

local total = 0
for _, piece in ipairs({ "x", "abcdefgh", ("0123456789"):rep(10) }) do
  local s = grow(piece, n)
  total = total + #s
end
print(total)
