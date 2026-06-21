# CURRENT TASK — base-host cleanup (`os.clock`/`warn`) + `require`/`package`

Plan: `/home/bart/.claude/plans/clever-yawning-neumann.md`. Two commits, each
behind the gate + Codex/Antigravity review + Bart's approval (Rule #15).

## Commit 1 — base-host cleanup (os.clock/os.nsclock + warn) — DONE, GATE GREEN

Closes the base-host tier.

- **os.clock** (`src/interp.zig` `nativeClock`): now returns **float seconds**
  (ns/1e9), Lua-faithful, namespaced under `os` via the registry `.module`/`.field`
  (`.name` stays `"clock"` = keyframe identity). The flat `clock` global is gone.
  The recorded `.clock` effect now carries the float (the effect serializer
  round-trips float scalars — `effectser.resultShapeOf`/`checkResultShape`/
  `toEffectResult`); replay returns it verbatim (the native isn't re-called).
- **os.nsclock** (new, `nativeNsClock`): lune extension, raw **int nanoseconds**,
  shares `EffectKind.clock`. Mixed float/int `.clock` entries replay by call order.
- **warn** (`nativeWarn` + `Vm.err` + `Vm.warn_enabled`): Lua 5.4. All args must be
  strings (checked before any emission); a single `@`-prefixed piece is a control
  message (`@off`/`@on` toggle `warn_enabled`, recognized even while off; unknown
  `@…` ignored); else concatenate → one `lune warning: …` line to stderr (`Vm.err`
  or process stderr). Pure output, NOT a recorded effect (like print). `warn_enabled`
  is per-session, not serialized.
- Tests (interp.zig): os.clock-float/os.nsclock-int shape; a record→replay run
  **mixing** os.clock + os.nsclock (shared `.clock` effect, consumed by call order,
  byte-identical replay); warn stderr-vs-stdout, @off/@on (incl. control-while-off),
  unknown-@ ignored, single-vs-multi-piece control, non-string/missing bad-argument.
  Migrated the F2d `clock()` programs to `os.clock()`/`os.nsclock()`.
- Docs: CSV rows `os.clock`+`basic.warn` → implemented; TODO note. Gate +
  check-version green.

### Review (commit 1) — DONE, all three fixes applied; **landed as `ee6a821`**.

## Commit 2 — require/package module system — DONE, GATE GREEN, AWAITING REVIEW

`require` + the `package` table, built on the existing `fs_source` + `file_read`
effect (no new seam, no new effect kind) — so it's **base-host**: a game/embedding
host that injects its own `fs_source` gets `require` for free, determinism covered.

- **`BaseNative.manual`** (`src/function.zig`): restore-only natives — present in
  `base_natives` so the keyframe restorer rebinds them by name, but `defineNative`
  skips install and `builtin_global_names` ignores them. Used for the default
  searchers (which live in `package.searchers`, not at a named global).
- **`load.compileToClosure`** made `pub` so `package` compiles modules via the same
  VM-owned-chunk path as `load`/`loadfile`. `Vm.getOrCreateModuleTable` made `pub`.
- **`src/stdlib/package.zig`** (new): `require` (cache → searcher iteration via
  `callValue` → loader → cache-or-true), `package.searchpath`, the two built-in
  searchers (`preload`, `path` — manual natives), and `installPackageRuntime`
  (seeds `loaded`/`preload`/`path`/`cpath`(inert)/`config`/`searchers`). Wired into
  `base_natives` + `installBaseLib`.
- Tests: interp.zig P3 suite (load+cache/read-once, preload-beats-path, dotted-name
  mapping, not-found message, empty-module→true, transitive, record→replay parity,
  user-replaced searcher closure); keyframeser.zig snapshot/restore (searchers
  rebind, cache survives, require works post-restore). Gate + check-version green.
- Docs: CSV `package,*` rows cli-binding→base-host, implemented (cpath partial/inert;
  loadlib stays excluded). require-cycle note in TODO.

### Review (commit 2) — DONE, one real bug found + fixed, both reviewers clean.
Codex flagged a GC-safety hazard: `requireCore` cached `*Table` pointers for
`package.loaded`/`package.searchers` across `callValue`; a loader/searcher that
reassigns those fields could orphan the table so a nested-safepoint GC sweeps it →
UAF. **Fixed:** added `requirePackageSubTable`, which re-derives the sub-table from
the permanently-rooted `vm.globals` after every `callValue` (no cached pointer).
`name_val` stays a rooted arg. Codex re-confirmed the hazard is closed with no new
leak; Antigravity independently passed all five dimensions (determinism, GC,
restore, memory, fidelity).

## Next
Awaiting Bart's commit approval for commit 2 (Rule #15). Suggested message:
`feat: require/package module system (base-host, host-injectable loader)`.
