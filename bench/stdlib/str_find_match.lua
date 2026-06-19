-- string.find / string.match throughput + LuaJIT parity probe.
--
-- Exercises the pattern matcher's anchored and unanchored paths: a plain (no
-- pattern) find, a two-capture word=word match, a single character-class match
-- coerced through tonumber, and an anchored match. Integer checksum keeps output
-- deterministic and byte-identical to LuaJIT.
--
--   lune              bench/stdlib/str_find_match.lua 100000   # tier-0
--   lune --jit-native bench/stdlib/str_find_match.lua 100000   # tier-1b
--   luajit            bench/stdlib/str_find_match.lua 100000   # reference
--
-- @bench args="100000" luajit=compatible

local find, match = string.find, string.match

local text = "key=value; name=lune; year=2026; lang=zig"

local function run(n)
  local acc = 0
  for i = 1, n do
    local s, e = find(text, "year", 1, true)   -- plain substring search
    acc = acc + s + e
    local k, v = match(text, "(%w+)=(%w+)")     -- first key=value, two captures
    acc = acc + #k + #v
    local digits = match("item-00420-x", "%d+") -- class quantifier
    acc = acc + tonumber(digits)
    if match(text, "^key") then acc = acc + 1 end  -- anchored
  end
  return acc
end

local N = tonumber(arg and arg[1]) or 100000
io.write(string.format("acc=%d\n", run(N)))
