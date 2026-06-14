// SolidJS <-> CodeMirror 6 bridge for the in-browser lune editor. Highlights via
// the lune mode (luneLanguage) and validates live against the real compiler
// (luneLinter -> store.checkSource -> wasm `check`). Two-way bound to the store's
// `source` with a guard so the view<->store sync never loops.

import { onMount, onCleanup, createEffect } from "solid-js";
import { EditorView, keymap, lineNumbers, highlightActiveLine, highlightActiveLineGutter, drawSelection } from "@codemirror/view";
import { EditorState } from "@codemirror/state";
import { defaultKeymap, history, historyKeymap, indentWithTab } from "@codemirror/commands";
import { indentOnInput, bracketMatching } from "@codemirror/language";
import { lintGutter, lintKeymap } from "@codemirror/lint";
import { state, setSource, checkSource } from "../store";
import { luneLanguage, luneHighlighting } from "./luneLanguage";
import { luneLinter } from "./luneLinter";

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

  onCleanup(() => view?.destroy());

  return <div class="cm-host" ref={host} />;
}
