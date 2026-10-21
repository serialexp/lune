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

/** The `.mahinatrace` wire version this viewer reads (`traceser.format_version`).
 *  The fixture tests decode a CLI-produced trace, so a bump on the Zig side
 *  that isn't mirrored here fails them. */
export const TRACE_FORMAT_VERSION = 5;

/** Decode a `.mahinatrace` byte buffer into its structural form. Strict, so a
 *  file that isn't one fails with a reason instead of decoding into garbage:
 *  the version word must be this viewer's, and the traces must use up the
 *  buffer exactly. (The format has no magic bytes, and the other artifact
 *  families start with small version words too, so the version check alone
 *  can't tell them apart — the exact-length check does the rest.) */
export function decodeTraceFile(bytes: Uint8Array): TraceFileOutput {
  const notTrace = "not a .mahinatrace";
  if (bytes.length < 8) throw new Error(`${notTrace}: only ${bytes.length} byte(s)`);
  const version = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength).getUint32(0, true);
  if (version !== TRACE_FORMAT_VERSION) {
    throw new Error(`${notTrace} this viewer reads: version word ${version}, expected ${TRACE_FORMAT_VERSION}`);
  }
  const decoder = new TraceFileDecoder(bytes);
  let file: TraceFileOutput;
  try {
    file = decoder.decode();
  } catch (e) {
    throw new Error(`${notTrace}: ${e instanceof Error ? e.message : String(e)}`);
  }
  if (decoder.hasMore()) {
    throw new Error(`${notTrace}: ${bytes.length - decoder.byteOffset} byte(s) left over after the traces`);
  }
  return file;
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
