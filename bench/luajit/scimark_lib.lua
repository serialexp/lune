------------------------------------------------------------------------------
-- Lua SciMark (2010-03-15).
--
-- A literal translation of SciMark 2.0a, written in Java and C.
-- Credits go to the original authors Roldan Pozo and Bruce Miller.
-- See: http://math.nist.gov/scimark2/
------------------------------------------------------------------------------


local SCIMARK_VERSION = "2010-03-15"

local RANDOM_SEED = 101009 -- Must be odd.

local abs, log, sin, floor = math.abs, math.log, math.sin, math.floor
local pi, clock = math.pi, os.clock

local benchmarks = {}

-- ### lune-local edit 2 of 2 (2026-08-26): a result checksum.
--
-- Upstream's kernels return a flop count that the wrappers discard, so these
-- four benches printed NOTHING. That made their frozen-output digest sha256("")
-- and made `bench/run.py`'s cross-tier check compare "" == "" == "" while
-- reporting `cross=ok` — on precisely the float/array workloads lune's JIT
-- leans on hardest. `benchmarks.checksum()` closes that: each kernel records
-- its result state here, and the wrapper prints a fold of it after the run.
--
-- WHY AN INTEGER FOLD AND NOT `string.format("%.17g", ...)`: when this was
-- written lune's `string.format` could not render a double's exact decimal
-- expansion (`%.17g` of 1/3 gave `0.3333333333333333` where C gives
-- `0.33333333333333331`), so a high-precision float print would have differed
-- between the engines for formatting reasons alone — masking or faking a real
-- numeric difference. That is fixed (`src/stdlib/decimal.zig` converts
-- exactly, verified byte-identical to glibc over 1.08M formats), so a `%.17g`
-- checksum would now agree. The fold is kept anyway, because it depends on no
-- formatting behaviour whatsoever: it compares the NUMBERS, so a future
-- rendering change cannot quietly weaken this oracle.
-- The fold below touches no float formatting at all:
--   * `x % 1` is exact;
--   * scaling by 2^52 is exact (power of two), and the product is < 2^52, so
--     `floor` recovers EVERY fraction bit — the fold is 1-ulp sensitive;
--   * every intermediate stays under 2^53, so it is exact both in LuaJIT's
--     doubles and in Lua 5.4's integers, and `%d` renders it identically.
-- KNOWN LIMIT (2026-08-27, deliberate): for LU and SPARSE the checksum is
-- cycle-count-insensitive — LU re-factors a fresh copy of the same matrix
-- each cycle and SPARSE overwrites `vy` each cycle, so the folded final state
-- witnesses the LAST cycle's arithmetic only and the ×cycles repetition is
-- semantically dead (FFT and SOR accumulate across cycles and are fully
-- sensitive). That is upstream scimark's own shape, it is not a correctness
-- hole (output equivalence is the contract), and it only becomes a benchmark-
-- validity problem if an engine ever learns to elide the dead repetition —
-- which would show up as an absurd step-change in these two board rows long
-- before it fooled anyone. Details + the fix-if-ever-needed in TODO.md
-- ("Weak-but-nonzero bench output coverage").
local ck_state = nil

local function ck_fold(acc, x)
  local ip = x - (x % 1)
  local fb = floor((x % 1) * 2^52)
  acc = (acc * 1000003 + ip) % 2147483647
  acc = (acc * 1000003 + fb) % 2147483647
  return acc
end

-- Folds whatever the most recently constructed kernel left behind. Reads the
-- state THROUGH the stored container rather than over pre-resolved rows: LU's
-- `lu_factor` pivots by swapping row references (`a[j], a[jp] = a[jp], a[j]`),
-- so a row list captured at construction time would checksum the wrong rows.
function benchmarks.checksum()
  local s = ck_state
  if not s then return "checksum: no kernel constructed" end
  local acc = 0
  if s.vec then
    local v = s.vec
    for i = 1, s.n do acc = ck_fold(acc, v[i]) end
  else
    local m = s.mat
    for y = 1, s.n do
      local row = m[y]
      for x = 1, s.n do acc = ck_fold(acc, row[x]) end
    end
  end
  return string.format("%s checksum: %d", s.name, acc)
end

------------------------------------------------------------------------------
-- This is a Lagged Fibonacci Pseudo-random Number Generator with
-- j, k, M = 5, 17, 31. Pretty weak, but same as C/Java SciMark.
------------------------------------------------------------------------------

local rand, rand_init

