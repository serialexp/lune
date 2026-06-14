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
} from "../store";
import { ExecEventKind, formatExecValue, exitKindLabel } from "../exec";

/** Milliseconds between auto-advance steps while playing (matches ReplayPanel). */
const PLAY_INTERVAL_MS = 220;

export default function TraceView() {
  const trace = selectedTrace;
  const [playing, setPlaying] = createSignal(false);

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
        return "iteration committed — loop ↺";
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
                This trace was recorded but never executed in this run — nothing to animate.
              </p>
            }
          >
            <div class="ir-anim">
              <div class="ir-transport">
                <button type="button" onClick={() => { setPlaying(false); setTraceExecPos(0); }} disabled={pos() === 0} title="Jump to start">
                  ⏮
                </button>
                <button type="button" onClick={() => { setPlaying(false); stepTraceExec(-1); }} disabled={pos() === 0} title="Step back">
                  ◀
                </button>
                <button type="button" onClick={togglePlay} title={playing() ? "Pause" : "Play"}>
                  {playing() ? "⏸ pause" : "▶ play"}
                </button>
                <button type="button" onClick={() => { setPlaying(false); stepTraceExec(1); }} disabled={atEnd()} title="Step forward">
                  ▶
                </button>
                <button type="button" onClick={() => { setPlaying(false); setTraceExecPos(lastPos()); }} disabled={atEnd()} title="Jump to end">
                  ⏭
                </button>
                <input
                  class="ir-slider"
                  type="range"
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
                  return (
                    <tr
                      classList={{
                        guard: ins.op.startsWith("guard"),
                        "ir-current": isCurrent() && !isExit(),
                        "ir-exit": isCurrent() && isExit(),
                      }}
                      ref={(el) => { if (isCurrent()) currentRow = el; }}
                    >
                      <td class="idx">%{ins.index}</td>
                      <td class="op">{ins.op}</td>
                      <td class="operands">{ins.operands}</td>
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

          <Show when={t().exitStores.length > 0}>
            <div class="subsection">
              <div class="pane-title">exit stores</div>
              <div class="exits">
                <For each={t().exitStores}>
                  {(s) => (
                    <span class="exit">
                      r{s.slot}&lt;-%{s.ref}
                    </span>
                  )}
                </For>
              </div>
            </div>
          </Show>
        </section>
      )}
    </Show>
  );
}
