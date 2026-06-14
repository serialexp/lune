// Exec-log view model: the per-trace execution log (fourth record family)
// flattened into one linear event stream the TraceView animates, plus value
// rendering. DOM-free and side-effect-free — the trace IR table reads this to
// light up rows as recorded execution flows through the trace.

import type { TraceExecLogOutput, ExecEventOutput } from "./decode";
import { bytesToDisplay, floatToDisplay } from "./disasm";

/** Event kinds, mirroring `src/execlog.zig`'s `ExecEventKind`. */
export const ExecEventKind = { Value: 0, GuardPass: 1, Commit: 2, Exit: 3 } as const;
/** Exit-ramp kinds, mirroring `src/execlog.zig`'s `ExitKind`. */
export const ExitKind = { Guard: 0, Arith: 1, Clean: 2 } as const;

/** One position in the flattened stream: an event plus the index of the trace
 *  entry (exit ramp) it belongs to, so the readout can name the entry. */
export interface ExecStep {
  entryIndex: number;
  event: ExecEventOutput;
}

/** Flatten a per-trace exec log into one linear event stream (its entries
 *  concatenated in order), so a single slider scrubs the whole recorded run —
 *  mirroring how `replayStops` linearizes the step-replay. */
export function flattenExec(log: TraceExecLogOutput): ExecStep[] {
  const steps: ExecStep[] = [];
  log.entries.forEach((entry, ei) => {
    for (const ev of entry.events) steps.push({ entryIndex: ei, event: ev });
  });
  return steps;
}

/** Render an event's `EffectResult` value to a short display string (same
 *  conventions as the const pool). */
export function formatExecValue(v: ExecEventOutput["value"]): string {
  switch (v.body.type) {
    case "ConstNil":
      return "nil";
    case "ConstBool":
      return v.body.value.v !== 0 ? "true" : "false";
    case "ConstInt":
      return v.body.value.v.toString();
    case "ConstFloat":
      return floatToDisplay(v.body.value.v);
    case "ConstString":
      return `"${bytesToDisplay(v.body.value.v)}"`;
  }
}

/** Human label for an exit-ramp kind. */
export function exitKindLabel(k: number): string {
  switch (k) {
    case ExitKind.Guard:
      return "guard";
    case ExitKind.Arith:
      return "arith";
    case ExitKind.Clean:
      return "clean";
    default:
      return "?";
  }
}
