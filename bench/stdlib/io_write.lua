-- io.write throughput: large chunks to stdout.
--
-- Writes N chunks of 4 KiB through `io.write`. The chunk is built once, so the
-- loop measures the write path (host call + copy into the stdout buffer +
-- the syscalls that drain it), not string building. Output is the chunks
-- themselves, deterministic and byte-identical to LuaJIT and across tiers.
--
--   mahina              bench/stdlib/io_write.lua 25000   # tier-0
--   mahina --jit-native bench/stdlib/io_write.lua 25000   # tier-1b
--   luajit              bench/stdlib/io_write.lua 25000   # reference
--
-- @bench args="25000" luajit=compatible

local N = tonumber(arg and arg[1]) or 25000
local chunk = string.rep("0123456789abcdef", 255) .. "0123456789abcde\n"
for _ = 1, N do
  io.write(chunk)
end
