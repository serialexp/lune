-- @bench args="3000" luajit=compatible name=scimark-sparse
-- SciMark sparse matrix-multiply kernel (verbatim from
-- LuaJIT/bench/scimark-sparse.lua). Requires scimark_lib.lua from the same
-- directory (runner per-bench cwd + package.path "./?.lua"). The kernel returns a
-- flop count the wrapper discards: stdout is empty, a pure-timing bench.
-- Float/array-heavy numeric throughput target.
require("scimark_lib").SPARSE(1000, 5000)(tonumber(arg and arg[1]) or 150000)
