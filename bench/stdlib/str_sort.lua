-- Sorting strings that share long prefixes, as file paths and namespaced
-- keys do: every `<` compares tens of equal bytes before the first
-- difference (`bytes.order`; `std.mem.order` took ~10 instructions a byte).
-- Prints a checksum of the sorted order, byte-identical to LuaJIT.
--
--   mahina              bench/stdlib/str_sort.lua 20000   # tier-0
--   mahina --jit-native bench/stdlib/str_sort.lua 20000   # tier-1b
--   luajit              bench/stdlib/str_sort.lua 20000   # reference
--
-- @bench args="20000" luajit=compatible

local N = tonumber(arg and arg[1]) or 20000

local dirs = { "assets/textures/terrain/", "assets/textures/characters/",
  "assets/sounds/ambient/forest/", "src/game/systems/physics/" }
local paths = {}
for i = 1, N do
  local k = (i * 7919) % N
  paths[i] = "/home/user/projects/example/" .. dirs[k % 4 + 1] .. "file-" .. tostring(k) .. ".dat"
end

local acc = 0
for round = 1, 3 do
  local t = {}
  for i = 1, N do t[i] = paths[(i + round * 4099) % N + 1] end
  table.sort(t)
  for i = 1, N, 97 do acc = (acc * 31 + #t[i] + i) % 1000000007 end
end
print(acc)