-- ### lune-local edit 1 of 2 (2026-08-26). Upstream reads:
--       if jit and jit.status and jit.status() then
-- The two branches below are NOT equivalent generators. They agree on their
-- first value and then diverge (verified: element 2 differs by 1, and the
-- sequences drift apart from there). Upstream never noticed because nothing
-- compares the two engines' numeric output — the four scimark benches print
-- nothing at all.
--
-- lune's bench suite DOES compare them: `bench/run.py` asserts lune's stdout
-- equals LuaJIT's for every `luajit=compatible` program. With the branch live,
-- LuaJIT takes the `bit` path and lune the portable one, so the engines run
-- these kernels on DIFFERENT INPUT DATA and byte-parity is not merely absent
-- but unreachable. Forcing the portable branch makes all four kernels agree
-- with LuaJIT bit-for-bit.
--
-- This is free: `rand` is called only by `random_vector`/`random_matrix` at
-- kernel-construction time, never inside a timed loop, for FFT/SOR/SPARSE/LU.
-- Measured on LuaJIT at bench sizes: sor -0.8%, lu -1.8% (i.e. noise). Only
-- `benchmarks.MC` calls `rand` in its hot loop, and MC is not one of our benches.
-- The `bit` branch is kept intact rather than deleted so the diff against
-- upstream stays one line.
if false and jit and jit.status and jit.status() then
  -- LJ2 has bit operations and zero-based arrays (internally).
  local bit = require("bit")
  local band, sar = bit.band, bit.arshift
  local Rm, Rj, Ri = {}, 0, 0
  for i=0,16 do Rm[i] = 0 end
  function rand_init(seed)
    Rj, Ri = 16, 11
    for i=16,0,-1 do
      seed = band(seed*9069, 0x7fffffff)
      Rm[i] = seed
    end
  end
  function rand()
    local i = band(Ri+1, sar(Ri-16, 31))
    local j = band(Rj+1, sar(Rj-16, 31))
    Ri, Rj = i, j
    local k = band(Rm[i] - Rm[j], 0x7fffffff)
    Rm[j] = k
    return k * (1.0/2147483647.0)
  end
else
  -- Better for standard Lua with one-based arrays and without bit operations.
  local Rm, Rj = {}, 1
  for i=1,17 do Rm[i] = 0 end
  function rand_init(seed)
    Rj = 1
    for i=17,1,-1 do
      seed = (seed*9069) % (2^31)
      Rm[i] = seed
    end
  end
  function rand()
    local j, m = Rj, Rm
    local h = j - 5
    if h < 1 then h = h + 17 end
    local k = m[h] - m[j]
    if k < 0 then k = k + 2147483647 end
    m[j] = k
    if j < 17 then Rj = j + 1 else Rj = 1 end
    return k * (1.0/2147483647.0)
  end
end

local function random_vector(n)
  local v = {}
  for x=1,n do v[x] = rand() end
  return v
end

local function random_matrix(m, n)
  local a = {}
  for y=1,m do
    local v = {}
    a[y] = v
    for x=1,n do v[x] = rand() end
  end
  return a
end

------------------------------------------------------------------------------
-- FFT: Fast Fourier Transform.
------------------------------------------------------------------------------

local function fft_bitreverse(v, n)
  local j = 0
  for i=0,2*n-4,2 do
    if i < j then
      v[i+1], v[i+2], v[j+1], v[j+2] = v[j+1], v[j+2], v[i+1], v[i+2]
    end
    local k = n
    while k <= j do j = j - k; k = k / 2 end
    j = j + k
  end
end

local function fft_transform(v, n, dir)
  if n <= 1 then return end
  fft_bitreverse(v, n)
  local dual = 1
  repeat
    local dual2 = 2*dual
    for i=1,2*n-1,2*dual2 do
      local j = i+dual2
      local ir, ii = v[i], v[i+1]
      local jr, ji = v[j], v[j+1]
      v[j], v[j+1] = ir - jr, ii - ji
      v[i], v[i+1] = ir + jr, ii + ji
    end
    local theta = dir * pi / dual
    local s, s2 = sin(theta), 2.0 * sin(theta * 0.5)^2
    local wr, wi = 1.0, 0.0
    for a=3,dual2-1,2 do
      wr, wi = wr - s*wi - s2*wr, wi + s*wr - s2*wi
      for i=a,a+2*(n-dual2),2*dual2 do
	local j = i+dual2
	local jr, ji = v[j], v[j+1]
	local dr, di = wr*jr - wi*ji, wr*ji + wi*jr
	local ir, ii = v[i], v[i+1]
	v[j], v[j+1] = ir - dr, ii - di
	v[i], v[i+1] = ir + dr, ii + di
      end
    end
    dual = dual2
  until dual >= n
end

function benchmarks.FFT(n)
  local l2n = log(n)/log(2)
  if l2n % 1 ~= 0 then
    io.stderr:write("Error: FFT data length is not a power of 2\n")
    os.exit(1)
  end
  local v = random_vector(n*2)
  ck_state = { name = "FFT", vec = v, n = n*2 } -- lune-local
  return function(cycles)
    local norm = 1.0 / n
    for p=1,cycles do
      fft_transform(v, n, -1)
      fft_transform(v, n, 1)
      for i=1,n*2 do v[i] = v[i] * norm end
    end
    return ((5*n-2)*l2n + 2*(n+1)) * cycles
  end
