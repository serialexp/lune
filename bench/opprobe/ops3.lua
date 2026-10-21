-- Item 4 probes: the cost of the ops the new forms would remove.
local which, n = arg[1], tonumber(arg[2])
local P = {}
P.base = function(n) local s = 0 for i = 1, n do s = s + i end return s end
-- One `load_int` (a constant materialised into a register).
P.kint = function(n) local s = 0 for i = 1, n do local b = 7 s = s + i end return s end
-- `load_const` of a string.
P.kstr = function(n) local s = 0 for i = 1, n do local b = "x" s = s + i end return s end
-- A local table's field read and write (no upvalue load).
P.lfget = function(n) local t = { x = 1 } local s = 0 for i = 1, n do local b = t.x s = s + i end return s end
P.lfset = function(n) local t = { x = 1 } local s = 0 for i = 1, n do t.x = i s = s + i end return s end
-- `if i < n` with locals only: compare + branch.
P.iflv = function(n) local s = 0 for i = 1, n do if i > n then s = 0 end s = s + i end return s end
-- `x == nil` / `x == "s"` against constants.
P.eqnil = function(n) local s, x = 0, 1 for i = 1, n do if x == nil then s = 0 end s = s + i end return s end
-- One `pairs` step: an n-key hash traversed once per outer iteration.
P.pairs = function(n)
  local t = {}
  for i = 1, 100 do t["k" .. i] = i end
  local s = 0
  for r = 1, math.floor(n / 100) do for k, v in pairs(t) do s = s + v end end
  return s
end
print(P[which](n))
