-- Hash-part field get/set micro-benchmark — the tier-1b *string-keyed field*
-- native-codegen benchmark (Hash phase H1). This is the isolation bench for the
-- `obj.field` recorder+lowering lever: a constant string key resolves to a
-- loop-invariant value-cell pointer that the native prologue hoists, exactly
-- like the array base pointer.
--
-- Why the variant exists: the JIT recorder historically aborted every `obj.field`
-- access because `get_index`/`set_index` with a *string* key fell outside the
-- integer-array fast path. H0 added the `href`/`hload`/`hstore`/`guard_hash`
-- recorder + tier-1a oracle; H1 lowers them to native. The hot loop here is pure
-- field RMW (`t.x = t.x + t.y`) plus field reads — no array, no host calls — so
-- it isolates the hash-field path with nothing else to abort on.
--
-- Run head-to-head:
--   lune                 bench/field_hash.lua 20000000   # tier-0 (bytecode interp)
--   lune --trace         bench/field_hash.lua 20000000   # tier-1a (IR interp)
--   lune --jit-native    bench/field_hash.lua 20000000   # tier-1b (native x64)
--   lune --dump-native   bench/field_hash.lua 20000000   # confirm the trace compiles
--   luajit               bench/field_hash.lua 20000000   # reference
-- Output is byte-identical across all four (and to LuaJIT).
--
-- @bench args="20000000" luajit=compatible

-- The body is a single field RMW that also reads a second field: every hash
-- load precedes the (single, deferred) store, so the C1 store-sink discipline is
-- satisfied and the loop records + lowers to native. `t.x` is the accumulator
-- cell, `t.y` an invariant field read — both resolve to hoisted value-cell
-- pointers in the native prologue.
local function run(t, n)
  for _ = 1, n do
    t.x = t.x + t.y
  end
  return t.x
end

local N = tonumber(arg and arg[1]) or 20000000
if N < 1 then N = 1 end
local t = { x = 0, y = 1 }
io.write(string.format("field RMW %10d -> %d\n", N, run(t, N)))
