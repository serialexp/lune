-- @bench args="80" luajit=compatible name=array3d
-- From LuaJIT/bench/array3d.lua (Computer Language Benchmarks Game port).
-- lune-added: this header and the trailing checksum block. The body is upstream.
--
-- WHY THE CHECKSUM. Upstream prints nothing, so this bench's frozen-output
-- digest was sha256("") and `bench/run.py`'s cross-tier check was comparing
-- "" == "" == "" while reporting `cross=ok`. The lone `assert` below pins
-- exactly one element out of dim^3.
--
-- COST, deliberately accepted (Bart, 2026-08-26): the fold walks all 512,000
-- elements, and it does not tier up — measured 49.8 ms under both tier-0 and
-- --jit-native. Measured effect on this row:
--
--            lune t0   lune jit   LuaJIT   jit/lj
--   before     172.1      177.9      1.9    95.8x
--   after      226.1      225.6      8.3    27.1x
--
-- Note the ratio MOVED A LOT, and in the flattering direction: the fold costs
-- LuaJIT +6.5 ms against a 1.9 ms baseline (+348%) but lune only +48 ms (+27%),
-- so array3d went from the worst row on the board to a middling one. Both
-- engines run the identical added work, so 27.1x is a true measurement — it is
-- just a measurement of a different mixture (~21% of the row is now checksum).
-- Read it that way; don't read the step at 2026-08-26 as an optimization.
-- Pre-change baselines are in bench/results/ up to 20260825-181602.
--
-- The alternative on the table was a strided sample at negligible cost,
-- rejected in favour of catching a single wrong element anywhere in the array.

local function array_set(self, x, y, z, p)
  assert(x >= 0 and x < self.nx, "x outside PA")
  assert(y >= 0 and y < self.ny, "y outside PA")
  assert(z >= 0 and z < self.nz, "z outside PA")
  local pos = (z*self.ny + y)*self.nx + x
  local image = self.image
  if self.packed then
    local maxv = self.max_voltage
    if p > maxv then self.max_voltage = p*2.0 end
    local oldp = image[pos] or 0.0 -- Works with uninitialized table, too
    if oldp > maxv then p = p + maxv*2.0 end
    image[pos] = p
  else
    image[pos] = p
  end
  self.changed = true
  self.changed_recently = true
end

local function array_points(self)
  local y, z = 0, 0
  return function(self, x)
    x = x + 1
    if x >= self.nx then
      x = 0
      y = y + 1
      if y >= self.ny then
	y = 0
	z = z + 1
	if z >= self.nz then
	  return nil, nil, nil
	end
      end
    end
    return x, y, z
  end, self, 0
end

local function array_new(nx, ny, nz, packed)
  return {
    nx = nx, ny = ny, nz = nz,
    packed = packed, max_voltage = 0.0,
    changed = false, changed_recently = false,
    image = {}, -- Preferably use a fixed-type, pre-sized array here.
    set = array_set,
    points = array_points,
  }
end

local dim = tonumber(arg and arg[1]) or 300 -- Array dimension dim^3
local packed = arg and arg[2] == "packed"   -- Packed image or flat
local arr = array_new(dim, dim, dim, packed)

for x,y,z in arr:points() do
  arr:set(x, y, z, x*x)
end
assert(arr.image[dim^3-1] == (dim-1)^2)

-- lune-added result checksum. Exact integer fold, no float formatting. When
-- this was written lune's string.format could not render a double's exact
-- decimal expansion, so a "%.17g" print would have differed from LuaJIT's for
-- formatting reasons alone; that is fixed (src/stdlib/decimal.zig) and a
-- formatted checksum would now agree. The fold is kept because it depends on
-- no formatting behaviour at all — it compares the NUMBERS, so it cannot be
-- silently weakened by a future rendering change.
-- `x % 1` is exact, scaling by 2^52 is exact, and
-- every intermediate stays under 2^53 — so this is 1-ulp sensitive and renders
-- identically under LuaJIT's doubles and Lua 5.4's integers.
--
-- The nil arm is load-bearing, not defensive: `array_points` starts its control
-- variable at 0 and pre-increments, so it never emits (0,0,0) and image[0] is
-- permanently unset (verified: 26 of 27 populated at dim=3). Folding a sentinel
-- and printing the populated count pins that hole rather than skipping past it,
-- so a change in the iterator's coverage shows up here.
local floor = math.floor
local acc, populated = 0, 0
local image = arr.image
for i = 0, dim^3 - 1 do
  local x = image[i]
  if x == nil then
    acc = (acc * 1000003 + 1) % 2147483647
  else
    populated = populated + 1
    local ip = x - (x % 1)
    local fb = floor((x % 1) * 2^52)
    acc = (acc * 1000003 + ip) % 2147483647
    acc = (acc * 1000003 + fb) % 2147483647
  end
end
print(string.format("array3d checksum: %d  populated: %d/%d  max_voltage: %d",
                    acc, populated, dim^3, arr.max_voltage))

