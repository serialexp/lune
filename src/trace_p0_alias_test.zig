//! Doc 43 P0 adversarial-alias corpus — the permanent, in-tree home of the
//! 2026-09-07 sweep that found the entry-snapshot / store-sinking miscompiles.
//!
//! Each program is a minimal shape that either (a) triggered a confirmed
//! tier-1a/native miscompile now fixed fail-closed (P0a callee-upvalue open
//! aliasing, P0b global-seed staleness, P0d length-dependent append double-
//! apply), or (b) is a boundary control that MUST keep tracing correctly and is
//! pinned so a future change can't silently regress it.
//!
//! `expectProgram` runs the full ten-leg matrix ({gc-stress off/on} × {tier-0,
//! record-only, tier-1a no-opt, tier-1a, native}) and asserts byte-identical
//! output on every leg — so a stale seed, a skipped sunk store, or a double-
//! applied append all diverge here. `hotloop = 4` (test config) commits traces
//! after 4 iterations, so the modest counts below still exercise committed
//! native code AND the loop-done replay path.
//!
//! Counts are scaled down from the original 1e5-iteration sweep purely for test
//! speed; the shapes and the expected sums are otherwise faithful (the sweep
//! itself lives at the same shapes with larger N).

const expectProgram = @import("interp_testutil.zig").expectProgram;

test "P0 corpus a01: callee upvalue open over anchor-mutated local (P0a fix)" {
    try expectProgram(
        \\local acc = 0
        \\local function get() return acc end
        \\local s = 0
        \\for i = 1, 2000 do acc = i; s = s + get() end
        \\print(s)
    , "2001000\n");
}

test "P0 corpus a02: hstore through _G stales a .global seed (P0b fix)" {
    try expectProgram(
        \\x = 0
        \\local g = _G
        \\local s = 0
        \\for i = 1, 2000 do g.x = i; s = s + x end
        \\print(s)
    , "2001000\n");
}

test "P0 corpus a03: rawset(_G,...) stales a .global seed (P0b fix)" {
    try expectProgram(
        \\x = 0
        \\local g = _G
        \\local s = 0
        \\for i = 1, 2000 do rawset(g, "x", i); s = s + x end
        \\print(s)
    , "2001000\n");
}

test "P0 corpus a04: read through _G alias, write via set_global (pin safe)" {
    try expectProgram(
        \\x = 0
        \\local g = _G
        \\local s = 0
        \\for i = 1, 2000 do x = i; s = s + g.x end
        \\print(s)
    , "2001000\n");
}

test "P0 corpus a05: store via t, load via alias t2, hash field (pin safe)" {
    try expectProgram(
        \\local t = { x = 0 }
        \\local t2 = t
        \\local s = 0
        \\for i = 1, 2000 do t.x = i; s = s + t2.x end
        \\print(s)
    , "2001000\n");
}

test "P0 corpus a06: store via a, load via alias a2, array slot (pin safe)" {
    try expectProgram(
        \\local a = { 0 }
        \\local a2 = a
        \\local s = 0
        \\for i = 1, 2000 do a[1] = i; s = s + a2[1] end
        \\print(s)
    , "2001000\n");
}

test "P0 corpus a07: two distinct same-shape tables, no cross-forward (control)" {
    try expectProgram(
        \\local t = { x = 0 }
        \\local u = { x = 0 }
        \\local s = 0
        \\for i = 1, 2000 do t.x = i; u.x = 2000 - i; s = s + t.x + u.x end
        \\print(s)
    , "4000000\n");
}

test "P0 corpus a08: shared closed-cell writer via set_upval (pin safe)" {
    try expectProgram(
        \\local function mk()
        \\  local v = 0
        \\  return function() return v end, function(nv) v = nv end
        \\end
        \\local get, set = mk()
        \\local s = 0
        \\for i = 1, 2000 do set(i); s = s + get() end
        \\print(s)
    , "2001000\n");
}

