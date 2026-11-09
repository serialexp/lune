-- A small pure function called from a loop that cannot trace: the cost of
-- entering and leaving a one-shot (head) trace once per call, against the
-- tier-0 body it replaces. The loop compares two distinct tables, which
-- keeps the loop itself off the trace, so every call to `f` goes through
-- the head-trace entry from tier 0 (doc 84). Integer checksum,
-- byte-identical to LuaJIT.
--
--   mahina              bench/call_small_fn.lua 1000000   # tier-0
--   mahina --jit-native bench/call_small_fn.lua 1000000   # tier-1b
--   luajit              bench/call_small_fn.lua 1000000   # reference
-- @bench args="1000000" luajit=compatible

local function f(n)
  local x = (n * 16807) % 2147483647
  return x % 7
end

local a, b = {}, {}
local acc = 0
local N = tonumber(arg and arg[1]) or 1000000
for i = 1, N do
  if a ~= b then acc = acc + f(i) end
end
print(acc)
