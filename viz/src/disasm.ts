// Pure rendering of a decoded trace into a structural view-model + text form.
//
// This mirrors `src/trace.zig`'s `writeIrInstr` / `writeTrace` so the web view
// matches `lune --dump-traces`. It is DOM-free and side-effect-free, so the
// cross-language decode test can assert on it directly.

import type { TraceFileOutput, TraceOutput, ConstValueOutput } from "./gen/generated";
import { irOpName, obsTypeName, NO_OPERAND_OPS, UNARY_OR_GUARD_OPS } from "./enums";

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
  anchorProtoId: number;
  anchorPc: number;
  /** `entry=[r0 r4 …]` slot list. */
  entrySlots: number[];
  instrs: InstrRow[];
  consts: ConstRow[];
  /** Loop-carried writebacks `rSlot<-%ref`. */
  exitStores: { slot: number; ref: number }[];
}

/** Render one instruction's operand column, exactly as `writeIrInstr` does. */
function operandsOf(opName: string, a: number, b: number, aux: number): string {
  if (opName === "slot_load") return `r${aux}`;
  if (opName === "konst") return `k${aux}`;
  if (NO_OPERAND_OPS.has(opName as never)) return "";
  if (UNARY_OR_GUARD_OPS.has(opName as never)) return `%${a}`;
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

function floatToDisplay(v: number): string {
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
    anchorProtoId: t.anchor_proto_id,
    anchorPc: t.anchor_pc,
    entrySlots: t.entry_slots,
    instrs,
    consts,
    exitStores: t.exit_stores.map((s) => ({ slot: s.slot, ref: s.ref })),
  };
}

export function viewsOf(file: TraceFileOutput): TraceView[] {
  return file.traces.map(traceToView);
}

/**
 * Reproduce `lune --dump-traces` body text for one trace (header uses the proto
 * *id*, since the artifact has no proto name). Columns match `writeTrace`:
 * `  %NNN  <op padded to 13><operands>` and `  exit: rS<-%R …`.
 */
export function traceToText(t: TraceOutput): string {
  const v = traceToView(t);
  const lines: string[] = [];
  lines.push(`trace ${v.anchorProtoId}:${v.anchorPc}  entry=[${v.entrySlots.map((s) => `r${s}`).join(" ")}]`);
  for (const row of v.instrs) {
    lines.push(`  %${row.index}  ${row.op.padEnd(13)}${row.operands}`);
  }
  if (v.exitStores.length > 0) {
    lines.push("  exit:" + v.exitStores.map((s) => ` r${s.slot}<-%${s.ref}`).join(""));
  }
  return lines.join("\n") + "\n";
}
