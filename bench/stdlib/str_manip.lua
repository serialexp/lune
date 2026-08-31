-- string slicing / case / build throughput + LuaJIT parity probe.
--
-- Exercises the non-pattern string library: sub (with wrapping offsets), upper,
-- lower, reverse, len, codepoint, char, rep (with a separator). Accumulates an
-- integer checksum over code-point values and lengths so output is deterministic
-- and byte-identical to LuaJIT (the base string is all-ASCII, so a mahina code
-- point equals a LuaJIT byte).
--
--   mahina              bench/stdlib/str_manip.lua 100000   # tier-0
--   mahina --jit-native bench/stdlib/str_manip.lua 100000   # tier-1b
--   luajit              bench/stdlib/str_manip.lua 100000   # reference
--
-- @bench args="100000" luajit=compatible

local sub, upper, lower = string.sub, string.upper, string.lower
local reverse, len = string.reverse, string.len
-- string.codepoint is mahina's replacement for string.byte (doc 06 S-B); LuaJIT
-- has only string.byte. The base string is all-ASCII, so they agree exactly.
local byte, char, rep = string.codepoint or string.byte, string.char, string.rep

local base = "The quick brown Fox jumps over the lazy Dog 0123456789"

local function run(n)
  local acc = 0
  for i = 1, n do
    local lo = (i % 30) + 1
    local a = sub(base, lo, lo + 9)        -- 10-char window
    local b = lower(upper(a))
    local c = reverse(b)
    acc = acc + len(c) + byte(c, 1) + byte(c, -1)
    if i % 64 == 0 then
      local e = rep(char(65 + (i % 26)), 4, "-")  -- "A-A-A-A"
      acc = acc + len(e)
    end
  end
  return acc
end

local N = tonumber(arg and arg[1]) or 100000
io.write(string.format("acc=%d\n", run(N)))
