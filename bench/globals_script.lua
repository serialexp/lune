-- Script-style code: a game tick written the way scripts usually are, with
-- its configuration, state, counters and functions all globals and the
-- stdlib reached through the global `math`. Every tick reads global
-- constants, calls global functions, updates global counters
-- (`G = G + 1`), and goes through the global RNG, whose seed is a global
-- store per call. Entities bounce, lose health and are replaced, so
-- tables churn too. Integer checksum, byte-identical to LuaJIT (the RNG
-- stays below 2^53).
--
--   mahina              bench/globals_script.lua 50000   # tier-0
--   mahina --jit-native bench/globals_script.lua 50000   # tier-1b
--   luajit              bench/globals_script.lua 50000   # reference
--
-- @bench args="50000" luajit=compatible

TICKS = tonumber(arg and arg[1]) or 50000
WIDTH = 640
HEIGHT = 480
MAX_ENTITIES = 48
PROBES = 6
REACH = 24

seed = 42
frame = 0
spawned = 0
removed = 0
bounces = 0
hits = 0
score = 0
entities = {}

function rand(n)
  seed = (seed * 16807) % 2147483647
  return seed % n
end

function spawn()
  entities[#entities + 1] = {
    x = rand(WIDTH), y = rand(HEIGHT),
    dx = rand(9) - 4, dy = rand(9) - 4,
    hp = 2 + rand(4),
  }
  spawned = spawned + 1
end

function clamp(v, lo, hi)
  return math.max(lo, math.min(hi, v))
end

function bounce(e)
  bounces = bounces + 1
  e.hp = e.hp - 1
end

function move(e)
  e.x = e.x + e.dx
  e.y = e.y + e.dy
  if e.x < 0 or e.x >= WIDTH then
    e.dx = -e.dx
    e.x = clamp(e.x, 0, WIDTH - 1)
    bounce(e)
  end
  if e.y < 0 or e.y >= HEIGHT then
    e.dy = -e.dy
    e.y = clamp(e.y, 0, HEIGHT - 1)
    bounce(e)
  end
end

function near(a, b)
  return math.abs(a.x - b.x) + math.abs(a.y - b.y) < REACH
end

function collide()
  local n = #entities
  if n < 2 then return end
  for _ = 1, PROBES do
    local a = entities[rand(n) + 1]
    local b = entities[rand(n) + 1]
    if a ~= b and near(a, b) then
      hits = hits + 1
      a.hp = a.hp - 1
      score = (score + frame * 7 + math.floor(a.x / 3)) % 1000000007
    end
  end
end

function reap()
  local i = 1
  while i <= #entities do
    if entities[i].hp <= 0 then
      entities[i] = entities[#entities]
      entities[#entities] = nil
      removed = removed + 1
    else
      i = i + 1
    end
  end
end

function tick()
  frame = frame + 1
  if #entities < MAX_ENTITIES and rand(3) == 0 then spawn() end
  for i = 1, #entities do move(entities[i]) end
  collide()
  reap()
end

for _ = 1, TICKS do tick() end

local pos = 0
for i = 1, #entities do
  pos = (pos + entities[i].x * 31 + entities[i].y) % 1000000007
end
print(frame, spawned, removed, bounces, hits, score, pos)
