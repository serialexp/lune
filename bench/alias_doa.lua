-- Minimal DOA-guard repro: two SSA paths to the SAME table in one flat loop.
local a = { v = 0 }
local t = { a, a }
local acc = 0
for i = 1, 100000 do
  t[1].v = t[1].v + 1
  acc = acc + t[2].v
end
print(acc)
