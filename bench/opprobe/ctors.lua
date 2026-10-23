-- Table constructor probes: what `{...}` costs per shape.
local which, n = arg[1], tonumber(arg[2])
local P = {}
P.base = function(n) local s = 0 for i = 1, n do s = s + i end return s end
P.newt = function(n) local s = 0 for i = 1, n do local b = {} s = s + i end return s end
-- One positional int (binary-trees' leaf `{ item }`).
P.c1i = function(n) local s = 0 for i = 1, n do local b = { i } s = s + i end return s end
-- Three positional ints: one lane throughout.
P.c3i = function(n) local s = 0 for i = 1, n do local b = { i, i, i } s = s + i end return s end
-- An int then two tables (binary-trees' node `{ item, left, right }`).
P.c3m = function(n) local s, t = 0, {} for i = 1, n do local b = { i, t, t } s = s + i end return s end
-- Three tables: the value lane from the first store.
P.c3t = function(n) local s, t = 0, {} for i = 1, n do local b = { t, t, t } s = s + i end return s end
-- Two named fields (a record).
P.c2n = function(n) local s = 0 for i = 1, n do local b = { x = i, y = i } s = s + i end return s end
-- Four named fields.
P.c4n = function(n) local s = 0 for i = 1, n do local b = { x = i, y = i, z = i, w = i } s = s + i end return s end
print(P[which](n))
