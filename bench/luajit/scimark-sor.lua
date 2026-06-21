-- @bench args="1000" luajit=compatible name=scimark-sor
-- SciMark SOR (successive over-relaxation) kernel (verbatim from
-- LuaJIT/bench/scimark-sor.lua). Requires scimark_lib.lua from the same directory
-- (runner per-bench cwd + package.path "./?.lua"). The kernel returns a flop count
-- the wrapper discards: stdout is empty, a pure-timing bench. Float/array-heavy
-- numeric throughput target.
require("scimark_lib").SOR(100)(tonumber(arg and arg[1]) or 50000)
