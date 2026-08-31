-- table library throughput + LuaJIT parity probe.
--
-- Builds a fresh array each iteration with table.insert (append and positional),
-- removes from the head, joins with table.concat, and copies a range with
-- table.move. Integer checksum keeps output deterministic and byte-identical to
-- LuaJIT. (table.pack/unpack live in lua54.lua — Lua 5.4 surface LuaJIT lacks.)
--
--   mahina              bench/stdlib/tbl_ops.lua 20000   # tier-0
--   mahina --jit-native bench/stdlib/tbl_ops.lua 20000   # tier-1b
--   luajit              bench/stdlib/tbl_ops.lua 20000   # reference
--
-- @bench args="20000" luajit=compatible

local insert, remove, concat, move = table.insert, table.remove, table.concat, table.move

local function run(n)
  local acc = 0
  for i = 1, n do
    local t = {}
    for j = 1, 10 do insert(t, j * 2) end   -- append 2,4,...,20
    insert(t, 2, 99)                         -- positional insert
    remove(t, 1)                             -- remove head
    local s = concat(t, ",")
    acc = acc + #s
    move(t, 1, 3, 8)                         -- copy [1..3] over [8..10]
    acc = acc + t[8] + t[9] + t[10]
  end
  return acc
end

local N = tonumber(arg and arg[1]) or 20000
io.write(string.format("acc=%d\n", run(N)))
