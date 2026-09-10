# Codex review — doc 45 guarded-absence slice (commit b2b5bd3)

Reviewer: Codex MCP (default model), read-only sandbox, 2026-09-10.
Scope: commit `b2b5bd3` against the doc 45 D7 contract; focus on
`emitGuardAbsent` inline-path equivalence with `table_runtime.isAbsent`,
`proveKinds` href-key demotion/admission, the `.nil` native kind, recorder
pending-store forwarding, and tropt effect classing.

Verdict: **no findings** — CRITICAL: none. MAJOR: none. MINOR: none.

Key checks reported:
- inline path matches `isAbsent` for every reachable shape (type/metatable,
  grid → full lookup, unsigned bounds incl. negative keys, boolean byte,
  16-byte `.value` tag, presence bitmap, hash count gate);
- rax/rcx excluded from allocation; callout registered via `bodyCalloutOf`
  with save area covering caller-saved GP/XMM homes + rdi/rsi/rdx;
- href_key demotion recognizes guard_absent as a real two-operand use;
  admission rejects `.none`;
- `.nil` rejected by numeric/comparison admission, correct truthiness,
  zero payload, nil-tag boxing in flushSlot;
- recordAbsentGet forwards must-alias pending stores, aborts ambiguity;
- tropt `.astore` classing → liveness root, no fold/CSE/DCE/LICM;
- wire ordinal 87 / side-exit classification / no exit-PC reading consistent.

Note: source review only (read-only env); gates were run separately in the
landing session (tests ×2, hashgate 84×2, wasm, viz 69).
