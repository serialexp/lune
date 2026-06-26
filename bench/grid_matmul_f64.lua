-- Floating-point dense matrix multiply — the **f64 grid-flattening** benchmark
-- (doc 14, `docs/design/14-nested-array-flattening.md`). The float twin of
-- `grid_matmul.lua`: three N×N matrices held as nested Lua tables (`a[i][j]`)
-- whose cells are **doubles**, so once a fused `a[i][j]=v` store inflates each
-- matrix it becomes a flat row-major grid at the **f64** element lane. The hot
-- inner product `s = s + A[i][k] * B[k][j]` and the store `C[i][j] = s` then
-- read/write f64 grid cells through fused `get_index2`/`set_index2`.
--
-- Why it exists: int grid cells lower to native in Phase 8 Stage B; this bench
-- is the yardstick for the **f64 cell** extension (XMM `movsd` cell load/store
-- behind the same grid guards). A double grid that records but bails native runs
-- on the tier-1a oracle (≈ tier-0); a fully-lowered one cashes the locality win
-- in XMM. Output is byte-identical across lune tier-0 / `--jit-native` / LuaJIT
-- (strict IEEE-754, round-to-nearest — lune never changes MXCSR).
--
-- Rows are made dense f64 arrays (`r[j] = 0.0`) *before* the first fused store so
-- the inflation scan unifies the cell lane to f64 (homogeneous-numeric, doc 14).
--
-- Run head-to-head:
--   lune                 bench/grid_matmul_f64.lua 200   # tier-0
--   lune --jit-native    bench/grid_matmul_f64.lua 200   # tier-1b (native x64, XMM cells)
--   lune --dump-aborts   bench/grid_matmul_f64.lua 200   # confirm no get_index2/set_index2 aborts
--   luajit               bench/grid_matmul_f64.lua 200   # reference
--
-- @bench args="200" luajit=compatible name=grid_matmul_f64

-- Build an N×N matrix of doubles as a nested table, then inflate it to an f64
-- grid by filling every cell with a deterministic fractional pattern through a
-- fused store.
local function mat(n, seed)
  local m = {}
  for i = 1, n do
    local r = {}
    for j = 1, n do r[j] = 0.0 end   -- dense f64 row (bare store → f64 array part)
    m[i] = r
  end
  for i = 1, n do
    for j = 1, n do
      m[i][j] = ((i * 31 + j * 17 + seed) % 100) * 0.5 + 0.25   -- first fused store → f64 grid
    end
  end
  return m
end

local N = tonumber(arg and arg[1]) or 200
if N < 1 then N = 1 end

local A = mat(N, 1)
local B = mat(N, 2)
local C = mat(N, 0)

for i = 1, N do
  for j = 1, N do
    local s = 0.0
    for k = 1, N do
      s = s + A[i][k] * B[k][j]   -- fused f64 grid reads (get_index2)
    end
    C[i][j] = s                   -- fused f64 grid write (set_index2)
  end
end

local sum = 0.0
for i = 1, N do
  for j = 1, N do
    sum = sum + C[i][j]
  end
end
io.write(string.format("grid_matmul_f64 N=%d checksum=%.4f\n", N, sum))
