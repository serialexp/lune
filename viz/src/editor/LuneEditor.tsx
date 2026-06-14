// SolidJS <-> CodeMirror 6 bridge for the in-browser lune editor. Highlights via
// the lune mode (luneLanguage) and validates live against the real compiler
// (luneLinter -> store.checkSource -> wasm `check`). Two-way bound to the store's
// `source` with a guard so the view<->store sync never loops.

import { onMount, onCleanup, createEffect } from "solid-js";
import { EditorView, keymap, lineNumbers, highlightActiveLine, highlightActiveLineGutter, drawSelection, Decoration, type DecorationSet } from "@codemirror/view";
import { EditorState, StateField, StateEffect } from "@codemirror/state";
import { defaultKeymap, history, historyKeymap, indentWithTab } from "@codemirror/commands";
import { indentOnInput, bracketMatching } from "@codemirror/language";
import { lintGutter, lintKeymap } from "@codemirror/lint";
import { state, setSource, checkSource } from "../store";
import { luneLanguage, luneHighlighting } from "./luneLanguage";
import { luneLinter, byteToUtf16 } from "./luneLinter";

// Runtime-error squiggle — a channel separate from the compile linter. Compile
// diagnostics (`luneLinter` → wasm `check`) fire as you type; a *runtime* error
// is only known after a Run, so it lives in its own decoration field rather than
// the lint state (the two would otherwise overwrite each other). The mark gets a
// `title` attribute for a native hover tooltip carrying the lune message.
const setRuntimeError = StateEffect.define<{ from: number; to: number; message: string } | null>();

const runtimeErrorField = StateField.define<DecorationSet>({
  create: () => Decoration.none,
  update(deco, tr) {
    for (const e of tr.effects) {
      if (e.is(setRuntimeError)) {
        return e.value
          ? Decoration.set([
              Decoration.mark({ class: "cm-runtime-error", attributes: { title: e.value.message } }).range(e.value.from, e.value.to),
            ])
          : Decoration.none;
      }
    }
    // Any edit invalidates the last run's error — clear the squiggle.
    if (tr.docChanged) return Decoration.none;
    return deco;
  },
  provide: (f) => EditorView.decorations.from(f),
});

// Step-replay current-line highlight — its own channel, independent of the
// compile linter and the runtime-error squiggle (all three can be live at once).
// A line decoration shades the whole line the replay is paused on.
const setReplayLine = StateEffect.define<number | null>();

const replayLineField = StateField.define<DecorationSet>({
  create: () => Decoration.none,
  update(deco, tr) {
    for (const e of tr.effects) {
      if (e.is(setReplayLine)) {
        if (e.value === null) return Decoration.none;
        const lineNo = e.value;
        if (lineNo < 1 || lineNo > tr.state.doc.lines) return Decoration.none;
        const from = tr.state.doc.line(lineNo).from;
        return Decoration.set([
          Decoration.line({ class: "cm-replay-line" }).range(from),
        ]);
      }
    }
    return deco;
  },
  provide: (f) => EditorView.decorations.from(f),
});

/** Editor chrome theme matching the dark viz palette. Token colors live in the
 *  HighlightStyle (luneHighlighting); this is gutter/cursor/selection only. */
const luneTheme = EditorView.theme(
  {
    "&": { fontSize: "13px", backgroundColor: "transparent", color: "#abb2bf" },
    ".cm-content": { fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace", caretColor: "#528bff" },
    ".cm-gutters": { backgroundColor: "transparent", color: "#5c6370", border: "none" },
    ".cm-activeLine": { backgroundColor: "#ffffff0a" },
    ".cm-activeLineGutter": { backgroundColor: "#ffffff0a" },
    "&.cm-focused": { outline: "none" },
    "&.cm-focused .cm-cursor": { borderLeftColor: "#528bff" },
    ".cm-selectionBackground, &.cm-focused .cm-selectionBackground": { backgroundColor: "#3e4451" },
  },
  { dark: true },
);

export default function LuneEditor() {
  let host!: HTMLDivElement;
  let view: EditorView | undefined;

  onMount(() => {
    view = new EditorView({
      parent: host,
      state: EditorState.create({
        doc: state.source,
        extensions: [
          lineNumbers(),
          highlightActiveLineGutter(),
          highlightActiveLine(),
          history(),
          drawSelection(),
          indentOnInput(),
          bracketMatching(),
          keymap.of([...defaultKeymap, ...historyKeymap, ...lintKeymap, indentWithTab]),
          luneLanguage(),
          luneHighlighting,
          luneLinter(checkSource),
          runtimeErrorField,
          replayLineField,
          lintGutter(),
          luneTheme,
          EditorView.updateListener.of((u) => {
            if (!u.docChanged) return;
            const text = u.state.doc.toString();
            if (text !== state.source) setSource(text);
          }),
        ],
      }),
    });
  });

  // Reconcile external `source` changes (e.g. loading a sample) into the view,
  // but only when they actually differ — edits originating in the view already
  // updated the store, so this skips them and avoids a feedback loop.
  createEffect(() => {
    const src = state.source;
    if (view && src !== view.state.doc.toString()) {
      view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: src } });
    }
  });

  // Mirror the last run's located runtime error into the editor as a squiggle.
  // Reactive on both `runErrorSpan` (the byte span) and `runError` (the message
  // shown in the tooltip). lune spans are UTF-8 byte offsets → map to UTF-16.
  createEffect(() => {
    const span = state.runErrorSpan;
    const message = state.runError ?? "runtime error";
    if (!view) return;
    if (!span) {
      view.dispatch({ effects: setRuntimeError.of(null) });
      return;
    }
    const docLen = view.state.doc.length;
    const map = byteToUtf16(view.state.doc.toString());
    const at = (b: number): number => {
      const i = Math.max(0, Math.min(b, map.length - 1));
      return Math.max(0, Math.min(map[i] ?? docLen, docLen));
    };
    const from = at(span.start);
    const to = Math.max(from, at(span.end));
    view.dispatch({ effects: setRuntimeError.of({ from, to, message }) });
  });

  // Mirror the step-replay current line into the editor. Only highlights while
  // replay is open and paused on a suspended (not finished) step; cleared
  // otherwise. `currentLine` is already 1-based, the unit CodeMirror lines use.
  createEffect(() => {
    if (!view) return;
    const active = state.replayActive;
    const rs = state.replayState;
    const line = active && rs && !rs.finished && rs.currentLine > 0 ? rs.currentLine : null;
    view.dispatch({ effects: setReplayLine.of(line) });
  });

  onCleanup(() => view?.destroy());

  return <div class="cm-host" ref={host} />;
}
