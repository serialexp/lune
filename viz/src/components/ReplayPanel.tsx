// Deterministic step-replay panel (Phase 7 v8). Scrub a finished run's execution
// and watch the VM state evolve: the current source line, output-so-far, the call
// chain, the deepest frame's locals, and the globals. Each slider position
// re-runs the captured effect log to that safepoint via the store
// (`setReplayPos` → wasm `replay`), so the same position always yields identical
// state — the payoff of deterministic replay. State flows through the store; this
// component is pure presentation + the play timer (Rule #9).

import { For, Show, createSignal, createEffect, onCleanup } from "solid-js";
import {
  state,
  setGrain,
  setReplayPos,
  stepReplay,
  closeReplay,
  replayDisasm,
  visibleGlobals,
  setShowBuiltinGlobals,
  replayLoc,
  locLabel,
  frameLabel,
} from "../store";

/** Milliseconds between auto-advance steps while playing. */
const PLAY_INTERVAL_MS = 220;

/** Whether a key event's target takes typing: the editor, or a text field
 *  (the args input, the sliders' own arrows). */
function isTyping(target: EventTarget | null): boolean {
  if (!(target instanceof HTMLElement)) return false;
  if (target.closest(".cm-editor")) return true;
  return target instanceof HTMLInputElement || target instanceof HTMLTextAreaElement || target.isContentEditable;
}

