// Right pane: the selected trace's anchor, entry slots, IR, consts, exits — and,
// when the trace actually executed, an animation of recorded execution flowing
// through the IR. Each slider position is one event from the trace's exec log
// (value landing / guard passing / iteration committed / side-exit). State lives
// in the store (`traceExecSteps`/`traceExecPos`); this component is presentation
// plus the play timer, mirroring ReplayPanel's transport (Rule #9).

import { For, Show, createSignal, createEffect, onCleanup } from "solid-js";
import {
  state,
  selectedTrace,
  selectedTraceExec,
  traceExecSteps,
  setTraceExecPos,
  stepTraceExec,
  traceLoc,
  hoverIrLoc,
  pinIrLoc,
  sameLoc,
  locLabel,
} from "../store";
import type { Loc } from "../store";
import { baseName } from "../paths";
import { ExecEventKind, formatExecValue, exitKindLabel } from "../exec";
import { operandTokens } from "../disasm";

/** Milliseconds between auto-advance steps while playing (matches ReplayPanel). */
const PLAY_INTERVAL_MS = 220;

/** The IR table's line cell: the line number in the entry file, else
 *  `file:line` (the file's last path segment; the cell's title has the path). */
function srcLineCell(loc: Loc | null): string {
  if (loc === null) return "";
  return loc.path === state.entryPath ? `${loc.line}` : `${baseName(loc.path)}:${loc.line}`;
}