end

------------------------------------------------------------------------------
-- SOR: Jacobi Successive Over-Relaxation.
------------------------------------------------------------------------------

local function sor_run(mat, m, n, cycles, omega)
  local om4, om1 = omega*0.25, 1.0-omega
  m = m - 1
  n = n - 1
  for i=1,cycles do
    for y=2,m do
      local v, vp, vn = mat[y], mat[y-1], mat[y+1]
      for x=2,n do
	v[x] = om4*((vp[x]+vn[x])+(v[x-1]+v[x+1])) + om1*v[x]
      end
    end
  end
end

function benchmarks.SOR(n)
  local mat = random_matrix(n, n)
  ck_state = { name = "SOR", mat = mat, n = n } -- lune-local
  return function(cycles)
    sor_run(mat, n, n, cycles, 1.25)
    return (n-1)*(n-1)*cycles*6
  end
end

------------------------------------------------------------------------------
-- MC: Monte Carlo Integration.
------------------------------------------------------------------------------

local function mc_integrate(cycles)
  local under_curve = 0
  local rand = rand
  for i=1,cycles do
    local x = rand()
    local y = rand()
    if x*x + y*y <= 1.0 then under_curve = under_curve + 1 end
  end
  return (under_curve/cycles) * 4
end

function benchmarks.MC()
  return function(cycles)
    local res = mc_integrate(cycles)
    assert(math.sqrt(cycles)*math.abs(res-math.pi) < 5.0, "bad MC result")
    return cycles * 4 -- Way off, but same as SciMark in C/Java.
  end
end

------------------------------------------------------------------------------
-- Sparse Matrix Multiplication.
------------------------------------------------------------------------------

local function sparse_mult(n, cycles, vy, val, row, col, vx)
  for p=1,cycles do
    for r=1,n do
      local sum = 0
      for i=row[r],row[r+1]-1 do sum = sum + vx[col[i]] * val[i] end
      vy[r] = sum
    end
  end
end

function benchmarks.SPARSE(n, nz)
  local nr = floor(nz/n)
  local anz = nr*n
  local vx = random_vector(n)
  local val = random_vector(anz)
  local vy, col, row = {}, {}, {}
  ck_state = { name = "SPARSE", vec = vy, n = n } -- lune-local
  row[1] = 1
  for r=1,n do
    local step = floor(r/nr)
    if step < 1 then step = 1 end
    local rr = row[r]
    row[r+1] = rr+nr
    for i=0,nr-1 do col[rr+i] = 1+i*step end
  end
  return function(cycles)
    sparse_mult(n, cycles, vy, val, row, col, vx)
    return anz*cycles*2
  end
end

------------------------------------------------------------------------------
-- LU: Dense Matrix Factorization.
------------------------------------------------------------------------------

local function lu_factor(a, pivot, m, n)
  local min_m_n = m < n and m or n
  for j=1,min_m_n do
    local jp, t = j, abs(a[j][j])
    for i=j+1,m do
      local ab = abs(a[i][j])
      if ab > t then
	jp = i
	t = ab
      end
    end
    pivot[j] = jp
    if a[jp][j] == 0 then error("zero pivot") end
    if jp ~= j then a[j], a[jp] = a[jp], a[j] end
    if j < m then
      local recp = 1.0 / a[j][j]
      for k=j+1,m do
        local v = a[k]
	v[j] = v[j] * recp
      end
    end
    if j < min_m_n then
      for i=j+1,m do
	local vi, vj = a[i], a[j]
	local eij = vi[j]
	for k=j+1,n do vi[k] = vi[k] - eij * vj[k] end
      end
    end
  end
end

local function matrix_alloc(m, n)
  local a = {}
  for y=1,m do a[y] = {} end
  return a
end

local function matrix_copy(dst, src, m, n)
  for y=1,m do
    local vd, vs = dst[y], src[y]
    for x=1,n do vd[x] = vs[x] end
  end
end

function benchmarks.LU(n)
  local mat = random_matrix(n, n)
  local tmp = matrix_alloc(n, n)
  local pivot = {}
  -- lune-local. `tmp` is the FACTORED copy, and `lu_factor` pivots by swapping
  -- row references inside it — which is exactly why `checksum()` re-reads the
  -- rows through `mat` rather than caching them here.
  ck_state = { name = "LU", mat = tmp, n = n }
  return function(cycles)
    for i=1,cycles do
      matrix_copy(tmp, mat, n, n)
      lu_factor(tmp, pivot, n, n)
    end
    return 2.0/3.0*n*n*n*cycles
  end
end

rand_init(RANDOM_SEED)

return benchmarks