export default function ReplayPanel() {
  const [playing, setPlaying] = createSignal(false);

  const lastPos = () => Math.max(0, state.replayStops.length - 1);
  const atEnd = () => state.replayPos >= lastPos();
  const finished = () => state.replayState?.finished === true;

  // Auto-advance while playing; stop at the final stop. The interval reads the
  // live store position each tick, so manual scrubbing mid-play stays coherent.
  createEffect(() => {
    if (!playing()) return;
    const id = setInterval(() => {
      if (state.replayPos >= state.replayStops.length - 1) {
        setPlaying(false);
        return;
      }
      stepReplay(1);
    }, PLAY_INTERVAL_MS);
    onCleanup(() => clearInterval(id));
  });

  const togglePlay = () => {
    if (atEnd()) setReplayPos(0); // replay from the top if parked at the end
    setPlaying((p) => !p);
  };

  // Keyboard transport while the panel is open (the shortcuts named in the
  // buttons' titles). Not while typing: the editor and text fields keep their
  // own arrows, Home/End and Space.
  const onKey = (e: KeyboardEvent) => {
    if (e.ctrlKey || e.metaKey || e.altKey || isTyping(e.target)) return;
    const act: Record<string, () => void> = {
      Escape: closeReplay,
      " ": togglePlay,
      ArrowLeft: () => { setPlaying(false); stepReplay(-1); },
      ArrowRight: () => { setPlaying(false); stepReplay(1); },
      Home: () => { setPlaying(false); setReplayPos(0); },
      End: () => { setPlaying(false); setReplayPos(lastPos()); },
    };
    const f = act[e.key];
    if (f === undefined) return;
    e.preventDefault();
    f();
  };
  window.addEventListener("keydown", onKey);
  onCleanup(() => window.removeEventListener("keydown", onKey));

  // The globals to list: by default without the builtins (step 1's globals).
  const globals = () =>
    visibleGlobals(state.replayView?.globals ?? [], state.replayBaseGlobals, state.showBuiltinGlobals);

  // The bytecode listing at the current step (the proto the cursor is in + pc),
  // or null when the program has finished (no live frame) or disasm is absent.
  const bytecode = () => replayDisasm();

  // Keep the highlighted pc row in view as stepping moves it. The ref is rebound
  // each render of the current row; the effect tracks the pc so it scrolls on
  // every step (including grain changes and slider scrubs).
  let currentRow: HTMLTableRowElement | undefined;
  createEffect(() => {
    const bc = bytecode();
    if (!bc) return;
    void bc.pc; // track
    currentRow?.scrollIntoView({ block: "nearest" });
  });

  return (
    <div class="replay">
      <div class="replay-head">
        <span class="replay-title">step replay</span>
        <div class="replay-grain" role="group" aria-label="step grain">
          <button
            type="button"
            classList={{ selected: state.grain === "instr" }}
            onClick={() => setGrain("instr")}
            title="One stop per bytecode instruction (safepoint)"
          >
            instruction
          </button>
          <button
            type="button"
            classList={{ selected: state.grain === "line" }}
            onClick={() => setGrain("line")}
            title="One stop per source-line change"
          >
            line
          </button>
        </div>
        <button type="button" class="replay-close" onClick={closeReplay} title="Close replay (Esc)" aria-label="Close replay">
          ✕
        </button>
      </div>

      <div class="replay-transport">
        <button type="button" onClick={() => { setPlaying(false); setReplayPos(0); }} disabled={state.replayPos === 0} title="Jump to start (Home)" aria-label="Jump to start">
          ⏮
        </button>
        <button type="button" onClick={() => { setPlaying(false); stepReplay(-1); }} disabled={state.replayPos === 0} title="Step back (←)" aria-label="Step back">
          ◀
        </button>
        <button type="button" onClick={togglePlay} title={playing() ? "Pause (Space)" : "Play (Space)"} aria-label={playing() ? "Pause" : "Play"}>
          {playing() ? "⏸ pause" : "▶ play"}
        </button>
        <button type="button" onClick={() => { setPlaying(false); stepReplay(1); }} disabled={atEnd()} title="Step forward (→)" aria-label="Step forward">
          ▶
        </button>
        <button type="button" onClick={() => { setPlaying(false); setReplayPos(lastPos()); }} disabled={atEnd()} title="Jump to end (End)" aria-label="Jump to end">
          ⏭
        </button>
        <input
          class="replay-slider"
          type="range"
          aria-label="Replay step"
          min={0}
          max={lastPos()}
          step={1}
          value={state.replayPos}
          onInput={(e) => { setPlaying(false); setReplayPos(e.currentTarget.valueAsNumber); }}
        />
        <span class="replay-pos muted">
          {state.replayPos + 1} / {state.replayStops.length}
        </span>
      </div>

      <div class="replay-status">
        <Show
          when={!finished()}
          fallback={<span class="replay-done">finished — {state.safepointCount} safepoints</span>}
        >
          <span>
            <Show when={replayLoc()} fallback={<>line <span class="accent">{state.replayState?.currentLine ?? "–"}</span></>}>
              {(loc) => <span class="accent">{locLabel(loc())}</span>}
            </Show>
            <span class="muted"> · depth {state.replayState?.depth ?? 0}</span>
          </span>
        </Show>
        <Show when={state.safepointCapped}>
          <span class="replay-capped" title="The run hit the safepoint cap; stepping is bounded to the recorded prefix.">
            ⚠ capped at {state.safepointCount}
          </span>
        </Show>
      </div>

      {/* Call chain at this step (deepest-first), flattened like the error traceback. */}
      <Show when={(state.replayState?.backtrace.length ?? 0) > 0}>
        <div class="replay-frames">
          {state.replayState!.backtrace.map(frameLabel).join(" → ")}
        </div>
      </Show>

      {/* Bytecode listing of the proto the cursor is in: the current `pc` row is
          highlighted and the row's source line annotated. This is the pure
          tier-0 bytecode the stepper actually executes — distinct from the JIT
          trace IR shown in the panes below. Hidden once the program finishes
          (no live frame to point at). */}
      <Show when={bytecode()}>
        {(bc) => (
          <div class="replay-col bc-panel">
            <div class="replay-col-title">
              bytecode <span class="muted">· proto {bc().proto.name} · regs {bc().proto.numRegisters} · params {bc().proto.numParams}</span>
            </div>
            <div class="bc-scroll">
              <table class="bc-list">
                <tbody>
                  <For each={bc().proto.instrs}>
                    {(ins, i) => (
                      <tr
                        classList={{ "bc-current": i() === bc().pc }}
                        ref={(el) => { if (i() === bc().pc) currentRow = el; }}
                      >
                        <td class="bc-pc">{i()}</td>
                        <td class="bc-text">{ins.text}</td>
                        <td class="bc-line">{ins.line > 0 ? `; line ${ins.line}` : ""}</td>
                      </tr>
                    )}
                  </For>
                </tbody>
              </table>
            </div>
          </div>
        )}
      </Show>

      <div class="replay-panels">
        <div class="replay-col">
          <div class="replay-col-title">output so far</div>
          <pre class="replay-stdout">{state.replayState?.stdout ?? ""}</pre>
        </div>

        <div class="replay-col">
          <div class="replay-col-title">locals</div>
          <Show when={(state.replayView?.locals.length ?? 0) > 0} fallback={<div class="replay-empty">—</div>}>
            <table class="replay-vars">
              <tbody>
                <For each={state.replayView!.locals}>
                  {(v) => (
                    <tr
                      classList={{ "replay-var-dead": v.dead === true }}
                      title={v.dead ? "dead: not read again before it is overwritten" : undefined}
                    >
                      <td class="replay-var-name" title={v.label}>{v.label}</td>
                      <td class="replay-var-val">
                        {v.value}
                        <Show when={v.dead}>
                          <span class="replay-var-tag">dead</span>
                        </Show>
                      </td>
                    </tr>
                  )}
                </For>
              </tbody>
            </table>
          </Show>
        </div>

        <div class="replay-col">
          <div class="replay-col-title">
            globals
            <Show when={globals().hidden > 0 || state.showBuiltinGlobals}>
              <label class="replay-builtins">
                <input
                  type="checkbox"
                  checked={state.showBuiltinGlobals}
                  onChange={(e) => setShowBuiltinGlobals(e.currentTarget.checked)}
                />
                show builtins{globals().hidden > 0 ? ` (${globals().hidden} hidden)` : ""}
              </label>
            </Show>
          </div>
          <Show when={globals().shown.length > 0} fallback={<div class="replay-empty">—</div>}>
            <table class="replay-vars">
              <tbody>
                <For each={globals().shown}>
                  {(v) => (
                    <tr>
                      <td class="replay-var-name" title={v.label}>{v.label}</td>
                      <td class="replay-var-val">{v.value}</td>
                    </tr>
                  )}
                </For>
              </tbody>
            </table>
          </Show>
        </div>
      </div>
    </div>
  );
}
