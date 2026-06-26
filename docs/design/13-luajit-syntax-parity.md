# lune — LuaJIT 3.0 Syntax-Extension Parity

Status: partial — Phases 1 & 3 landed; Phases 4–5 outstanding
Owner: Bart
Last updated: 2026-06-26

> Scope of *this* doc: the syntax extensions lune has **decided to adopt**, with
> the exact semantics to match (or the exact reason we diverge). Undecided and
> still-moving LuaJIT proposals are listed under "Parked" so they aren't lost,
> but they are explicitly out of this doc's contract until promoted.

## Implementation status

Tracking the gap between this design and `main`. Tick items as they land; move
whole phases to "Done" once everything inside is checked.

### Done

- [x] **Phase 1 — `~>>` arithmetic right shift.** New token `rshift_arith` (`~>>`)
      with maximal-munch disambiguation from `~=` / `~` / `~>`; AST op `sar`,
      bytecode `sar`, compiler mapping; `arith.sar` oracle (sign-extending i64,
      sign-fill on count ≥ 64, logical-left reverse on negative count) + unit
      tests; tier-0 dispatch + `__sar` metamethod + bitwise fault message; parser
      precedence (shift level, l=14/r=15); trace IR `sar` (appended at enum end =
      ordinal 47, wire-pinned in `traceser` + `viz/src/enums.ts`); tier-1a
      `irinterp` eval; `tropt`/`troptdiag` binary classification; `x64`
      `sarRegCl` (D3 /7) + `sarRegImm8` (C1 /7 ib) encoders + tests; `nativegen`
      `proveKinds`/`isTransient`/`operandReads`/`emitShift` (sign-fill leg) +
      differential test across all count regimes. Verified identical across
      tier-0 / tier-1a / native via the CLI; the JIT records `sar` and compiles
      it natively (not declined). The open AST-name question is resolved: `sar`.
      Subsumes the former **Phase 6** (confirm `~>>` lowers under the JIT) —
      proven natively-lowered as part of this phase, not a separate follow-up.
- [x] **Phase 3 — Customary operators `! && || !=`.** Pure lexer aliases: `&&`→
      `and`, `||`→`or`, `!`→`not`, `!=`→`~=` (`ne`), emitting the very same tokens
      so the parser/evaluator are untouched (zero AST/eval change). A lone `&`/`|`
      stays bitwise; only the doubled form aliases, and `!` vs `!=` disambiguates
      by the trailing `=`. Lexer-tag test + end-to-end eval test covering
      short-circuit and value-returning (not boolean-coercing) semantics.

### Outstanding

- [ ] **Phase 2 — `~>>=` compound form.** Rides on the general compound-assignment
      desugar (Phase 5) but the *operator* belongs to the bitwise set; land the
      token alongside Phase 1, wire the desugar in Phase 5.
- [ ] **Phase 4 — `??` nil-coalescing.** New token, AST node, short-circuit eval,
      precedence at the `or` level, pure-nil check, tests.
- [ ] **Phase 5 — Compound assignment `+= -= *= /= //= %= &= |= ~= <<= >>= ~>>= ..=`.**
      Parser desugar with single-evaluation of the target prefix; no `^=`; `~=`
      parses as xor-assign in statement context. Tests for the prefix-eval-once
      contract and the `~=` disambiguation.
- [ ] **Decision needed — error policy doc-link.** Cross-reference the fail-loud
      `//`-by-zero call from `02-determinism.md` (or wherever the error taxonomy
      lives) so the divergence from LuaJIT is recorded in one canonical place.

## Why this exists

Mike Pall is, as of June 2026, formalizing a "Lua-shaped, not Lua-compatible"
syntax-extension set for **LuaJIT 3.0** — the same positioning lune was built on.
The canonical spec is the evolving **first comment of LuaJIT/LuaJIT#1475** (full
per-operator semantics); the backport scope/checklist is **#1476**; an adjacent
instrumentation-ABI call is **#1457**.

Bart's policy: **match LuaJIT's exact semantics unless we have a specific reason
not to; where semantics must diverge, keep the *syntax* aligned** so code reads
the same and muscle memory transfers, even when a value differs. This doc is the
contract for which extensions we take, what their semantics are, and where we
knowingly fork.