test "P0 corpus a09: callee upvalue open BELOW anchor window, per-episode reseed" {
    try expectProgram(
        \\local n = 0
        \\local function get() return n end
        \\local function run()
        \\  local s = 0
        \\  for i = 1, 2000 do s = s + get() end
        \\  return s
        \\end
        \\local total = 0
        \\for round = 1, 3 do n = round; total = total + run() end
        \\print(total)
    , "12000\n");
}

test "P0 corpus a10: hash_cell RMW via t, read via alias t2 (pin safe)" {
    try expectProgram(
        \\local t = { c = 0 }
        \\local t2 = t
        \\local s = 0
        \\for i = 1, 2000 do t.c = t.c + 1; s = s + t2.c end
        \\print(s)
    , "2001000\n");
}

test "P0 corpus a11: integer-key store + string-key global read, disjoint parts" {
    try expectProgram(
        \\x = 7
        \\local g = _G
        \\local s = 0
        \\for i = 1, 2000 do g[1] = i; s = s + x end
        \\print(s)
    , "14000\n");
}

test "P0 corpus a12: cross-episode function-valued swap via upvalue callee" {
    try expectProgram(
        \\local function f1() return 1 end
        \\local function f2() return 2 end
        \\local f = f1
        \\local s = 0
        \\for round = 1, 4 do
        \\  if round == 3 then f = f2 end
        \\  for i = 1, 2000 do s = s + f() end
        \\end
        \\print(s)
    , "12000\n");
}

test "P0 corpus a13: hash_cell seed vs table growth between episodes" {
    try expectProgram(
        \\local t = { c = 0 }
        \\local s = 0
        \\for round = 1, 4 do
        \\  for i = 1, 2000 do t.c = t.c + 1; s = s + t.c end
        \\  t["k" .. round] = round
        \\end
        \\print(s)
    , "32004000\n");
}

test "P0 corpus a14: mid-loop global function swap calls the right function" {
    try expectProgram(
        \\local function f1() return 1 end
        \\local function f2() return 1000 end
        \\f = f1
        \\local g = _G
        \\local s = 0
        \\for i = 1, 2000 do
        \\  if i == 1000 then g.f = f2 end
        \\  s = s + f()
        \\end
        \\print(s)
    , "1001999\n");
}

test "P0 corpus a15: mid-loop upvalue function swap through inlined callee" {
    try expectProgram(
        \\local function f1() return 1 end
        \\local function f2() return 1000 end
        \\local f = f1
        \\local function call() return f() end
        \\local s = 0
        \\for i = 1, 2000 do
        \\  if i == 1000 then f = f2 end
        \\  s = s + call()
        \\end
        \\print(s)
    , "1001999\n");
}

