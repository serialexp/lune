-- @bench args="80" luajit=compatible name=scimark-lu
-- SciMark LU-decomposition kernel (from LuaJIT/bench/scimark-lu.lua). Requires
-- scimark_lib.lua from the same directory (resolved via the runner's per-bench
-- cwd + package.path "./?.lua"). Float/array-heavy numeric throughput target.
--
-- The upstream one-liner discards the kernel's flop count and prints nothing, so
-- this bench's frozen digest was sha256("") and its cross-tier check compared
-- "" == "" == "". The trailing print closes that; the checksum folds the
-- FACTORED matrix, so it pins the pivoting and the elimination, not just the
-- input. Byte-parity with LuaJIT depends on scimark_lib.lua's forced portable
-- RNG (see its "lune-local edit 1 of 2").
local lib = require("scimark_lib")
lib.LU(100)(tonumber(arg and arg[1]) or 5000)
print(lib.checksum())