## What's already aligned (no work)

lune's operator **precedence already matches** Mike's published table for every
shared operator. The Pratt binding powers live in `infixBp`
(`src/parser.zig:485-512`); the bitwise ordering in particular is identical —
`&` binds tighter than binary `~` (xor) tighter than `|`, all sitting between the
shifts and the comparison operators. Consequence: the new operators have
unambiguous slots —

| Operator | Precedence slot | Assoc |
|----------|-----------------|-------|
| `?.`     | index/call level (highest, with `.` `:` `[]` `f()`) | left |
| `??`     | `or` level | left |
| `?:`     | just below `or` | right |
| compound `=` / `??=` | assignment (lowest) | — |

The existing bitwise tokens (`& | ~ << >>`), `//`, `~=`, and the full arithmetic
set are already lexed, parsed, and evaluated (`src/token.zig`, `src/ast.zig`,
`src/interp.zig`). lune runs on native **i64/f64** with real integers — there is
no `bit.*` library and none is planned.

## Decisions (the contract)

### 1. `//` by zero — fail loud (deliberate divergence)

LuaJIT: plain-number `7 // 0` returns `+inf`/`-inf`/`nan` and **never throws**
(Mike: a compiler wants to avoid "may return or may throw" operations). lune:
**throws.** Syntax identical, semantics diverge.

This is lune philosophy (fail loudly on unexpected conditions), and it is *not* a
JIT tax:

- A throw is **deterministic control flow** (same operands → same throw), so it is
  fully replay-safe. The determinism asterisk only bites if a decision smuggles in
  a clock/RNG/raw address; a divide-by-zero check is a pure function of the operands.
- On a guarded-upstream hot path the cost is at most **one predictable branch**.
  For integer floor-div the branch exists anyway (x86 `idiv` faults on zero), so
  throwing is *free* vs. a silent result. For float div it adds one perfectly
  predicted compare. When the caller guards `b ~= 0` upstream, the optimizer can
  prove the inner guard redundant and **eliminate it entirely** (LuaJIT does this).
- What actually murders a trace is the exceptional path being **taken** (record
  abort / side-exit storm / blacklist) — not its mere existence. "Handle it so you
  never hit that path" is exactly the condition under which the throw is free.

The general rule this instances: **lune fails loud; LuaJIT's no-throw arithmetic
bias is not adopted.** Record the canonical statement in the error-taxonomy doc.

### 2. Bitwise `& | ~ << >> ~>>` — syntax aligned, 64-bit semantics (divergence)

LuaJIT's bit operators are `bit.*` semantics: **32-bit** on plain numbers (64-bit
only for cdata). lune has **native 64-bit** operators and no `bit` library. We
keep the operator *syntax* identical but the *width* diverges: `~x`, `>>`, `<<`,
and `~>>` produce different values than LuaJIT for the same source. This was
already lune's design before #1475; #1475 just confirms the syntax to match.

### 3. `~>>` arithmetic right shift (+ `~>>=`) — add

Completes the shift set. lune today has `>>` (logical, zero-fill) but no
arithmetic (sign-extending) shift. Add token `~>>`, AST op (`sar`/`ashr`), tier-0
eval, native lowering, and the `~>>=` compound form. Mike's symbol choice rationale
(`>>>` reads as *logical* in JS, so `~>>` was the next-best for arithmetic) — we
take his symbol verbatim.

### 4. Customary operators `! && || !=` — add as aliases

Pure lexical aliases:

| Customary | Classic | Meaning |
|-----------|---------|---------|
| `!`  | `not` | logical negation |
| `&&` | `and` | conjunction, short-circuit |
| `||` | `or`  | disjunction, short-circuit |
| `!=` | `~=`  | inequality |

Identical semantics — implemented by emitting the existing tokens from the lexer.
Two-ways-to-write is accepted here (Bart writes `&&`). No AST or eval change.

### 5. `??` nil-coalescing — add, pure-nil only

