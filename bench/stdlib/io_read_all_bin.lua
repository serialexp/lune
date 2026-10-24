-- f:read("a") of a 100 MB file in `rb` mode: mahina returns a byte array
-- (an integer table packed in the `u8` lane, doc 65 Q1), LuaJIT a string;
-- `#` is the byte count in both.
--
--   mahina              bench/stdlib/io_read_all_bin.lua   # tier-0
--   luajit              bench/stdlib/io_read_all_bin.lua   # reference
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

local f = io.open(path, "rb")
local b = f:read("a")
f:close()
print(#b)
