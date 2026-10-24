-- io.lines throughput: iterate a 100 MB, 1 M-line file line by line.
--
-- Doc 65 §9: `for l in io.lines(f)` over the file, against `lua5.4`/LuaJIT.
-- The loop counts lines and characters, so it measures the read path (host
-- fill + line split + UTF-8 check + string interning), not string work.
--
--   mahina              bench/stdlib/io_lines.lua   # tier-0
--   mahina --jit-native bench/stdlib/io_lines.lua   # tier-1b
--   luajit              bench/stdlib/io_lines.lua   # reference
--
-- @bench args="1000000" luajit=compatible
-- The input: 1 M lines of 100 bytes (100 MB of ASCII), created on first use
-- at a fixed path (arg[2]) and reused while its size matches, so the timed
-- runs only read. ASCII keeps the output identical to LuaJIT's.
local N = tonumber(arg and arg[1]) or 1000000
local path = (arg and arg[2]) or "/tmp/mahina-bench-lines.txt"
local function ensure()
  -- mahina raises on a missing file, Lua returns nil: pcall covers both.
  local ok, f = pcall(io.open, path, "rb")
  if ok and f then
    local size = f:seek("end")
    f:close()
    if size == N * 100 then return end
  end
  local w = io.open(path, "w")
  local pad = string.rep("x", 91)
  for i = 1, N do
    w:write(string.format("%07d ", i), pad, "\n")
  end
  w:close()
end
ensure()

local lines, chars = 0, 0
for l in io.lines(path) do
  lines = lines + 1
  chars = chars + #l
end
print(lines, chars)