`a ?? b` returns `b` **iff `a` is nil**, else `a`. Evaluate `a` once;
short-circuit `b` (not evaluated when `a` is non-nil — matters for side effects).
**Pure-nil check only** — lune has no NULL cdata pointer, so the only nil is nil;
do not generalize to falsiness (that's the `a or b` pitfall this operator exists
to avoid). Precedence: `or` level, left-assoc.

## Parked — decided-to-defer or not-yet-decided

These are **not** in this doc's contract. Listed with the semantics to match *when*
promoted, so the survey work isn't repeated.

### Specified well enough to adopt, just not decided yet

- **`?:` ternary** — right-assoc, short-circuits. Replicate the wart: `b` cannot
  directly contain `obj:method()` (parse ambiguity) → requires parens
  `cond ? (obj:method()) : default`.
- **`?.` safe navigation** — the gnarliest. Match points: `?.[key]` **not** `?[key]`;
  whole-chain short-circuit (`foo?.a.b` → nil, but `(foo?.a).b` throws —
  JS-identical, Mike confirmed in-thread); works on **assignment LHS** too (unlike
  JS); method form `obj?.:method()`. Full placement table in the #1475 spec.
- **`??=` nil-coalescing assignment** — short-circuits `b` (unlike the other
  compound ops), single-eval of the target prefix.
- **`continue`** — landmine: `repeat…until` where `continue` jumps into a local's
  scope referenced by the `until` expression. Mike rejects continue-into-scope; he
  affords the analysis because the 3.0 parser is SSA. lune is tree-walk + JIT, so
  this needs its own equivalent scope check, not a verbatim lift.
- **Underscores in number literals** — `1_000_000`. Lexer-only; trivial.

### Not yet frozen upstream — chasing now = chasing a moving target

- **`const`** — soft keyword in place of `local`; Mike leaning `const` over Lua
  5.4's `<const>`.
- **Short function syntax** — Mike leaning `|…| -> expr` / `|…| -> do … end`, TBD.
- **String interpolation / template literals** — Mike marks "needed?".
- **Match/switch** — novel `in expr do … end` with `=>` arms, actively being
  designed in the thread (multi-match, implicit selector binding still in flux).

### Adjacent, non-syntax

- **#1457 instrumentation ABI** — Mike proposes near-zero-overhead VM
  instrumentation (machine-code addr → trace number, per-trace details, frame
  walking) so external profilers stop disassembling the VM. That is the
  introspection surface lune's trace visualiser / time-travel replay already owns
  natively. Worth lurking as a gap-check on what a tracing JIT "should" expose; no
  action.

## Phasing

Land in the Outstanding order. Each phase is independently shippable behind
`zig build test` and pins its semantics with parity tests (global Rule #3, Z-3).
Phases 1–4 are mechanical (tokens/aliases/one AST node). Phase 5 (compound
assignment) is the only one touching statement parsing — it carries the
single-evaluation-of-prefix contract and the `~=`-as-xor-assign disambiguation,
so it gets the most test surface.

## Open questions for review

- [ ] Where does the canonical "lune fails loud, no silent inf/nan" statement
      live — `02-determinism.md`, a new error-taxonomy doc, or here? (Decision 1
      references it; pick one home.)
- [x] AST op name for arithmetic shift: **resolved to `sar`** (matches the x86
      mnemonic and the existing `shl`/`shr` naming). Landed in Phase 1.
- [ ] Do customary aliases round-trip through any pretty-printer / formatter we
      own? If a formatter exists, decide whether it canonicalizes `&&`→`and` or
      preserves source (Mike's criterion 5: don't hurt tool developers).

## References

- LuaJIT/LuaJIT#1475 — *LuaJIT 3.0 Syntax Extensions* (first comment = canonical
  per-operator spec + precedence table).
- LuaJIT/LuaJIT#1476 — *Backport v3.0 Syntax Extensions to v2.1* (scope checklist;
  `temp-v3bp-syntax1` branch).
- LuaJIT/LuaJIT#1457 — *VM instrumentation for third-party tools*.
- `src/parser.zig:485-512` (`infixBp`) — current precedence table.
- `TODO.md` — "LuaJIT 3.0 syntax extensions — parity survey + decision log"
  (the running scratch this doc was promoted from).
