-- Reduced advance:4-shaped variable-trip numeric nest (doc 50 diagnosis
-- instrument). Same decomposition shape as nbody's advance: outer numeric
-- loop carrying locals, inner numeric loop with shrinking trip count
-- (j = i+1..n), hash-field reads in the inner body, writeback after.
local N = 5

local bodies = {}
for i = 1, N do
  bodies[i] = { x = i * 1.0, v = 0.0 }
end

local function advance(bodies, n, dt)
  for i = 1, n do
    local bi = bodies[i]
    local bx, bv = bi.x, bi.v
    for j = i + 1, n do
      local bj = bodies[j]
      local d = bx - bj.x
      bv = bv - d * dt
      bj.v = bj.v + d * dt
    end
    bi.v = bv
    bi.x = bx + dt * bv
  end
end

local iters = tonumber(arg and arg[1]) or 50000
for k = 1, iters do
  advance(bodies, N, 0.001)
end

local s = 0
for i = 1, N do
  s = s + i * bodies[i].x + (i * i) * bodies[i].v
end
print(string.format("%0.9f", s))
