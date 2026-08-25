-- @bench args="3000" luajit=compatible name=scimark-sparse
-- SciMark sparse matrix-multiply kernel (from
-- LuaJIT/bench/scimark-sparse.lua). Requires scimark_lib.lua from the same
-- directory (runner per-bench cwd + package.path "./?.lua"). Float/array-heavy
-- numeric throughput target.
--
-- The upstream one-liner discards the kernel's flop count and prints nothing, so
-- this bench's frozen digest was sha256("") and its cross-tier check compared
-- "" == "" == "". The trailing print closes that; the checksum folds the result
-- vector `vy`, i.e. the product the kernel actually computes. Byte-parity with
-- LuaJIT depends on scimark_lib.lua's forced portable RNG (see its "lune-local
-- edit 1 of 2").
local lib = require("scimark_lib")
lib.SPARSE(1000, 5000)(tonumber(arg and arg[1]) or 150000)
print(lib.checksum())
