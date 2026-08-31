// Thin wrapper over the generated binschema decoder. The generated codec
// (src/gen/generated.ts) is produced from schema/trace.json by
// tools/regen-trace-schema.sh and vendored — never hand-edited. This module is
// the one place the app touches it, so a regen that renames things is a
// single-file fix here.

import {
  TraceFileDecoder,
  type TraceFileOutput,
  type TraceOutput,
  ExecLogFileDecoder,
  type ExecLogFileOutput,
  type TraceExecLogOutput,
  type TraceEntryOutput,
  type ExecEventOutput,
  CoverageFileDecoder,
  type CoverageFileOutput,
  type CoverageAnchorOutput,
  type JitCountersOutput,
} from "./gen/generated";

export type { TraceFileOutput, TraceOutput };
export type { ExecLogFileOutput, TraceExecLogOutput, TraceEntryOutput, ExecEventOutput };
export type { CoverageFileOutput, CoverageAnchorOutput, JitCountersOutput };

/** A single decoded const: a discriminated union tagged by `body.type`. */
export type DecodedConst = TraceOutput["consts"][number];

/** Decode a `.mahinatrace` byte buffer into its structural form. */
export function decodeTraceFile(bytes: Uint8Array): TraceFileOutput {
  return new TraceFileDecoder(bytes).decode();
}

/** Decode a trace **execution-log** blob (the fourth record family) into its
 *  structural form: per-trace logs, each with the per-entry/exit-ramp event
 *  stream the IR-interpreter recorded. Mirrors `decodeTraceFile`. */
export function decodeExecLogFile(bytes: Uint8Array): ExecLogFileOutput {
  return new ExecLogFileDecoder(bytes).decode();
}

/** Decode a JIT **coverage** blob (the fifth record family) into its structural
 *  form: the aggregate native-vs-tier-0 iteration split, the raw JIT event
 *  counters, and the per-anchor (loop-header) breakdown. Mirrors
 *  `decodeTraceFile`. */
export function decodeCoverageFile(bytes: Uint8Array): CoverageFileOutput {
  return new CoverageFileDecoder(bytes).decode();
}
