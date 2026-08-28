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

/** IR opcodes, indexed by wire ordinal (mirrors trace.IrOp, 0..56). */
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
  "guard_builtin", // 45
  "fsqrt", // 46
  "sar", // 47  (~>> arithmetic right shift; appended at the enum end)
  // Flattened-grid cell access (doc 14, Phase 8); appended at the enum end so
  // wire ordinals 0..47 are undisturbed.
  "garow", // 48  (table, row) → row-base address
  "gcell", // 49  (garow, col) → cell address
  "gload", // 50  load grid cell
  "gstore", // 51  store grid cell
  "guard_grid", // 52  container still an int grid at the recorded element lane
  "guard_stride", // 53  grid stride still equals the recorded value
  "guard_gcol", // 54  column in [1, stride]
  "guard_gpresent", // 55  cell present
  // Nested-loop trace linking (doc 15, Phase 2); appended at the enum end so wire
  // ordinals 0..55 are undisturbed.
  "link", // 56  terminal hand-off to an inner root trace (aux = inner anchor pc)
  // Builtin recording breadth (doc 23, arc A); appended at the enum end so wire
  // ordinals 0..56 are undisturbed.
  "alen", // 57  `#t` fast-case border: max(asize-1, 0), side-exits otherwise
  "fsin", // 58  math.sin via the shared noinline fmath kernel (never folded)
  "fcos", // 59  math.cos via the shared noinline fmath kernel (never folded)
  // Deterministic on-trace allocation (doc 24, arc B); appended at the enum end
  // so wire ordinals 0..59 are undisturbed.
  "tostr_int", // 60  interned decimal rendering of a proven int (allocating)
  "tostr_num", // 61  interned rendering of a proven float (allocating)
  "slen", // 62  #s of a proven string: cached cp_len (code points)
  "guard_string", // 63  value is a heap string
  "guard_gc", // 64  allocation-budget entry guard (aux = bound A)
  "ssub", // 65  string.sub(s, i, j) — third operand rides aux as a ref
  "srev", // 66  string.reverse(s)
  "schar1", // 67  1-arg string.char(c)
  "srep2", // 68  2-arg string.rep(s, n)
  "supper", // 69  string.upper(s) — full Unicode simple case map (allocating)
  "slower", // 70  string.lower(s) — ditto
  "scp", // 71  single-result string.codepoint(s, i, j) — third operand rides aux as a ref
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

/** Value tags, indexed by wire ordinal (mirrors value.Tag, 0..5). */
export const VALUE_TAG_NAMES = [
  "nil", // 0
  "boolean", // 1
  "int", // 2
  "float", // 3
  "heap_ref", // 4
  // 5: a transient grid row handle (doc 14). Never actually serialized — it
  // inflates to a real table before persisting — but the ordinal is reserved so
  // the wire contract stays aligned with value.Tag.
  "row_view", // 5
] as const;

export type ValueTagName = (typeof VALUE_TAG_NAMES)[number];

/** Opcodes that take no operand columns (the loop back-edge terminator and the
 * preheader region boundary — both pure structural markers). */
export const NO_OPERAND_OPS: ReadonlySet<IrOpName> = new Set([
  "loop",
  "preheader",
  "link",
  // guard_gc is operand-free: aux carries the allocation bound A (doc 24).
  "guard_gc",
]);

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
  "guard_builtin",
  "fsqrt",
  "fsin",
  "fcos",
  "alen",
  "tostr_int",
  "tostr_num",
  "slen",
  "guard_string",
  "srev",
  "schar1",
  "supper",
  "slower",
  // Single-operand grid ops (doc 14): the cell load + three structural guards
  // render `%a`. garow/gcell/gstore/guard_gcol are two-operand (guard_gcol carries
  // the column ref in `%b`) and use the default `%a, %b`.
  "gload",
  "guard_grid",
  "guard_stride",
  "guard_gpresent",
]);

/** Three-operand ops whose third operand rides `aux` as a ref (mirrors
 * `writeIrInstr`'s `%a  %b  %aux` arm): `ssub` (doc 24 codex #4) and `scp`
 * (doc 26 D3). */
export const TERNARY_AUX_OPS: ReadonlySet<IrOpName> = new Set(["ssub", "scp"]);

/** Map a raw wire ordinal to a name, falling back to `op:N` if out of range. */
export function irOpName(op: number): string {
  return IR_OP_NAMES[op] ?? `op:${op}`;
}

export function obsTypeName(ty: number): string {
  return OBS_TYPE_NAMES[ty] ?? `ty:${ty}`;
}
