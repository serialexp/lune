// Keyframe-snapshot → human-readable view, for the step-debugger's state panels.
//
// A replay step (`mahina_replay`) returns a whole-VM keyframe blob: every unswept
// heap object (id-keyed), the live register window, and the active frames
// (src/keyframeser.zig). This module decodes that blob with the generated
// `SnapshotFileDecoder` and projects out the two things the UI shows directly —
// the global environment and the deepest frame's locals — formatting each Value
// exactly as the trace/const views do (reusing `disasm.ts`'s value formatters).
//
// It deliberately does NOT try to reconstruct the whole heap: a HeapRef renders
// as a compact tag (`"str"`, `table#7`, `function#3`), which is enough to see how
// state evolves without drawing the object graph.

import {
  SnapshotFileDecoder,
  type SnapValueOutput,
  type HeapObjectOutput,
} from "./gen/generated";
import { bytesToDisplay, floatToDisplay } from "./disasm";

/** One named global or indexed local, value pre-formatted for display. */
export interface NamedValue {
  /** Global name, or `r<slot>` for a local register. */
  label: string;
  /** Formatted value (`42`, `"hi"`, `true`, `table#7`, …). */
  value: string;
  /** A local register no path from the pending instruction reads before
   *  writing it. The keyframe carries a tombstone for it, not a value
   *  (doc 61 Phase K), so `value` is a placeholder. */
  dead?: boolean;
}

/** The projected state at one replay step. */
export interface SnapshotView {
  /** User-visible globals (string-keyed entries of the globals table). */
  globals: NamedValue[];
  /** The deepest (currently-executing) frame's register window. */
  locals: NamedValue[];
}

/** SnapValue.tag ordinals (mirror src/value.zig Value.Tag — see the schema doc). */
const enum Tag {
  Nil = 0,
  Bool = 1,
  Int = 2,
  Float = 3,
  HeapRef = 4,
}

/** HeapObject.obj_type ordinals (mirror the schema's HeapObject union order). */
const enum ObjType {
  String = 0,
  Table = 1,
  Closure = 2,
  Native = 3,
  Upvalue = 4,
}

/** A short tag for a heap object reference, given the resolved object (or null
 *  if the id wasn't in the snapshot — should not happen for a reachable graph). */
function heapRefDisplay(id: number, obj: HeapObjectOutput | undefined): string {
  if (!obj) return `#${id}`;
  switch (obj.body.type) {
    case "HeapString":
      return `"${bytesToDisplay(obj.body.value.bytes)}"`;
    case "HeapTable":
      return `table#${id}`;
    case "HeapClosure":
      return `function#${id}`;
    case "HeapNative":
      return `native#${id}`;
    case "HeapUpvalue":
      return `upvalue#${id}`;
    default:
      return `#${id}`;
  }
}

/** Format a snapshot Value for display, resolving heap refs against `objects`. */
function valueDisplay(v: SnapValueOutput, objects: Map<number, HeapObjectOutput>): string {
  switch (v.tag) {
    case Tag.Nil:
      return "nil";
    case Tag.Bool:
      return v.body.type === "ConstBool" && v.body.value.v !== 0 ? "true" : "false";
    case Tag.Int:
      return v.body.type === "ConstInt" ? v.body.value.v.toString() : "?";
    case Tag.Float:
      return v.body.type === "ConstFloat" ? floatToDisplay(v.body.value.v) : "?";
    case Tag.HeapRef:
      if (v.body.type === "HeapRef") return heapRefDisplay(v.body.value.id, objects.get(v.body.value.id));
      return "?";
    default:
      return "?";
  }
}

/** The bare display of a table key: a string key shows unquoted (it's a name);
 *  any other key falls back to its value form. */
function keyDisplay(k: SnapValueOutput, objects: Map<number, HeapObjectOutput>): string {
  if (k.tag === Tag.HeapRef && k.body.type === "HeapRef") {
    const obj = objects.get(k.body.value.id);
    if (obj && obj.body.type === "HeapString") return bytesToDisplay(obj.body.value.bytes);
  }
  return valueDisplay(k, objects);
}

/**
 * Decode a keyframe blob and project the globals + deepest-frame locals. Returns
 * null if the blob is empty or fails to decode (the caller then shows nothing).
 * A local whose slot is a `DeadSlot` tombstone is marked `dead`.
 */
export function decodeSnapshot(blob: Uint8Array): SnapshotView | null {
  if (blob.length === 0) return null;
  let kf;
  try {
    kf = new SnapshotFileDecoder(blob).decode().keyframe;
  } catch {
    return null;
  }

  const objects = new Map<number, HeapObjectOutput>();
  for (const o of kf.objects) objects.set(o.id, o);

  // Globals: the string-keyed (hash-part) entries of the globals table.
  const globals: NamedValue[] = [];
  const globalsObj = objects.get(kf.globals_id);
  if (globalsObj && globalsObj.body.type === "HeapTable") {
    for (const e of globalsObj.body.value.entries) {
      globals.push({ label: keyDisplay(e.key, objects), value: valueDisplay(e.val, objects) });
    }
    globals.sort((a, b) => a.label.localeCompare(b.label));
  }

  // Locals: the deepest frame's register window. The live stack is captured as
  // `stack[0..stack_top]`; the deepest frame spans `[base, stack_top)`, so that
  // tail slice is exactly its registers (src/keyframeser.zig).
  const locals: NamedValue[] = [];
  if (kf.frames.length > 0) {
    const base = kf.frames[kf.frames.length - 1].base;
    for (let i = base; i < kf.stack.length; i++) {
      const label = `r${i - base}`;
      const sv = kf.stack[i];
      if (sv.body.type === "DeadSlot") {
        locals.push({ label, value: "—", dead: true });
      } else {
        locals.push({ label, value: valueDisplay(sv as SnapValueOutput, objects) });
      }
    }
  }

  return { globals, locals };
}
