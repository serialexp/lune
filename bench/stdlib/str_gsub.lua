-- string.gsub throughput + LuaJIT parity probe.
--
-- Exercises both supported replacement kinds: a literal string replacement (with
-- the match count) and a table replacement keyed on the first capture (words not
-- in the map are kept verbatim). Function replacement is intentionally absent —
-- mahina defers it (needs call-into-VM-from-native). Integer checksum over result
-- lengths and counts keeps output byte-identical to LuaJIT.
--
--   mahina              bench/stdlib/str_gsub.lua 80000   # tier-0
--   mahina --jit-native bench/stdlib/str_gsub.lua 80000   # tier-1b
--   luajit              bench/stdlib/str_gsub.lua 80000   # reference
--
-- @bench args="80000" luajit=compatible

local gsub = string.gsub

local text = "the cat sat on the mat with the bat"
local map = { cat = "dog", mat = "rug", bat = "owl" }

local function run(n)
  local acc = 0
  for i = 1, n do
    local r1, c1 = gsub(text, "at", "AT")    -- literal replacement + count
    acc = acc + #r1 + c1
    local r2, c2 = gsub(text, "%w+", map)    -- table replacement on each word
    acc = acc + #r2 + c2
  end
  return acc
end

local N = tonumber(arg and arg[1]) or 80000
io.write(string.format("acc=%d\n", run(N)))
