-- @bench args="80" luajit=compatible name=scimark-lu
-- SciMark LU-decomposition kernel (verbatim from LuaJIT/bench/scimark-lu.lua).
-- Requires scimark_lib.lua from the same directory (resolved via the runner's
-- per-bench cwd + package.path "./?.lua"). The kernel returns a flop count the
-- wrapper discards: stdout is empty, a pure-timing bench. Float/array-heavy
-- numeric throughput target.
require("scimark_lib").LU(100)(tonumber(arg and arg[1]) or 5000)
