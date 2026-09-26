# Doc 56 Phase 4 code review — Antigravity (2026-09-26)

Scope: the uncommitted Phase 4 change (`git diff HEAD -- src justfile`
plus the new `src/nativegen_adapter.zig` / `src/nativegen_adapter_test.zig`):
the exit-side stub and `exit_side_cells`, the exit adapter builder,
liveness extension (`extendExitSideLiveness`), `ExitLoc.live_from`, the
`exit_side_ok` direct-entry byte, publish/unpublish on the exit-side state
machine, the `--jit-exit-side-native` switch, the recorder's per-VM
`debug_log` gate and the `just shadow` rsync change. Read-only review
with tool access, asked to be adversarial.

**Verdict: no serious findings.**

Verified sound by the reviewer:
- materialization order matches tier-1a `materializeExitSide`: sunk stores
  with `0 < ord < guard.ord` in stream order, then carried homes, then
  exit-snapshot slots (which override the homes);
- the stub and the constant/`uref` staging clobber only `rax`; staged
  words sit above `map.frame_words`, so they never collide with a live
  spill cell; the store emitters' scratch registers are outside the
  allocator's orders;
- `extendExitSideLiveness` keeps every value an attachable exit reads live
  to it (and suppresses win-1 reuse at the guard); `live_from = 0` for
  slot homes holds because the prologue loads every home, win-2 coalescing
  only happens after the last body guard (and `live_until` is clamped
  there), and peeled traces have no map;
- `exit_side_ok` is set only at the dispatcher's two direct entries, and
  the stub also requires an empty ledger and no active silent set, so a
  chain replay never sees an `.exit_side` row;
- ownership: `CompiledTrace.deinit` frees cells, adapter pages and target
  cells; unpublish on every `gave_up`; OOM paths free what they built;
- determinism: every publish/unpublish is driven by deterministic counters;
  addresses only feed a `!= 0` test on the cell, never a tiering decision;
- with the switch off: no cells, no liveness extension, no stubs — the code
  is unchanged.

## Findings and what was done

1. **Minor — `ownCarried` misses a duplicate reload of a carried slot.**
   A second `slot_load` of the same carried slot, restored by the exit
   snapshot, is not recognised as "the carried home already wrote it"; if
   that reload's register has expired the build refuses (`not_held`).
   *Checked:* fails soft (ordinary exit), and the recorder maps each slot
   to one load through its register map, so a live duplicate is not
   produced today. No change.

2. **Minor — `frameWords` over-counts boxed tag spills.** The reviewer
   claimed `boxedTagSpill` only numbers `.boxed` `slot_load`s.
   *Checked and rejected:* `boxedTagSpill` (`nativegen_emit.zig:470`)
   takes its ordinal over EVERY `.boxed` kind below the ref, so the tag
   cells span exactly `spill_count + count(.boxed)` — what `frameWords`
   computes. Over-counting would in any case only be conservative.

3. **Nit — the staged `uref`'s kind is never read.** True: a `uref` is
   only a store base, read through `refBaseReg`, which ignores kinds.
   *Fixed:* the adapter now marks it `.ptr` (a cell pointer) instead of
   borrowing a map row's kind, and the comment says why.

Reviewer note: several of its quoted snippets and line numbers did not
match the tree (e.g. a `u8` slot parameter that is `u16`, a `.spill_limit`
refusal that is `.spill`); each finding above was re-checked against the
real source before acting on it.