export default function TraceView() {
  const trace = selectedTrace;
  const [playing, setPlaying] = createSignal(false);

  // `%N` operand links: hovering one marks the row defining %N, clicking one
  // scrolls to that row and flashes it. Local view state, like `playing`.
  const [hoverRef, setHoverRef] = createSignal(-1);
  const [flashRef, setFlashRef] = createSignal(-1);
  const rowEls: HTMLTableRowElement[] = [];
  let flashTimer: ReturnType<typeof setTimeout> | undefined;
  const goToRef = (ref: number) => {
    rowEls[ref]?.scrollIntoView({ block: "center", behavior: "smooth" });
    setFlashRef(ref);
    clearTimeout(flashTimer);
    flashTimer = setTimeout(() => setFlashRef(-1), 1200);
  };
  onCleanup(() => clearTimeout(flashTimer));

  const steps = () => traceExecSteps();
  const hasAnim = () => steps().length > 0;
  const pos = () => state.traceExecPos;
  const lastPos = () => Math.max(0, steps().length - 1);
  const atEnd = () => pos() >= lastPos();
  const cur = () => steps()[pos()] ?? null;
  const curEvent = () => cur()?.event ?? null;
  const log = () => selectedTraceExec();
  const curEntry = () => {
    const c = cur();
    const l = log();
    return c && l ? (l.entries[c.entryIndex] ?? null) : null;
  };

  // The SSA row index this event lights up, or -1 when the event has no row
  // (a `commit` marks an iteration boundary, not an instruction).
  const curRef = (): number => {
    const ev = curEvent();
    if (!ev) return -1;
    if (ev.kind === ExecEventKind.Commit) return -1;
    return ev.ref;
  };
  const isExit = () => curEvent()?.kind === ExecEventKind.Exit;

  // Doc 39: a PEELED trace's run-once region is a real tier-0 iteration (the
  // type-stabilizing first pass), so the FIRST commit of each entry closes
  // iterations 1–2 at once; every later commit is one iteration as usual.
  const isFirstCommitInEntry = (): boolean => {
    const c = cur();
    if (!c) return false;
    const all = steps();
    for (let i = pos() - 1; i >= 0; i--) {
      const s = all[i];
      if (!s || s.entryIndex !== c.entryIndex) break;
      if (s.event.kind === ExecEventKind.Commit) return false;
    }
    return true;
  };

  // Auto-advance while playing; stop at the final event. Reads the live store
  // position each tick so manual scrubbing mid-play stays coherent.
  createEffect(() => {
    if (!playing()) return;
    const id = setInterval(() => {
      if (state.traceExecPos >= lastPos()) {
        setPlaying(false);
        return;
      }
      stepTraceExec(1);
    }, PLAY_INTERVAL_MS);
    onCleanup(() => clearInterval(id));
  });

  const togglePlay = () => {
    if (atEnd()) setTraceExecPos(0); // replay from the top if parked at the end
    setPlaying((p) => !p);
  };

  // Keep the highlighted IR row in view as stepping moves it.
  let currentRow: HTMLTableRowElement | undefined;
  createEffect(() => {
    void pos(); // track
    if (!hasAnim()) return;
    currentRow?.scrollIntoView({ block: "nearest" });
  });

  // One-line readout describing the current event.
  const readout = (): string => {
    const ev = curEvent();
    if (!ev) return "";
    switch (ev.kind) {
      case ExecEventKind.Value:
        return `%${ev.ref} = ${formatExecValue(ev.value)}`;
      case ExecEventKind.GuardPass:
        return `guard %${ev.ref} passed`;
      case ExecEventKind.Commit:
        return (trace()?.peeled ?? 0) !== 0 && isFirstCommitInEntry()
          ? "iterations 1–2 committed (peeled stabilizing pass) — loop ↺"
          : "iteration committed — loop ↺";
      case ExecEventKind.Exit: {
        const k = curEntry()?.exit_kind ?? 0;
        return `exit ramp @ %${ev.ref} — ${exitKindLabel(k)} side-exit → tier-0`;
      }
      default:
        return "";
    }
  };

  return (
    <Show when={trace()} fallback={<section class="trace-view empty">No trace selected.</section>}>
      {(t) => (
        <section class="trace-view">
          <header class="trace-header">
            <h2>
              JIT trace IR <span class="accent">{t().anchorProtoId}:{t().anchorPc}</span>
              <Show when={traceLoc({ protoId: t().anchorProtoId, pc: t().anchorPc })}>
                {(loc) => <span class="muted"> · starts at {locLabel(loc())}</span>}
              </Show>
            </h2>
            <p class="trace-note muted">
              Optimized SSA recorded for this hot loop — not the tier-0 bytecode
              the step-replay panel above executes.
            </p>
            <div class="entry">
              entry = [
              <For each={t().entrySlots}>{(s, i) => <span> {i() > 0 ? " " : ""}r{s}</span>}</For>
              {" ]"}
            </div>
          </header>

          {/* Trace-iteration animation. Present only when this trace executed
              (hot enough to record an exec log); otherwise the IR table below
              renders statically exactly as before. */}
          <Show
            when={hasAnim()}
            fallback={
              <p class="trace-note muted ir-no-anim">
                {state.execLogsRecorded
                  ? "This trace was recorded but never executed in this run — nothing to animate."
                  : "A .mahinatrace holds the recorded traces only, not how they ran. Open the program and Run (wasm) to animate its traces."}
              </p>
            }
          >
            <div class="ir-anim">
              <div class="ir-transport">
                <button type="button" onClick={() => { setPlaying(false); setTraceExecPos(0); }} disabled={pos() === 0} title="Jump to start" aria-label="Jump to the first trace event">
                  ⏮
                </button>
                <button type="button" onClick={() => { setPlaying(false); stepTraceExec(-1); }} disabled={pos() === 0} title="Step back" aria-label="Previous trace event">
                  ◀
                </button>
                <button type="button" onClick={togglePlay} title={playing() ? "Pause" : "Play"} aria-label={playing() ? "Pause the trace animation" : "Play the trace animation"}>
                  {playing() ? "⏸ pause" : "▶ play"}
                </button>
                <button type="button" onClick={() => { setPlaying(false); stepTraceExec(1); }} disabled={atEnd()} title="Step forward" aria-label="Next trace event">
                  ▶
                </button>
                <button type="button" onClick={() => { setPlaying(false); setTraceExecPos(lastPos()); }} disabled={atEnd()} title="Jump to end" aria-label="Jump to the last trace event">
                  ⏭
                </button>
                <input
                  class="ir-slider"
                  type="range"
                  aria-label="Trace event"
                  min={0}
                  max={lastPos()}
                  step={1}
                  value={pos()}
                  onInput={(e) => { setPlaying(false); setTraceExecPos(e.currentTarget.valueAsNumber); }}
                />
                <span class="ir-pos muted">
                  {pos() + 1} / {steps().length}
                </span>
              </div>
              <div class="ir-readout" classList={{ "ir-readout-exit": isExit() }}>
                <span class="ir-readout-text">{readout()}</span>
                <Show when={curEntry()}>
                  {(e) => (
                    <span class="ir-readout-meta muted">
                      entry {(cur()?.entryIndex ?? 0) + 1} / {log()!.entries.length} · {e().iterations} iter
                      <Show when={e().capped !== 0}>
                        <span class="ir-capped" title="Per-entry iteration detail was capped; the exit is still exact."> · ⚠ detail capped</span>
                      </Show>
                      <Show when={log()!.entries_capped !== 0}>
                        <span class="ir-capped" title="Entries were capped; later exit ramps in this run aren't recorded."> · ⚠ entries capped</span>
                      </Show>
                    </span>
                  )}
                </Show>
              </div>
            </div>
          </Show>

          <table class="ir">
            <thead>
              <tr>
                <th>#</th>
                <th class="src-line" title="The source line whose bytecode recorded this instruction. Hover a row to see it in the editor; click to jump there.">line</th>
                <th>op</th>
                <th>operands</th>
                <th>ty</th>
                <th>snap</th>
              </tr>
            </thead>
            <tbody>
              <For each={t().instrs}>
                {(ins, i) => {
                  const isCurrent = () => hasAnim() && i() === curRef();
                  const loc = () => traceLoc(ins.src);
                  return (
                    <tr
                      id={`ir-${i()}`}
                      classList={{
                        guard: ins.op.startsWith("guard"),
                        "ir-current": isCurrent() && !isExit(),
                        "ir-exit": isCurrent() && isExit(),
                        // A row's position is its SSA number (`ins.index` is the padded text).
                        "ir-ref-target": hoverRef() === i() || flashRef() === i(),
                        "ir-has-line": loc() !== null,
                        // Recorded from the line the editor cursor is on.
                        "ir-cursor-line": sameLoc(loc(), state.editorCursor),
                        "ir-pinned-line": sameLoc(loc(), state.irPinnedLoc),
                      }}
                      ref={(el) => {
                        if (isCurrent()) currentRow = el;
                        rowEls[i()] = el;
                      }}
                      onMouseEnter={() => hoverIrLoc(loc())}
                      onMouseLeave={() => hoverIrLoc(null)}
                      onClick={() => {
                        const l = loc();
                        if (l !== null) pinIrLoc(l);
                      }}
                    >
                      <td class="idx">%{ins.index}</td>
                      <td class="src-line" title={loc() !== null ? `${loc()!.path}, line ${loc()!.line}` : undefined}>
                        {srcLineCell(loc())}
                      </td>
                      <td class="op">{ins.op}</td>
                      <td class="operands">
                        <For each={operandTokens(ins.operands)}>
                          {(tok) =>
                            "ref" in tok ? (
                              <a
                                href={`#ir-${tok.ref}`}
                                class="ir-ref"
                                title={`go to %${tok.ref}'s definition`}
                                onMouseEnter={() => setHoverRef(tok.ref)}
                                onMouseLeave={() => setHoverRef(-1)}
                                onClick={(e) => { e.preventDefault(); goToRef(tok.ref); }}
                              >
                                %{tok.ref}
                              </a>
                            ) : (
                              tok.text
                            )
                          }
                        </For>
                      </td>
                      <td class="ty">{ins.ty}</td>
                      <td class="snap">{ins.op.startsWith("guard") ? ins.snap : ""}</td>
                    </tr>
                  );
                }}
              </For>
            </tbody>
          </table>

          <Show when={t().consts.length > 0}>
            <div class="subsection">
              <div class="pane-title">consts</div>
              <table class="consts">
                <tbody>
                  <For each={t().consts}>
                    {(c) => (
                      <tr>
                        <td class="idx">{c.slot}</td>
                        <td class="ty">{c.kind}</td>
                        <td class="val">{c.text}</td>
                      </tr>
                    )}
                  </For>
                </tbody>
              </table>
            </div>
          </Show>
        </section>
      )}
    </Show>
  );
}
