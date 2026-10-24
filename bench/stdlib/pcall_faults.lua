-- Caught runtime faults in a hot loop: raising, describing and catching
-- "attempt to call/index a nil value", with and without the variable name
-- the VM derives from the bytecode (`src/bc_names.zig`), plus a fault it
-- does not name. A program that uses pcall for control flow pays this per
-- fault.
--
--   mahina              bench/stdlib/pcall_faults.lua   # tier-0
--   luajit              bench/stdlib/pcall_faults.lua   # reference
--
-- @bench args="300000" luajit=compatible
-- Only the count is printed: the messages' chunk names differ by engine.
local N = tonumber(arg and arg[1]) or 300000

local t = {}
local function work(i)
  local a, b, c = i, i * 2, i * 3
  if a > b then c = a elseif b > c then c = b end
  for k = 1, 3 do a = a + k end
  local s = 0
  if i % 2 == 0 then s = s + a else s = s - b end
  local kind = i % 4
  if kind == 0 then return t.missing(a, b, c, s) end -- field
  if kind == 1 then return t:method(a) end -- method
  if kind == 2 then return t.x.y end -- index of a nil field
  return s + t.z -- arithmetic on nil (not named)
end

local failed = 0
for i = 1, N do
  if not pcall(work, i) then failed = failed + 1 end
end
print(failed)
