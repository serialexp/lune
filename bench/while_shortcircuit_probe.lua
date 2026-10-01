-- @bench args="120" luajit=compatible name=while_shortcircuit_probe
-- Doc 58 B2 mode-equivalence probe. This is the shape that the 28-bench ×
-- 4-mode parity sweep did NOT carry, and which codex's B2 review used to find
-- a real divergence: with doc 58 B2's first cut, this printed 76 under
-- tier-0, `--trace` and `--jit-native --jit-no-exit-side-native`, but 215
-- with native exit adapters on (now the `--jit-native` default).
--
-- Three ingredients are each necessary (dropping any one makes all four modes
-- agree again):
--   1. a compound `and` in the `while` condition, so the loop's own test is
--      preceded by a short-circuit branch whose not-taken successor is the
--      while's test itself, not the post-loop pc;
--   2. a trip count that VARIES per outer iteration, so the inner root cannot
--      specialise to one trip count;
--   3. a loop-carried boolean flipped every trip, which makes the recorder
--      unroll the body twice (both copies of the loop test then carry the same
--      resume pc).
--
-- The failure is an overrun of exactly one iteration, on the outer iterations
-- whose trip count the armed exit-side child does not serve correctly.
-- Keep this bench even after the fix: it is the only parity coverage of a
-- short-circuit condition on a `while` root.
local s = 0
local n = tonumber(arg and arg[1]) or 120
for r = 1, n do
  local b = false
  local i = 0
  while i < (r % 9 + 3) and true do
    b = not b
    i = i + 1
    if b then s = s + i else s = s - i end
  end
end
print(s)
