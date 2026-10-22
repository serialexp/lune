-- `#t` as a stack pointer: push with `t[#t + 1] = v`, pop with `t[#t] = nil`.
--
-- Every pop leaves the array part's capacity behind as trailing nils, so `#t`
-- has to find the border past them. A linear trim made this quadratic in the
-- stack depth (TODO.md "`#t` on a table"); the border search keeps it
-- O(log capacity) per `#`. Integer checksum, byte-identical to LuaJIT.
--
--   mahina              bench/stdlib/tbl_stack.lua 200000   # tier-0
--   mahina --jit-native bench/stdlib/tbl_stack.lua 200000   # tier-1b
--   luajit              bench/stdlib/tbl_stack.lua 200000   # reference
--
-- @bench args="200000" luajit=compatible

local function run(n)
  local half = math.floor(n / 2)
  local t = {}
  local acc = 0
  -- Fill to depth n, drain to half, refill, drain to empty: the drains run
  -- over a capacity of n, the refill over half-empty capacity.
  for i = 1, n do t[#t + 1] = i end
  for _ = 1, half do acc = acc + t[#t]; t[#t] = nil end
  for i = 1, half do t[#t + 1] = i * 3 end
  while #t > 0 do acc = (acc + t[#t]) % 1000000007; t[#t] = nil end
  return acc
end

local N = tonumber(arg and arg[1]) or 200000
io.write(string.format("acc=%d\n", run(N)))