test "P0 corpus a16: length-dependent append via alias (P0d fix)" {
    try expectProgram(
        \\local a = {}
        \\local a2 = a
        \\local s = 0
        \\for i = 1, 2000 do a[#a + 1] = i; s = s + #a2 end
        \\print(s)
    , "2001000\n");
}

test "P0 corpus a17: sunk hash RMW visible right after linked loop-done" {
    try expectProgram(
        \\local t = { x = 0 }
        \\local s = 0
        \\for round = 1, 200 do
        \\  for i = 1, 50 do t.x = t.x + 1 end
        \\  s = s + t.x
        \\end
        \\print(s)
    , "1005000\n");
}

test "P0 corpus a18: sunk array RMW applies exactly once at loop-done" {
    try expectProgram(
        \\local a = { 0 }
        \\local s = 0
        \\for round = 1, 200 do
        \\  for i = 1, 50 do a[1] = a[1] + 1 end
        \\  s = s + a[1]
        \\end
        \\print(s)
    , "1005000\n");
}

test "P0 corpus a19: counting append (nsieve shape) stays exact" {
    try expectProgram(
        \\local a = {}
        \\for i = 1, 2000 do a[i] = i * 2 end
        \\local s = 0
        \\for i = 1, 2000 do s = s + a[i] end
        \\print(s, #a)
    , "4002000\t2000\n");
}

test "P0 corpus a20: per-round append + immediate aggregate (P0d-adjacent)" {
    try expectProgram(
        \\local s = 0
        \\for round = 1, 200 do
        \\  local a = {}
        \\  for i = 1, 100 do a[#a + 1] = i end
        \\  s = s + #a
        \\end
        \\print(s)
    , "20000\n");
}

// Doc 81 §7: `set_global` records as a store into the globals table. Each
// shape below pins one way a recorded global store meets a global read, a
// `_G` handle, or a change to the globals table.

test "P0 corpus g01: set_global then get_global of the same name reads the store" {
    try expectProgram(
        \\x = 0
        \\local s = 0
        \\for i = 1, 2000 do x = i; s = s + x end
        \\print(s, x)
    , "2001000\t2000\n");
}

test "P0 corpus g02: get_global then set_global of the same name (the memo retry)" {
    try expectProgram(
        \\x = 0
        \\local s = 0
        \\for i = 1, 2000 do s = s + x; x = i end
        \\print(s, x)
    , "1999000\t2000\n");
}

test "P0 corpus g03: a global counter RMW" {
    try expectProgram(
        \\n = 0
        \\for i = 1, 2000 do n = n + 1 end
        \\print(n)
    , "2000\n");
}

test "P0 corpus g04: set_global of one name, a _G-handle store and read of another" {
    try expectProgram(
        \\x = 0
        \\y = 0
        \\local g = _G
        \\local s = 0
        \\for i = 1, 2000 do y = i; g.x = i; s = s + x + y end
        \\print(s)
    , "4002000\n");
}

test "P0 corpus g05: an inlined callee's RNG seed is a global RMW" {
    try expectProgram(
        \\seed = 1
        \\local function rnd() seed = (seed * 16807) % 2147483647; return seed % 10 end
        \\local s = 0
        \\for i = 1, 2000 do s = s + rnd() end
        \\print(s, seed)
    , "8899\t75099568\n");
}

test "P0 corpus g06: freezing _G mid-loop stops the recorded store" {
    try expectProgram(
        \\x = 0
        \\local s = 0
        \\local ok = pcall(function()
        \\  for i = 1, 2000 do
        \\    if i == 1000 then table.freeze(_G) end
        \\    x = i
        \\    s = s + i
        \\  end
        \\end)
        \\print(ok, s, x)
    , "false\t499500\t999\n");
}

test "P0 corpus g07: new globals mid-loop change the table under a recorded store" {
    try expectProgram(
        \\x = 0
        \\local s = 0
        \\for i = 1, 2000 do
        \\  x = x + 1
        \\  if i % 500 == 0 then _G["k" .. i] = i end
        \\  s = s + x
        \\end
        \\print(s, k1000)
    , "2001000\t1000\n");
}

test "P0 corpus g08: a global deleted and re-created under a recorded store" {
    try expectProgram(
        \\x = 0
        \\local s = 0
        \\for i = 1, 2000 do
        \\  x = i
        \\  if i == 1500 then x = nil end
        \\  s = s + (x or 0)
        \\end
        \\print(s, x)
    , "1999500\t2000\n");
}

test "P0 corpus g09: a global function swapped while a counter is stored" {
    try expectProgram(
        \\local function f1() return 1 end
        \\local function f2() return 1000 end
        \\f = f1
        \\c = 0
        \\local s = 0
        \\for i = 1, 2000 do
        \\  c = c + 1
        \\  if i == 1000 then f = f2 end
        \\  s = s + f()
        \\end
        \\print(s, c)
    , "1001999\t2000\n");
}

test "P0 corpus g10: two globals stored by an inlined callee, one read back" {
    try expectProgram(
        \\a = 0
        \\b = 0
        \\local function bump() a = a + 1; b = b + a end
        \\for i = 1, 2000 do bump() end
        \\print(a, b)
    , "2000\t2001000\n");
}
