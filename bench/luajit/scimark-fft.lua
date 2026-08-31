-- @bench args="500" luajit=compatible name=scimark-fft
-- SciMark FFT kernel (from LuaJIT/bench/scimark-fft.lua). Requires the shared
-- scimark_lib.lua from the same directory — the runner runs each bench with cwd
-- set to its directory, so package.path's "./?.lua" resolves it. A float/array-
-- heavy numeric throughput target, the workload mahina's tracing JIT does not yet
-- accelerate.
--
-- The upstream one-liner discards the kernel's flop count and prints nothing, so
-- this bench's frozen digest was sha256("") and its cross-tier check compared
-- "" == "" == "". The trailing print closes that; see scimark_lib.lua's
-- `benchmarks.checksum()` for why the checksum is an exact integer fold rather
-- than a formatted float.
--
-- Byte-parity with LuaJIT depends on scimark_lib.lua's forced portable RNG (see
-- its "mahina-local edit 1 of 2"). It ALSO depends on mahina and LuaJIT's libm
-- agreeing on the `sin` values fft_transform feeds in: verified bit-identical at
-- this pinned size (n=1024), but that is an empirical result, not a guarantee —
-- re-verify against LuaJIT if the transform size ever changes.
local lib = require("scimark_lib")
lib.FFT(1024)(tonumber(arg and arg[1]) or 50000)
print(lib.checksum())
