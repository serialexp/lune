-- f:read("a") of a 100 MB text file: one bulk read into one string.
--
-- Doc 65 §9: the budget allows one UTF-8 validation pass over the bytes.
--
--   mahina              bench/stdlib/io_read_all.lua   # tier-0
--   luajit              bench/stdlib/io_read_all.lua   # reference
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

local f = io.open(path)
local s = f:read("a")
f:close()
print(#s)
