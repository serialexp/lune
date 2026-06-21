-- @bench args="500" luajit=compatible name=scimark-fft
-- SciMark FFT kernel (verbatim from LuaJIT/bench/scimark-fft.lua). Requires the
-- shared scimark_lib.lua from the same directory — the runner runs each bench
-- with cwd set to its directory, so package.path's "./?.lua" resolves it. The
-- kernel returns a flop count that the wrapper discards: stdout is empty, so this
-- is a pure-timing bench (empty == empty satisfies luajit=compatible parity). It
-- is a float/array-heavy numeric throughput target, the workload lune's tracing
-- JIT does not yet accelerate.
require("scimark_lib").FFT(1024)(tonumber(arg and arg[1]) or 50000)
