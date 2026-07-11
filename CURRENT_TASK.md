# CURRENT_TASK — Exit-branch patching (faithful LuaJIT port)

## Where we are (2026-07-11)

Bart chose the **faithful port**: re-architect lune's native traces toward
LuaJIT's frameless shared-arena model so a trace→trace transition is a bare `jmp`
(no ~600 ns Zig dispatcher re-entry), which is the only thing that flips nsieve's
tiny linked clusters from neutral to a win. Design is in
`docs/design/17-exit-branch-patching.md` (grounded against LuaJIT
`lj_mcode.c` + `vm_x86.dasc`; committed `bf55370`).

### Committed this session (all LOCAL, unpushed — Rule #15)
- `5ba4048` fix: don't penalize shared anchor on successful coherent chain bursts
- `62d619b` docs: correct the false "untraceable init loop" nsieve diagnosis
- `911fbaf` fix: select native tier for zero-exit coherent chain under --jit-native (task #38)
- `01ece13` docs: add design 17 (investigation + peer review)
- `bf55370` docs: ground design 17 port architecture against LuaJIT

### Tasks
#41 P-D arena · #42 P-A frameless ABI (blocked by 41) · #43 P-B result (by 42) ·
#44 P-C exit-kind (by 42) · #45 P-E lifetime (by 41) · #46 P-F determinism ·
#47 P-G eligibility+fallback. Three ordered increments in doc 17 §Phasing.

## Key facts established (de-risk Increment 1)
- **All runtime helper calls are absolute** (`movRegImm64 rax, &fn; call rax`,
  e.g. nativegen.zig:2804-2806); all jmp/jcc are trace-local labels. **No rel32
  cross-region refs exist today** → the arena's ±2GiB window is NOT load-bearing
  until Increment 2 (bare jmps). So Increment 1 is pure co-location.
- Usage surface is tiny: `ExecPage`/`mapExecutable`/`CompiledTrace` live in
  nativegen.zig; `nativeFor` (trace.zig:1795) is the only production consumer.

## Increment 1 — Shared arena, keep per-trace C ABI (task #41) — ✅ LANDED

Implemented `McodeArena` in nativegen.zig (bump cursor + first-fit free-list,
mcprot RW↔RX toggle). `ExecPage` is now a view (`.owned` mmap for the test path,
`.arena` slot for production). `compile(gpa,t)` (tests) + `compileInto(gpa,arena,t)`
(production, via `nativeFor`) share `compileImpl`. Arena owned by `TraceState`,
deinited after the cache. main.zig dumpNative reads `ct.page.code`.
Per-trace reclaim KEPT (Bart: try reclaim first, revisit if worse than pure bump).
Gate met: `just test` green; nsieve byte-identical tier-0/tier-1a/native; bench
unchanged (nsieve jit 93.3ms, nsieve-bit 52.5ms, fp 276.5ms — matches baseline).
NOT committed yet.

### Original plan (kept for reference)

**Goal:** replace per-trace `mmap` with one arena; traces become *slices* of it.
Keep the per-trace `call`/`ret` C ABI unchanged (still C functions, just
co-located). Byte-identical *behavior*; independently testable.

**Lifecycle today (all in nativegen.zig unless noted):**
- `ExecPage {mem: []align u8, len}` — owns an mmap; `deinit()` munmaps (:84-100).
- `mapExecutable(code) -> ExecPage` (:104) — mmap RW, memcpy, mprotect RX.
- `CompiledTrace {page}` (:348); `compile(gpa,t)` (:414) calls mapExecutable (:443).
- `CompiledTrace.deinit` → `page.deinit()` (:380).
- `NativeState.compiled` union (trace.zig:390); set in nativeFor (:1801).
- `Trace.destroy` → `self.native.deinit()` (trace.zig:623).
- `TraceState.deinit` frees all traces (trace.zig:~992 `for cache |t| t.destroy`).
- Two TEST-ONLY standalone `mapExecutable` at nativegen.zig:5247,5280 (runNative
  helpers) — keep a standalone path for these or give them a throwaway arena.

**Design decided (faithful LuaJIT):**
- `McodeArena` owned by `TraceState` (lifetime ≥ all traces). Chain of mmap'd
  regions (~1 MB each); bump cursor; chain a new region when full.
- `arena.alloc(code) -> ExecPage`: ensure region RW, memcpy at cursor, advance,
  mprotect RX (mcprot-style; ~2 mprotects/trace, negligible — compile is rare).
- `ExecPage` becomes a *slice view* (base ptr + len into a region); `deinit()`
  → **no-op**. `CompiledTrace.deinit` → no-op. `Trace.destroy` stops munmapping.
  Arena munmaps all regions at `TraceState.deinit`.
- **Reclamation policy = LuaJIT's: NO per-trace free.** Retired traces' mcode
  becomes dead space until arena deinit. Fine for bench/test (rare retirement).
  **Flush-all-on-full deferred** → note in TODO.md when implemented.
- Placement: mmap with a hint near a runtime fn addr (best-effort centering) so
  Increment 2's rel32 jmps land in range. **Strict in-range check + abort-trace
  (LuaJIT `LJ_TRERR_MCODEAL`) DEFERRED to Increment 2** (nothing needs rel32 yet).
- Thread the arena into `compile` (add param) from `nativeFor`.

**Gate:** `just test` green; 10-mode matrix nsieve byte-identical (single unique
block: `./zig-out/bin/lune [--trace [--jit-native]] nsieve.lua 9 | sort -u`).

## SEMANTIC CHANGE to flag to Bart before/at commit
Increment 1 makes trace retirement stop freeing mcode immediately (faithful to
LuaJIT; flush-all deferred). If Bart wants per-trace reclaim kept, the arena
needs a free-list instead — ask before relying on the no-reclaim policy.

## Then: Increment 2 (frameless trampoline + bare-jmp links) → Increment 3
(port lj_asm_patchexit + unpatch-on-retire). See doc 17 §Phasing.

## Untracked files that belong to OTHER agents — do NOT stage
`CURRENT_TASK_E3.md`, `bench/results/*.tsv`, and similar.
