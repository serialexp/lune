// Pure rendering of a decoded trace into a structural view-model + text form.
//
// This mirrors `src/trace.zig`'s `writeIrInstr` / `writeTrace` so the web view
// matches `mahina --dump-traces`. It is DOM-free and side-effect-free, so the
// cross-language decode test can assert on it directly.

import type { TraceFileOutput, TraceOutput, ConstValueOutput } from "./gen/generated";
import {
  irOpName,
  obsTypeName,
  NO_OPERAND_OPS,
  UNARY_OR_GUARD_OPS,
  TERNARY_AUX_OPS,
  TERMINAL_KIND_NAMES,
} from "./enums";

/** The decoded `ConstValue.body` `{ type, value }` envelope, straight from the
 * generated decoder — a discriminated union keyed on `type`. */
type ConstBody = ConstValueOutput["body"];

export interface InstrRow {
  /** Zero-padded SSA index, e.g. "007". */
  index: string;
  op: string;
  operands: string;
  /** Result/guard type name; omitted (empty) when `unknown`. */
  ty: string;
  /** Deopt snapshot index — only meaningful for guards. */
  snap: number;
}

export interface ConstRow {
  /** Pool index, e.g. "k0". */
  slot: string;
  /** Variant name (int/float/boolean/nil/string). */
  kind: string;
  /** Display value. */
  text: string;
}

export interface TraceView {
  /** Stable `Trace.id` (wire v5) — the key exec logs join on; not a cache position. */
  id: number;
  anchorProtoId: number;
  anchorPc: number;
  /** Non-zero when the trace starts with a type-stabilizing peeled iteration. */
  peeled: number;
  /** `entry=[r0 r4 …]` slot list. */
  entrySlots: number[];
  instrs: InstrRow[];
  consts: ConstRow[];
}

/** Sentinel `phi.aux` for an internal (slot-less) φ — mirrors `trace.PHI_INTERNAL`. */
const PHI_INTERNAL = -1;

/** Render one instruction's operand column, exactly as `writeIrInstr` does. */
function operandsOf(opName: string, a: number, b: number, aux: number): string {
  if (opName === "slot_load") return `r${aux}`;
  // Doc 43 P5: uref prints its seed slot like slot_load (`writeIrInstr` parity).
  if (opName === "uref") return `r${aux}`;
  // Doc 44: terminal prints its kind tag + resume pc (`writeIrInstr` parity).
  if (opName === "terminal") return `${TERMINAL_KIND_NAMES[a] ?? `kind:${a}`} @ ${aux}`;
  if (opName === "konst") return `k${aux}`;
  // φ: slot-bound prints `update=%b -> r{slot}`; internal prints
  // `init=%a update=%b -> internal` (the loop-carried writeback rides the stream).
  if (opName === "phi") {
    return aux === PHI_INTERNAL
      ? `init=%${a} update=%${b} -> internal`
      : `update=%${b} -> r${aux}`;
  }
  if (NO_OPERAND_OPS.has(opName as never)) return "";
  if (UNARY_OR_GUARD_OPS.has(opName as never)) return `%${a}`;
  // ssub/scp: the third operand rides aux as a ref (doc 24 codex #4 / doc 26).
  if (TERNARY_AUX_OPS.has(opName as never)) return `%${a}  %${b}  %${aux}`;
  return `%${a}  %${b}`;
}

/** Decode a byte-string const to a printable form (ASCII as-is, else `\xNN`). */
export function bytesToDisplay(bytes: number[]): string {
  let out = "";
  for (const c of bytes) {
    if (c >= 0x20 && c < 0x7f && c !== 0x5c) out += String.fromCharCode(c);
    else if (c === 0x5c) out += "\\\\";
    else out += "\\x" + c.toString(16).padStart(2, "0");
  }
  return out;
}

function constToRow(index: number, body: ConstBody): ConstRow {
  const slot = `k${index}`;
  switch (body.type) {
    case "ConstNil":
      return { slot, kind: "nil", text: "nil" };
    case "ConstBool":
      return { slot, kind: "boolean", text: body.value.v !== 0 ? "true" : "false" };
    case "ConstInt":
      return { slot, kind: "int", text: body.value.v.toString() };
    case "ConstFloat":
      return { slot, kind: "float", text: floatToDisplay(body.value.v) };
    case "ConstString":
      return { slot, kind: "string", text: `"${bytesToDisplay(body.value.v)}"` };
  }
}

export function floatToDisplay(v: number): string {
  if (Number.isNaN(v)) return "nan";
  if (v === Infinity) return "inf";
  if (v === -Infinity) return "-inf";
  // Preserve -0.0 visibly.
  if (v === 0 && 1 / v === -Infinity) return "-0";
  return String(v);
}

/** Build the structural view-model for a single decoded trace. */
export function traceToView(t: TraceOutput): TraceView {
  const instrs: InstrRow[] = t.instrs.map((ins, i) => {
    const op = irOpName(ins.op);
    const tyName = obsTypeName(ins.ty);
    return {
      index: i.toString().padStart(3, "0"),
      op,
      operands: operandsOf(op, ins.a, ins.b, ins.aux),
      ty: tyName === "unknown" ? "" : tyName,
      snap: ins.snap,
    };
  });

  const consts: ConstRow[] = t.consts.map((c, i) => constToRow(i, c.body));

  return {
    id: t.id,
    anchorProtoId: t.anchor_proto_id,
    anchorPc: t.anchor_pc,
    peeled: t.peeled,
    entrySlots: t.entry_slots,
    instrs,
    consts,
  };
}

export function viewsOf(file: TraceFileOutput): TraceView[] {
  return file.traces.map(traceToView);
}

/**
 * Reproduce `mahina --dump-traces` body text for one trace (header uses the proto
 * *id*, since the artifact has no proto name). Columns match `writeTrace`:
 * `  %NNN  <op padded to 13><operands>`. Loop-carried writebacks now ride the
 * instruction stream as slot-bound `phi` rows (no separate `exit:` line).
 */
export function traceToText(t: TraceOutput): string {
  const v = traceToView(t);
  const lines: string[] = [];
  lines.push(`trace ${v.anchorProtoId}:${v.anchorPc}  entry=[${v.entrySlots.map((s) => `r${s}`).join(" ")}]`);
  for (const row of v.instrs) {
    lines.push(`  %${row.index}  ${row.op.padEnd(13)}${row.operands}`);
  }
  return lines.join("\n") + "\n";
}
