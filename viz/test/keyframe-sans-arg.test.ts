// Regression tests for keyframeSansArg (viz/src/diff.ts) — the structural
// keyframe normalizer the cross-engine differential validator uses to cancel the
// host-injected `arg[0]` (script path) without a byte compare. A codex review
// found the first cut of that normalizer masked *real* divergences it should have
// surfaced: i64 values collapsed through `Number` (equal above 2^53), float64
// specials folded by JSON (NaN/±Inf → null, −0 → 0), `loaded_chunks` omitted
// entirely, and the whole `arg` table cleared (hiding arg[1..]). These tests pin
// that keyframeSansArg now distinguishes each of those while still cancelling
// arg[0]. Keyframes are built with the generated encoder — no VM run needed.

import { test, expect } from "bun:test";
import { SnapshotFileEncoder, type SnapValueInput, type HeapObjectInput, type TableEntryInput } from "../src/gen/generated";
import { keyframeSansArg } from "../src/diff";

const enc = (s: string): number[] => Array.from(new TextEncoder().encode(s));

const sInt = (v: bigint): SnapValueInput => ({ tag: 2, body: { type: "ConstInt", value: { v } } });
const sFloat = (v: number): SnapValueInput => ({ tag: 3, body: { type: "ConstFloat", value: { v } } });
const sRef = (id: number): SnapValueInput => ({ tag: 4, body: { type: "HeapRef", value: { id } } });

/** A tiny heap builder: allocates ids sequentially, returns the encoded bytes. */
class Kf {
  objs: HeapObjectInput[] = [];
  private id = 0;
  str(s: string): number {
    const i = this.id++;
    this.objs.push({ id: i, obj_type: 0, body: { type: "HeapString", value: { bytes: enc(s) } } });
    return i;
  }
  tbl(array: SnapValueInput[], entries: TableEntryInput[]): number {
    const i = this.id++;
    this.objs.push({ id: i, obj_type: 1, body: { type: "HeapTable", value: { array, entries, metatable_id: 0 } } });
    return i;
  }
  encode(globalsId: number, loaded: { source: string; name: string }[] = []): Uint8Array {
    return new SnapshotFileEncoder().encode({
      version: 1,
      keyframe: {
        globals_id: globalsId,
        string_metatable_id: 0,
        objects: this.objs,
        stack: [],
        frames: [],
        open_upvalues: [],
        loaded_chunks: loaded.map((l) => ({ source: enc(l.source), name: enc(l.name) })),
      },
    });
  }
}

/** globals = { name: val } — one scalar global under a string key. */
function scalarGlobal(name: string, val: SnapValueInput, loaded: { source: string; name: string }[] = []): Uint8Array {
  const kf = new Kf();
  const keyId = kf.str(name);
  const gid = kf.tbl([], [{ key: sRef(keyId), val }]);
  return kf.encode(gid, loaded);
}

test("i64 globals above 2^53 are NOT collapsed (Number would have folded them)", () => {
  const a = 9007199254740992n; // 2^53
  const b = 9007199254740993n; // 2^53 + 1
  // Precondition: a plain Number cast — the old bug — makes these indistinguishable.
  expect(Number(a)).toBe(Number(b));
  expect(keyframeSansArg(scalarGlobal("n", sInt(a)))).not.toBe(keyframeSansArg(scalarGlobal("n", sInt(b))));
  // Sanity: identical i64s still compare equal.
  expect(keyframeSansArg(scalarGlobal("n", sInt(a)))).toBe(keyframeSansArg(scalarGlobal("n", sInt(a))));
});

test("float64 specials are distinguished (JSON would fold them)", () => {
  const negZero = keyframeSansArg(scalarGlobal("x", sFloat(-0)));
  const posZero = keyframeSansArg(scalarGlobal("x", sFloat(0)));
  const nan = keyframeSansArg(scalarGlobal("x", sFloat(NaN)));
  const posInf = keyframeSansArg(scalarGlobal("x", sFloat(Infinity)));
  const negInf = keyframeSansArg(scalarGlobal("x", sFloat(-Infinity)));
  // −0 vs +0, NaN vs a number, +Inf vs −Inf — all folded to the same JSON token
  // (`0` / `null`) under the old replacer; the raw-bit encoding keeps them apart.
  expect(negZero).not.toBe(posZero);
  expect(nan).not.toBe(posInf);
  expect(posInf).not.toBe(negInf);
  // A finite value still round-trips to itself.
  expect(keyframeSansArg(scalarGlobal("x", sFloat(1.5)))).toBe(keyframeSansArg(scalarGlobal("x", sFloat(1.5))));
});

test("loaded_chunks differences are not masked", () => {
  const base = scalarGlobal("n", sInt(1n), [{ source: "return 1", name: "=c" }]);
  const diffSource = scalarGlobal("n", sInt(1n), [{ source: "return 2", name: "=c" }]);
  const diffName = scalarGlobal("n", sInt(1n), [{ source: "return 1", name: "=d" }]);
  const none = scalarGlobal("n", sInt(1n), []);
  expect(keyframeSansArg(base)).not.toBe(keyframeSansArg(diffSource));
  expect(keyframeSansArg(base)).not.toBe(keyframeSansArg(diffName));
  expect(keyframeSansArg(base)).not.toBe(keyframeSansArg(none));
  expect(keyframeSansArg(base)).toBe(keyframeSansArg(scalarGlobal("n", sInt(1n), [{ source: "return 1", name: "=c" }])));
});

// Build globals = { arg = {0=path, [extra…]} }. arg[0] is the host-injected slot.
function withArg(path: string, extra: TableEntryInput[] = []): Uint8Array {
  const kf = new Kf();
  const pathId = kf.str(path);
  const argEntries: TableEntryInput[] = [{ key: sInt(0n), val: sRef(pathId) }, ...extra];
  const argId = kf.tbl([], argEntries);
  const argKeyId = kf.str("arg");
  const gid = kf.tbl([], [{ key: sRef(argKeyId), val: sRef(argId) }]);
  return kf.encode(gid);
}

test("arg[0] (script path) is cancelled — two paths compare equal", () => {
  expect(keyframeSansArg(withArg("/tmp/aaa/p.lune"))).toBe(keyframeSansArg(withArg("/tmp/zzz/other.lune")));
});

test("arg[1..] is preserved — a real divergence there still surfaces", () => {
  // Path strings differ (arg[0], cancelled) AND arg[1] differs; only arg[1] counts.
  expect(keyframeSansArg(withArgWith("realA"))).not.toBe(keyframeSansArg(withArgWith("realB")));
  // Control: same arg[1], differing path → equal (only the path was cancelled).
  expect(keyframeSansArg(withArgWith("same"))).toBe(keyframeSansArg(withArgWith("same")));
});

/** globals = { arg = {0="/p", 1=<real>} } with distinct path per call. */
let argPathCounter = 0;
function withArgWith(realOne: string): Uint8Array {
  const kf = new Kf();
  const realId = kf.str(realOne);
  const pathId = kf.str(`/tmp/path-${argPathCounter++}`);
  const argId = kf.tbl([], [
    { key: sInt(0n), val: sRef(pathId) },
    { key: sInt(1n), val: sRef(realId) },
  ]);
  const argKeyId = kf.str("arg");
  const gid = kf.tbl([], [{ key: sRef(argKeyId), val: sRef(argId) }]);
  return kf.encode(gid);
}
