// Wire-ordinal → name tables for the raw `uint8` enum fields in a .lunetrace
// (`IrInstr.op`, `IrInstr.ty`, `ConstValue.tag`).
//
// These mirror, BY POSITION, the Zig enums `trace.IrOp`, `trace.ObsType`, and
// `value.Tag`. The mapping is a wire contract: the test
//   "wire enum ordinals are a pinned contract (mirrored by viz/src/enums.ts)"
// in src/traceser.zig pins each ordinal, so reordering an enum on the VM side
// fails the Zig suite and signals that these tables must change in lockstep.
// (Future hardening: generate this file from Zig @typeInfo reflection so it
// cannot drift at all — see docs/design/04-snapshot-replay-schema.md.)

/** IR opcodes, indexed by wire ordinal (mirrors trace.IrOp, 0..47). */
export const IR_OP_NAMES = [
  "slot_load", // 0
  "konst", // 1
  "add", // 2
  "sub", // 3
  "mul", // 4
  "div", // 5
  "idiv", // 6
  "mod", // 7
  "pow", // 8
  "band", // 9
  "bor", // 10
  "bxor", // 11
  "shl", // 12
  "shr", // 13
  "neg", // 14
  "not", // 15
  "bnot", // 16
  "eq", // 17
  "ne", // 18
  "lt", // 19
  "le", // 20
  "guard_int", // 21
  "guard_float", // 22
  "guard_number", // 23
  "guard_true", // 24
  "guard_false", // 25
  "aref", // 26
  "aload", // 27
  "astore", // 28
  "guard_table", // 29
  "guard_lane", // 30
  "guard_bounds", // 31
  "guard_present", // 32
  "guard_fits", // 33
  "loop", // 34
  "phi", // 35
  "preheader", // 36
  "int_of_float", // 37
  "guard_append", // 38
  "astore_append", // 39
  "guard_func", // 40
  "href", // 41
  "hload", // 42
  "hstore", // 43
  "guard_hash", // 44
  "guard_pure", // 45
  "fsqrt", // 46
  "sar", // 47  (~>> arithmetic right shift; appended at the enum end)
] as const;

export type IrOpName = (typeof IR_OP_NAMES)[number];

/** Observed/result types, indexed by wire ordinal (mirrors trace.ObsType, 0..5). */
export const OBS_TYPE_NAMES = [
  "unknown", // 0
  "int", // 1
  "float", // 2
  "boolean", // 3
  "nil", // 4
  "heap", // 5
] as const;

export type ObsTypeName = (typeof OBS_TYPE_NAMES)[number];

/** Value tags, indexed by wire ordinal (mirrors value.Tag, 0..4). */
export const VALUE_TAG_NAMES = [
  "nil", // 0
  "boolean", // 1
  "int", // 2
  "float", // 3
  "heap_ref", // 4
] as const;

export type ValueTagName = (typeof VALUE_TAG_NAMES)[number];

/** Opcodes that take no operand columns (the loop back-edge terminator and the
 * preheader region boundary — both pure structural markers). */
export const NO_OPERAND_OPS: ReadonlySet<IrOpName> = new Set(["loop", "preheader"]);

/** Unary ops + guards: render a single operand `%a`. (`aref` is two-operand and
 * falls through to the default `%a, %b` rendering.) */
export const UNARY_OR_GUARD_OPS: ReadonlySet<IrOpName> = new Set([
  "neg",
  "not",
  "bnot",
  "guard_int",
  "guard_float",
  "guard_number",
  "guard_true",
  "guard_false",
  "aload",
  "guard_table",
  "guard_lane",
  "guard_bounds",
  "guard_present",
  "guard_fits",
  "int_of_float",
  "guard_append",
  "hload",
  "guard_hash",
  "guard_pure",
  "fsqrt",
]);

/** Map a raw wire ordinal to a name, falling back to `op:N` if out of range. */
export function irOpName(op: number): string {
  return IR_OP_NAMES[op] ?? `op:${op}`;
}

export function obsTypeName(ty: number): string {
  return OBS_TYPE_NAMES[ty] ?? `ty:${ty}`;
}
