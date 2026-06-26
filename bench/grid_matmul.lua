-- Integer dense matrix multiply — the **grid-flattening** benchmark (doc 14,
-- `docs/design/14-nested-array-flattening.md`). Three N×N integer matrices held
-- as nested Lua tables (`a[i][j]`). Once each matrix is touched by a fused
-- `a[i][j]=v` store it **inflates to a flat row-major grid** (Phase 4); the hot
-- inner product `s = s + A[i][k] * B[k][j]` and the result store `C[i][j] = s`
-- then read/write grid cells through fused `get_index2`/`set_index2`.
--
-- Why the benchmark exists: it is the workload the grid optimisation is *for* —
-- a dense 2-D numeric kernel with `a[i][j]` locality. Through Phase 7 the
-- representation is correct (grids inflate, mutate, GC-survive, and round-trip
-- through keyframes deterministically) but the trace recorder still aborts on
-- `get_index2`/`set_index2` (`nyi_opcode`), so every matrix op runs on the
-- tier-0 interpreter — confirm with `--dump-aborts`. Phase 8 teaches the recorder
-- to lower a fused grid access to grid-relative address arithmetic
-- (`base + (i*stride + j)` at the cell lane) behind a `guard_grid`, which is where
-- the locality win is finally cashed. This bench is the before/after yardstick.
--
-- INTEGER cells on purpose: lune's tier-1b backend is int/bool-only today (no XMM
-- float store/load), so an int grid is what the native path can lower first
-- (Phase 8 "int lanes first"). A float matmul would bail on the cell lane until a
-- later phase, masking the grid win.
--
-- Run head-to-head:
--   lune                 bench/grid_matmul.lua 200   # tier-0 (bytecode interp)
--   lune --jit-native    bench/grid_matmul.lua 200   # tier-1b (native x64)
--   lune --dump-aborts   bench/grid_matmul.lua 200   # see get_index2/set_index2 aborts
--   luajit               bench/grid_matmul.lua 200   # reference
-- Output is byte-identical across all of them (and to LuaJIT).
--
-- @bench args="200" luajit=compatible name=grid_matmul

-- Build an N×N matrix as a nested table, then inflate it to a grid by filling
-- every cell with a deterministic pattern through a fused store. The rows are
-- made dense (a contiguous int array part) *before* the first fused store so the
-- inflation scan accepts them (homogeneous-numeric precondition, doc 14).
local function mat(n, seed)
  local m = {}
  for i = 1, n do
    local r = {}
    for j = 1, n do r[j] = 0 end   -- dense int row (bare store fills the array part)
    m[i] = r
  end
  for i = 1, n do
    for j = 1, n do
      m[i][j] = (i * 31 + j * 17 + seed) % 100   -- first fused store inflates m to a grid
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
    local s = 0
    for k = 1, N do
      s = s + A[i][k] * B[k][j]   -- fused grid reads (get_index2)
    end
    C[i][j] = s                   -- fused grid write (set_index2)
  end
end

local sum = 0
for i = 1, N do
  for j = 1, N do
    sum = sum + C[i][j]
  end
end
io.write(string.format("grid_matmul N=%d checksum=%d\n", N, sum))
