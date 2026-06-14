// Dual-execution differential validator (Phase 7 v3, Commit 3).
//
// The same source runs through two *different engines* — the in-browser wasm VM
// and the native binary (via the dev-server `POST /run` middleware) — and this
// module compares their artifacts byte-for-byte. Two independent engines
// agreeing is a far stronger determinism guarantee than two native runs
// agreeing (docs/design/02-determinism.md).
//
// Scope of the byte-identity claim:
//   - A fully deterministic program (zero recorded effects) MUST produce
//     byte-identical keyframe + effects + trace + stdout across both engines. Any
//     mismatch there is flagged for inspection (`ok = false`). Note that basic
//     IEEE-754 float ops (+, -, *, /) ARE bit-identical across wasm and x86-64,
//     so ordinary float programs pass; only transcendentals / NaN payloads can
//     diverge (02-determinism.md's deferred cross-platform-FP item) and would
//     surface here as a flagged divergence — the documented carve-out, to be
//     read by a human, not silently hidden.
//   - clock() and friends are recorded nondeterministic *inputs*: the two engines
//     see independent values, so their effect logs (and any heap state derived
//     from them) differ BY DESIGN. That is expected, labelled, and does not fail
//     the verdict. Such a program's determinism is verified by *replay*, not by
//     this cross-engine record-vs-record comparison.
//
// This module is decode-free on purpose: it reads only the effect-count prefix
// (a plain u32), never the per-effect payload — the vendored TS snapshot/effect
// decoders have a generator bug (they branch on the wrong discriminator field;
// see TODO.md), so a full structural diff is deferred until that codec is fixed.

/** One engine's run output (wasm or native), artifacts as raw bytes. */
export interface RunArtifacts {
  status: number;
  stdout: string;
  keyframe: Uint8Array;
  effects: Uint8Array;
  trace: Uint8Array;
}

export type ArtifactName = "keyframe" | "effects" | "trace";

export interface ArtifactDiff {
  name: ArtifactName;
  match: boolean;
  wasmLen: number;
  nativeLen: number;
  /** First differing byte offset (null when identical). */
  firstDiffByte: number | null;
  /** Set when a mismatch is *expected* (and why); null when match or unexplained. */
  expectedNote: string | null;
}

export interface DiffReport {
  /** True iff every artifact matches OR every mismatch is an explained, expected
   *  divergence — i.e. there is no UNEXPLAINED mismatch. */
  ok: boolean;
  /** Whether both engines saw zero recorded effects (the strong-claim regime). */
  deterministic: boolean;
  /** Recorded-effect counts (wasm, native) read from each log's u32 prefix. */
  wasmEffects: number;
  nativeEffects: number;
  stdoutMatch: boolean;
  /** Set when a stdout mismatch is expected (nondeterministic input printed). */
  stdoutNote: string | null;
  artifacts: ArtifactDiff[];
}

/** Byte-for-byte comparison; returns the first differing offset, if any. */
function compareBytes(a: Uint8Array, b: Uint8Array): number | null {
  const n = Math.min(a.length, b.length);
  for (let i = 0; i < n; i++) {
    if (a[i] !== b[i]) return i;
  }
  if (a.length !== b.length) return n;
  return null;
}

/** The recorded-effect count, read straight from the EffectFile's u32 length
 *  prefix (layout: `version: u32`, `effects.length: u32`, …). Decode-free, so it
 *  sidesteps the buggy per-effect decoder. Returns −1 for a malformed buffer. */
function effectCount(bytes: Uint8Array): number {
  if (bytes.length < 8) return -1;
  const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  return dv.getUint32(4, true);
}

/**
 * Compare a wasm run against a native run of the same source. Pure: no DOM, no
 * I/O — both sides are passed in already-collected.
 */
export function diffRuns(wasm: RunArtifacts, native: RunArtifacts): DiffReport {
  const wasmEffects = effectCount(wasm.effects);
  const nativeEffects = effectCount(native.effects);
  const deterministic = wasmEffects === 0 && nativeEffects === 0;

  const order: ArtifactName[] = ["keyframe", "effects", "trace"];
  const artifacts: ArtifactDiff[] = order.map((name) => {
    const w = wasm[name];
    const n = native[name];
    const firstDiffByte = compareBytes(w, n);
    const match = firstDiffByte === null;

    let expectedNote: string | null = null;
    if (!match && !deterministic) {
      if (name === "effects") {
        expectedNote = `expected: ${wasmEffects}/${nativeEffects} nondeterministic input(s) recorded independently by each engine`;
      } else if (name === "keyframe") {
        expectedNote = "expected: heap state derived from a recorded nondeterministic input";
      }
      // `trace` is control-flow/IR, independent of an effect's *value*, so a
      // trace mismatch is NOT auto-excused even in the nondeterministic regime.
    }

    return { name, match, wasmLen: w.length, nativeLen: n.length, firstDiffByte, expectedNote };
  });

  // stdout may legitimately differ when the program prints a nondeterministic
  // input; otherwise a mismatch is real.
  const stdoutMatch = wasm.stdout === native.stdout;
  let stdoutNote: string | null = null;
  if (!stdoutMatch && !deterministic) {
    stdoutNote = "expected: a nondeterministic input was printed";
  }

  const unexplainedArtifact = artifacts.some((a) => !a.match && a.expectedNote === null);
  const unexplainedStdout = !stdoutMatch && stdoutNote === null;
  const statusMatch = wasm.status === native.status;
  const ok = !unexplainedArtifact && !unexplainedStdout && statusMatch;

  return { ok, deterministic, wasmEffects, nativeEffects, stdoutMatch, stdoutNote, artifacts };
}
