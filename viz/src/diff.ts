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
// Effect counts are read decode-free (a plain u32 prefix). The keyframe, however,
// is normalized through the snapshot decoder before comparison to neutralize the
// one host-injected difference: the native CLI populates `arg[0]` = the script
// path (a nondeterministic temp path, commit 94cf36e), while the wasm embedding
// has no argv and leaves it unset. That is an *embedding* difference, not a
// language-determinism one, so `keyframeSansArg` drops integer key `0` from the
// global `arg` table on both sides. Every OTHER part of the reachable state is
// preserved with full fidelity — i64 globals as exact decimals, float64s by raw
// bits, and the `loaded_chunks` list — so a genuine cross-engine divergence still
// surfaces. (The trace/effects artifacts stay byte-compared.)

import { SnapshotFileDecoder } from "./gen/generated";

const td = new TextDecoder();

/** True when a decoded SnapValue is a heap reference. */
function svId(sv: any): number | null {
  return sv && sv.tag === 4 ? Number(sv.body.value.id) : null;
}

// Lossless JSON scalarization: a bigint is emitted as its exact decimal string (a
// `Number` cast would silently collapse any i64/u64 above 2^53), and raw bytes as
// a numeric array.
const jsonReplacer = (_k: string, v: any) =>
  typeof v === "bigint" ? `i64:${v.toString()}` : v instanceof Uint8Array ? Array.from(v) : v;

// A float64's exact 8-byte little-endian bit pattern as hex. Comparing the bits
// (not the JS `number`) preserves the divergences JSON.stringify would erase: NaN
// payloads, ±Infinity (both → `null`), and −0 (→ `0`).
function f64Bits(v: number): string {
  const dv = new DataView(new ArrayBuffer(8));
  dv.setFloat64(0, v, true);
  return dv.getBigUint64(0, true).toString(16).padStart(16, "0");
}

/**
 * Decode a keyframe, drop `arg[0]`, and return a canonical structural string in
 * which every object is relabelled by its first-visit order in a deterministic
 * walk from the roots (globals → string metatable → stack → frames → open
 * upvalues, each object's edges in a fixed order). Absolute object ids are never
 * emitted — only these traversal-relative indices — so the id SHIFT that native
 * introduces by allocating `arg[0]` = script path mid-sequence (which bumps every
 * later object's id by one vs the wasm embedding, and interns extra global-name
 * strings) cancels out. Scalars keep full fidelity: i64 as an exact decimal,
 * float64 by raw bits (NaN/±Inf/−0 distinguished), and `loaded_chunks` is emitted
 * in load order — so the ONLY thing this normalization hides is the host-injected
 * `arg[0]`; any real divergence elsewhere still yields a different string. Returns
 * a distinct fallback string if the buffer can't be decoded, so a malformed
 * keyframe surfaces as a mismatch rather than throwing.
 */
