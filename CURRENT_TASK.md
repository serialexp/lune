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

## Review (DONE — both clean modulo three fixes, all applied)
Codex + Antigravity ran on commit 1. Three actionable items, all fixed:
1. `effect_format_version` 4→5 (old v4 int-ns clock logs would replay as float
   seconds verbatim — fail-loud signal, not backcompat per Rule #8).
2. `nativeWarn` emission made best-effort (`emitWarning(...) catch {}`) so a stderr
   write failure can never become a catchable VM fault — making the unserialized
   `warn_enabled` sound (warn touches only stderr, outside the replay contract).
3. Added the mixed os.clock/os.nsclock record→replay test (the shared-effect
   replay path; the shape test alone was off-mode only).

## Next
Awaiting Bart's commit approval for commit 1 (Rule #15). Suggested message:
`feat: finish base-host tier — os.clock/os.nsclock + warn`. After that: Phase 3
(`require`/`package`).
