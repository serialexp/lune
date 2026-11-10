-- @bench args="200000" luajit=compatible
-- Field reads and overwrites on objects that carry a metatable (doc 77
-- Phase 1): `p.x`, `p.vx` are present keys, so neither access consults the
-- metatable, but today any metatable stops the recording.
local Particle = {}
Particle.__index = Particle

local ps = {}
for i = 1, 64 do
    ps[i] = setmetatable({ x = i * 7 % 1000, vx = i % 5 - 2 }, Particle)
end

local function step(p)
    local x = p.x + p.vx
    if x < 0 or x > 1000 then
        p.vx = -p.vx
        x = p.x + p.vx
    end
    p.x = x
end

local n = tonumber(arg[1])
for _ = 1, n do
    for i = 1, #ps do
        step(ps[i])
    end
end

local s = 0
for i = 1, #ps do
    s = s + ps[i].x * i
end
print(s)