export function keyframeSansArg(bytes: Uint8Array): string {
  let kf: any;
  try {
    kf = new SnapshotFileDecoder(bytes).decode().keyframe;
  } catch {
    return `undecodable:${bytes.length}`;
  }
  const byId = new Map<number, any>();
  for (const o of kf.objects) byId.set(Number(o.id), o);

  // Neutralize the single host-injected slot globals["arg"][0]. The native CLI
  // sets arg[0] = the script path (a nondeterministic temp path); the wasm
  // embedding has no argv and leaves it unset. We drop integer key 0 from `arg` on
  // BOTH sides — symmetric, so a user-set arg[0] cancels too — and leave every
  // other slot (arg[1..], arg.foo, the array part) intact, so a genuine divergence
  // there still surfaces. Key 0 is never in the array part (that holds keys 1..n),
  // so it always lives in the hash `entries`. The now-orphaned path string simply
  // isn't reached by the traversal below and drops out on its own.
  const globals = byId.get(Number(kf.globals_id));
  if (globals && globals.obj_type === 1) {
    for (const e of globals.body.value.entries) {
      const keyId = svId(e.key);
      if (keyId === null) continue;
      const keyObj = byId.get(keyId);
      if (keyObj && keyObj.obj_type === 0 && td.decode(new Uint8Array(keyObj.body.value.bytes)) === "arg") {
        const argId = svId(e.val);
        const argTable = argId !== null ? byId.get(argId) : null;
        if (argTable && argTable.obj_type === 1) {
          argTable.body.value.entries = argTable.body.value.entries.filter(
            (ae: any) => !(ae.key.tag === 2 && ae.key.body.value.v === 0n),
          );
        }
      }
    }
  }

  // Assign each reachable object a canonical index in BFS-from-roots order. `visit`
  // returns the (stable) index, enqueueing the object the first time it's seen; a
  // strict FIFO walk means dequeue order == index order, so the emitted list lines
  // up with the indices the edges reference.
  const canon = new Map<number, number>();
  const queue: number[] = [];
  const visit = (id: number | null): number | null => {
    if (id === null || !byId.has(id)) return null;
    const existing = canon.get(id);
    if (existing !== undefined) return existing;
    const idx = canon.size;
    canon.set(id, idx);
    queue.push(id);
    return idx;
  };
  // A SnapValue → canonical form. Heap ref → traversal index; int64 → exact decimal
  // (lossless past 2^53); float64 → raw bits (NaN/±Inf/−0 distinguished); nil/bool
  // pass through their scalar body.
  const canonSv = (sv: any): any => {
    switch (sv.tag) {
      case 4:
        return { ref: visit(Number(sv.body.value.id)) };
      case 2:
        return { i64: sv.body.value.v.toString() };
      case 3:
        return { f64: f64Bits(sv.body.value.v) };
      default:
        return { tag: sv.tag, body: sv.body };
    }
  };

  const roots = {
    globals: visit(Number(kf.globals_id)),
    string_metatable: Number(kf.string_metatable_id) > 0 ? visit(Number(kf.string_metatable_id) - 1) : -1,
    stack: kf.stack.map(canonSv),
    frames: kf.frames.map((fr: any) => ({ closure: visit(Number(fr.closure_id)), pc: fr.pc, base: fr.base, ret_dest: fr.ret_dest, ret_count: fr.ret_count })),
    open_upvalues: kf.open_upvalues.map((uv: any) => ({ stack_index: uv.stack_index, upvalue: visit(Number(uv.upvalue_id)) })),
  };

  const objects: any[] = [];
  for (let i = 0; i < queue.length; i++) {
    const o = byId.get(queue[i]);
    if (!o) continue;
    let body: any;
    switch (o.obj_type) {
      case 0: // string
        body = { str: Array.from(new Uint8Array(o.body.value.bytes)) };
        break;
      case 1: { // table
        const t = o.body.value;
        body = {
          array: t.array.map(canonSv),
          entries: t.entries.map((e: any) => ({ key: canonSv(e.key), val: canonSv(e.val) })),
          metatable: Number(t.metatable_id) > 0 ? visit(Number(t.metatable_id) - 1) : -1,
        };
        break;
      }
      case 2: // closure
        body = { proto_id: o.body.value.proto_id, upvalues: o.body.value.upvalue_ids.map((u: any) => visit(Number(u))) };
        break;
      case 3: // native
        body = { name: Array.from(new Uint8Array(o.body.value.name)) };
        break;
      case 4: // upvalue
        body = { closed: o.body.value.closed, value: canonSv(o.body.value.value) };
        break;
      default:
        body = { unknown: o.obj_type };
    }
    objects.push({ obj_type: o.obj_type, body });
  }

  // Runtime-`load`ed chunks are order-significant metadata with no object ids to
  // relabel — emit them verbatim (in load order) so differing loaded source/name
  // is not masked (finding: keyframeSansArg previously omitted them entirely).
  const loaded_chunks = kf.loaded_chunks.map((c: any) => ({
    source: Array.from(new Uint8Array(c.source)),
    name: Array.from(new Uint8Array(c.name)),
  }));

  return JSON.stringify({ roots, objects, loaded_chunks }, jsonReplacer);
}

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
    // The keyframe is compared structurally with the global `arg` table excluded
    // (see the module header): native's `arg[0]` = script path never byte-matches
    // wasm's empty arg, but that's an embedding difference, not a determinism one.
    // effects/trace stay byte-exact.
    let firstDiffByte: number | null;
    if (name === "keyframe") {
      firstDiffByte = keyframeSansArg(w) === keyframeSansArg(n) ? null : 0;
    } else {
      firstDiffByte = compareBytes(w, n);
    }
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
