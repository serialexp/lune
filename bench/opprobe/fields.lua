-- Each probe adds one field-access construct over `base` (s = s + i).
local which, n = arg[1], tonumber(arg[2])
local P = {}
P.base = function(n) local s = 0 for i = 1, n do s = s + i end return s end
P.fget = function(n) local t = { x = 1, y = 2 } local s = 0 for i = 1, n do local b = t.x s = s + i end return s end
P.fset = function(n) local t = { x = 1, y = 2 } local s = 0 for i = 1, n do t.x = i s = s + i end return s end
local C = {} C.__index = C
function C:get() return 1 end
local o = setmetatable({ v = 1 }, C)
-- Method lookup through __index, no call.
P.mlook = function(n) local o = o local s = 0 for i = 1, n do local f = o.get s = s + i end return s end
-- Full method call.
P.mcall = function(n) local o = o local s = 0 for i = 1, n do o:get() s = s + i end return s end
-- Plain call of the same function, for comparison with mcall.
P.pcall_ = function(n) local o = o local g = C.get local s = 0 for i = 1, n do g(o) s = s + i end return s end
print(P[which](n))
