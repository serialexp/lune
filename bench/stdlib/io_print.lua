-- print throughput: many short lines to stdout.
--
-- Each `print` is one host call writing a short line. Before doc 65 Phase 0
-- every call flushed stdout (one write syscall per line); with the C-stdio
-- policy stdout is fully buffered when it is not a terminal (the harness reads
-- it through a pipe), so this measures the per-call cost, not syscalls.
-- Output is the lines themselves, so it is deterministic and byte-identical to
-- LuaJIT (and across all of mahina's tiers).
--
--   mahina              bench/stdlib/io_print.lua 1000000   # tier-0
--   mahina --jit-native bench/stdlib/io_print.lua 1000000   # tier-1b
--   luajit              bench/stdlib/io_print.lua 1000000   # reference
--
-- @bench args="1000000" luajit=compatible

local N = tonumber(arg and arg[1]) or 1000000
for i = 1, N do
  print(i, i * 3)
end
