-- @bench args="1000" luajit=compatible name=scimark-sor
-- SciMark SOR (successive over-relaxation) kernel (from
-- LuaJIT/bench/scimark-sor.lua). Requires scimark_lib.lua from the same directory
-- (runner per-bench cwd + package.path "./?.lua"). Float/array-heavy numeric
-- throughput target.
--
-- The upstream one-liner discards the kernel's flop count and prints nothing, so
-- this bench's frozen digest was sha256("") and its cross-tier check compared
-- "" == "" == "". The trailing print closes that; the checksum folds the relaxed
-- matrix, which SOR mutates in place. Byte-parity with LuaJIT depends on
-- scimark_lib.lua's forced portable RNG (see its "lune-local edit 1 of 2").
local lib = require("scimark_lib")
lib.SOR(100)(tonumber(arg and arg[1]) or 50000)
print(lib.checksum())
