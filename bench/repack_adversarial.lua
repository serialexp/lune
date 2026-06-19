-- Adversarial benchmark for Lune's lane-packed array part.
--
-- Goal: maximise the work that is *asymmetric* between stock Lua and Lune —
-- operations stock Lua does in O(1) but Lune must do in O(n) because it keeps a
-- table's dense array part packed in a narrow "lane" (i8/bool/f64/…) and has to
-- rewrite the whole packed buffer when a value falls outside the current lane.
--
-- The two asymmetric costs:
--   * widen   — storing an out-of-lane value (e.g. a float into an int lane)
--               rewrites every slot into the 16-byte value lane.
--   * convert — at a rehash, optimalLane() may re-pack the whole array.
--
-- A *single long-lived* table can't be made to pay these often: re-narrowing
-- needs a rehash, and Lune's rehash threshold doubles each time (amortised). So
-- this benchmark defeats the amortisation with many **fresh** tables — each one
-- starts at threshold 4, pays a full rehash+convert, and is then forced to widen
-- its whole array exactly once. Stock Lua pays O(1) for the same stores.
--
-- Modes (arg[1]):
--   control — build each table's array only (work both engines pay equally).
--   poison  — build, then force one full-array widen per table (Lune-only cost).
--   churn   — one big persistent table, hammered with lane-flipping rehashes.
-- arg[2] = M (tables / rounds), arg[3] = K (elements per table).
--
-- @bench args="poison 2000 1000" luajit=compatible name=repack

local mode = (arg and arg[1]) or "poison"
local M = tonumber(arg and arg[2]) or 6000
local K = tonumber(arg and arg[3]) or 3000

local checksum = 0

if mode == "control" then
  -- Build a dense small-int array per table. In Lune the first inserts (no a[1])
  -- route through the hash, trip a rehash, and pack the run into a narrow int
  -- lane; stock Lua just grows its array part. No out-of-lane store: this is the
  -- shared baseline both engines pay.
  for _ = 1, M do
    local a = {}
    for i = 2, K do a[i] = i % 100 end
    checksum = checksum + a[3]
  end

elseif mode == "poison" then
  -- Same build, then a single float store into a slot that already holds an int.
  -- Trivial for Lua; in Lune it is out of the narrow int lane, so the entire
  -- packed array is rewritten into the 16-byte value lane (one full-array pass).
  for _ = 1, M do
    local a = {}
    for i = 2, K do a[i] = i % 100 end
    a[2] = 0.5
    checksum = checksum + a[3] + a[2] * 2
  end

elseif mode == "storm" then
  -- Like poison, but per table run C widen/re-narrow CYCLES so the repack work
  -- (Lune-only) dominates the one-time build (shared). Each cycle: store a float
  -- (widen narrow->value, O(K)), store an int back, then a short bounded burst of
  -- fresh hash keys to cross the rehash threshold and re-narrow value->int
  -- (convert, O(K)). A fresh table each outer iter resets the threshold so the
  -- per-cycle churn stays tiny. arg[4] = C (cycles per table, default 6).
  local C = tonumber(arg and arg[4]) or 6
  for _ = 1, M do
    local a = {}
    for i = 2, K do a[i] = i % 100 end
    local nextkey = K + 1000000
    local need = 4
    for _ = 1, C do
      a[2] = 0.5                          -- widen narrow -> value (O(K))
      a[2] = 2                            -- int again (lane still value)
      for j = 1, need do a[nextkey + j] = j end   -- force a rehash -> re-narrow
      for j = 1, need do a[nextkey + j] = nil end
      nextkey = nextkey + need
      -- Cap the per-cycle key burst: the rehash threshold roughly doubles each
      -- rehash, so crossing it needs ~2x more keys each time — but left uncapped
      -- the burst is 4*2^C and overflows time/memory for large C. Past the cap the
      -- threshold simply outruns us and rehashes stop firing, which is fine: under
      -- monotonic lanes a forced rehash no longer re-narrows anyway.
      if need < 65536 then need = need * 2 end
    end
    checksum = checksum + a[3]
  end

elseif mode == "churn" then
  -- One persistent big array. Each round flips the lane: poke a float (widen
  -- narrow->value, O(K)), set it back to an int, then churn enough fresh hash
  -- keys to cross the (doubling) rehash threshold so the next rehash re-narrows
  -- value->int (convert, O(K)). Lua pays O(1) per store and only rehashes its
  -- hash part. The hash churn grows ~2x per round, so keep M small.
  local a = {}
  for i = 2, K do a[i] = i % 100 end
  local nextkey = K + 1000000 -- sparse: never migrates into the array
  local need = 4
  for _ = 1, M do
    a[2] = 0.5        -- widen narrow -> value
    a[2] = 7          -- back to an int value (lane still value until a rehash)
    -- churn `need` fresh sparse keys to force a rehash, then delete them
    for j = 1, need do a[nextkey + j] = j end
    for j = 1, need do a[nextkey + j] = nil end
    nextkey = nextkey + need
    -- Threshold roughly doubles each rehash, so we'd need ~2x more keys to force
    -- the next one — the amortisation that protects a long-lived table. Cap the
    -- push so the loop terminates; past the cap, rehashes simply stop firing and
    -- Lune stops repacking (which is the point: one table can't be milked).
    if need < 65536 then need = need * 2 end
    checksum = checksum + a[3]
  end
end

io.write(string.format("%s checksum %.1f\n", mode, checksum))
