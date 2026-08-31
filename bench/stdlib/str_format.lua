-- string.format throughput + LuaJIT parity probe.
--
-- Exercises the formatter's conversion switch and flags/width/precision in a hot
-- loop: %d %x %o %g, signed/space/zero/left flags, a fixed-precision float, a
-- padded string, %c, and the %% literal. Output is an integer length checksum
-- plus the final formatted line, so it is deterministic and byte-identical to
-- LuaJIT (and across all of mahina's tiers).
--
--   mahina              bench/stdlib/str_format.lua 200000   # tier-0
--   mahina --jit-native bench/stdlib/str_format.lua 200000   # tier-1b
--   luajit              bench/stdlib/str_format.lua 200000   # reference
--
-- @bench args="200000" luajit=compatible

local fmt = string.format

local function run(n)
  local acc = 0
  local sample = ""
  for i = 1, n do
    local s = fmt("%d|%05x|%o|%+d|% d|%-6s|%8.3f|%g|%c|100%%",
      i, i, i, i, i, "id", i * 0.25, i / 3, 65 + (i % 26))
    acc = acc + #s
    if i == n then sample = s end
  end
  return acc, sample
end

local N = tonumber(arg and arg[1]) or 200000
local acc, sample = run(N)
io.write(string.format("len_sum=%d\nsample=%s\n", acc, sample))
