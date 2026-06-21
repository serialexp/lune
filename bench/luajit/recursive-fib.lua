-- @bench args="31" luajit=compatible name=recursive-fib
-- Vendored verbatim from LuaJIT/bench/recursive-fib.lua (Computer Language
-- Benchmarks Game port). Only this header is lune-added.
local function fib(n)
  if n < 2 then return 1 end
  return fib(n-2) + fib(n-1)
end

local n = tonumber(arg[1]) or 10
io.write(string.format("Fib(%d): %d\n", n, fib(n)))
