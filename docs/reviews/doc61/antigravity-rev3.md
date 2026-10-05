# Doc 61 rev 3 — antigravity review (2026-10-05)

Verdict: **REVISE**. Folded into rev 4.

## Blocker

- **Nested `xpcall` handlers break the single Vm fault range.** An inner handler overwrites `fault_lo`/`fault_hi`, and restoring them on return is not enough to describe both regions while the inner handler runs. Suggested fix: a per-frame faulting flag. → Rev 4 uses the existing per-frame `in_flight` flag with save/restore on the topmost faulting frame (§4.4).

## Should-fixes

- **SF1.** `pushHostCall`'s new callee frame must start `in_flight = false`. Only the caller is in flight. → Rev 4 §4.2.
- **SF2.** Bytecode has only one frame-pushing opcode, `.call`: method calls and the generic-for iterator call both compile to it. The call-like set should say so. → Rev 4 §4.3.

## Q1

Again recommends (b), pooling only pinned values. → Recorded in rev 4 §7; Bart decides.
