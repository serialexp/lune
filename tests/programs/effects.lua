-- Effects (doc 86 P1 corpus): math.random's seed and os.clock go through the
-- effect log, so a resumed run must replay them where the recording read them.
local rolls = {}
for _ = 1, 6 do
    rolls[#rolls + 1] = math.random(1, 6)
end
print("rolls", table.concat(rolls, " "))

local t0 = os.clock()
local s = 0
for i = 1, 50 do
    s = s + i
end
local t1 = os.clock()
print("clock", s, t1 > t0)

local samples = {}
for _ = 1, 4 do
    samples[#samples + 1] = string.format("%.6f", os.clock())
end
print("samples", table.concat(samples, " "))
print("float", math.random() < 1)
