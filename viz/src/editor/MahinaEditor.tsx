// SolidJS <-> CodeMirror 6 bridge for the in-browser mahina editor. Highlights via
// the mahina mode (mahinaLanguage) and validates live against the real compiler
// (mahinaLinter -> store.checkSource -> wasm `check`). Shows the store's active
// tab (`activePath`), two-way bound to that file's text with a guard so the
// view<->store sync never loops. Each tab keeps its own EditorState (undo
// history, selection) while the program is open.

import { onMount, onCleanup, createEffect, on } from "solid-js";
import { EditorView, keymap, lineNumbers, highlightActiveLine, highlightActiveLineGutter, drawSelection, Decoration, type DecorationSet } from "@codemirror/view";
import { EditorState, StateField, StateEffect } from "@codemirror/state";
import { defaultKeymap, history, historyKeymap, indentWithTab } from "@codemirror/commands";
import { indentOnInput, bracketMatching } from "@codemirror/language";
import { lintGutter, lintKeymap } from "@codemirror/lint";
import {
  state,
  setFileText,
  fileText,
  activeReadOnly,
  checkSource,
  coverageLinesOf,
  coverageLineTitle,
  fileMapped,
  replayLoc,
  tabs,
  setEditorCursorLine,
  type CoverageClass,
} from "../store";
import { mahinaLanguage, mahinaHighlighting } from "./mahinaLanguage";
import { mahinaLinter, byteToUtf16 } from "./mahinaLinter";

// Runtime-error squiggle — a channel separate from the compile linter. Compile
// diagnostics (`mahinaLinter` → wasm `check`) fire as you type; a *runtime* error
// is only known after a Run, so it lives in its own decoration field rather than
// the lint state (the two would otherwise overwrite each other). The mark gets a
// `title` attribute for a native hover tooltip carrying the mahina message.
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
    // The line is the replayed source's, not the edited text's — clear it on
    // any edit, like the other run-derived fields. (Keeping it unmapped left a
    // decoration past the end of a shorter document: CodeMirror's "Position …
    // is out of range" crash after loading a new file mid-replay.)
    if (tr.docChanged) return Decoration.none;
    return deco;
  },
  provide: (f) => EditorView.decorations.from(f),
});

// Trace-IR source line — the line the hovered (else last clicked) IR row was
// recorded from. Its own channel, like the replay line, and cleared on any edit
// for the same reason: the line number is the traced source's.
const setTraceLine = StateEffect.define<number | null>();

const traceLineField = StateField.define<DecorationSet>({
  create: () => Decoration.none,
  update(deco, tr) {
    for (const e of tr.effects) {
      if (e.is(setTraceLine)) {
        const lineNo = e.value;
        if (lineNo === null || lineNo < 1 || lineNo > tr.state.doc.lines) return Decoration.none;
        return Decoration.set([Decoration.line({ class: "cm-trace-line" }).range(tr.state.doc.line(lineNo).from)]);
      }
    }
    if (tr.docChanged) return Decoration.none;
    return deco;
  },
  provide: (f) => EditorView.decorations.from(f),
});

// JIT-coverage line shading — a fourth decoration channel, independent of the
// compile linter, runtime-error squiggle, and replay-line highlight (all can be
// live at once). Only loop-header lines (the coverage anchors) are shaded, so
// this colours a handful of lines, not the whole file: green = ran native, amber
// = has a trace but ran interpreted (the smell), red = no trace / purely
// interpreted. Cleared on any edit (line numbers would drift off the run).
const COVERAGE_CLASS: Record<CoverageClass, string> = {
  native: "cm-cov-native",
  "covered-interpreted": "cm-cov-covered-interp",
  uncovered: "cm-cov-uncovered",
};

const setCoverage = StateEffect.define<{ line: number; cls: CoverageClass; title: string }[] | null>();

const coverageField = StateField.define<DecorationSet>({
  create: () => Decoration.none,
  update(deco, tr) {
    for (const e of tr.effects) {
      if (e.is(setCoverage)) {
        if (e.value === null || e.value.length === 0) return Decoration.none;
        const lines = tr.state.doc.lines;
        // Line decorations must be added in document order — sort by line.
        const ranges = e.value
          .filter((c) => c.line >= 1 && c.line <= lines)
          .sort((a, b) => a.line - b.line)
          .map((c) =>
            Decoration.line({ class: COVERAGE_CLASS[c.cls], attributes: { title: c.title } }).range(
              tr.state.doc.line(c.line).from,
            ),
          );
        return Decoration.set(ranges);
      }
    }
    // Any edit invalidates the last run's coverage — clear the shading.
    if (tr.docChanged) return Decoration.none;
    return deco;
  },
  provide: (f) => EditorView.decorations.from(f),
});

/** Editor chrome theme matching the dark viz palette. Token colors live in the
 *  HighlightStyle (mahinaHighlighting); this is gutter/cursor/selection only. */
const mahinaTheme = EditorView.theme(
  {
    "&": { fontSize: "13px", backgroundColor: "transparent", color: "#abb2bf" },
    ".cm-content": { fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace", caretColor: "#528bff" },
    // Line numbers in the same AA-contrast grey as the app's --muted text.
    ".cm-gutters": { backgroundColor: "transparent", color: "#868fbb", border: "none" },
    ".cm-activeLine": { backgroundColor: "#ffffff0a" },
    ".cm-activeLineGutter": { backgroundColor: "#ffffff0a" },
    "&.cm-focused": { outline: "none" },
    "&.cm-focused .cm-cursor": { borderLeftColor: "#528bff" },
    ".cm-selectionBackground, &.cm-focused .cm-selectionBackground": { backgroundColor: "#3e4451" },
  },
  { dark: true },
);

export default function MahinaEditor() {
  let host!: HTMLDivElement;
  let view: EditorView | undefined;
  /** The tab `view` shows, and each other tab's state while it's hidden. */
  let shownPath = state.activePath;
  const saved = new Map<string, EditorState>();

  const makeState = (doc: string, readOnly: boolean): EditorState =>
    EditorState.create({
      doc,
      extensions: [
        lineNumbers(),
        highlightActiveLineGutter(),
        highlightActiveLine(),
        history(),
        drawSelection(),
        indentOnInput(),
        bracketMatching(),
        keymap.of([...defaultKeymap, ...historyKeymap, ...lintKeymap, indentWithTab]),
        mahinaLanguage(),
        mahinaHighlighting,
        mahinaLinter(checkSource),
        runtimeErrorField,
        replayLineField,
        traceLineField,
        coverageField,
        lintGutter(),
        mahinaTheme,
        EditorState.readOnly.of(readOnly),
        EditorView.updateListener.of((u) => {
          // The cursor line marks the IR rows recorded from it — only once
          // the user has put the cursor somewhere (not the initial line 1).
          if (u.selectionSet && u.view.hasFocus) {
            setEditorCursorLine(u.state.doc.lineAt(u.state.selection.main.head).number);
          }
          if (!u.docChanged) return;
          const text = u.state.doc.toString();
          if (text !== fileText(shownPath)) setFileText(shownPath, text);
        }),
      ],
    });

  onMount(() => {
    view = new EditorView({ parent: host, state: makeState(fileText(shownPath) ?? "", activeReadOnly()) });
  });

  // Switch tabs: park the shown tab's state and show the active one's — its
  // saved state when that still holds the file's text, else a fresh one.
  // Created before the decoration effects, so on a switch they re-apply to the
  // tab being shown.
  createEffect(() => {
    const path = state.activePath;
    if (!view || path === shownPath) return;
    saved.set(shownPath, view.state);
    const text = fileText(path) ?? "";
    const parked = saved.get(path);
    view.setState(parked !== undefined && parked.doc.toString() === text ? parked : makeState(text, activeReadOnly()));
    saved.delete(path);
    shownPath = path;
  });

  // Forget the parked states of tabs that are gone (closed, renamed, or a
  // previous run's read-only chunks).
  createEffect(() => {
    const live = new Set(tabs().map((t) => t.path));
    for (const path of saved.keys()) if (!live.has(path)) saved.delete(path);
  });

  // Reconcile external text changes of the shown tab (e.g. loading a file)
  // into the view, but only when they actually differ — edits originating in
  // the view already updated the store, so this skips them and avoids a
  // feedback loop.
  createEffect(() => {
    const text = fileText(state.activePath);
    if (view && state.activePath === shownPath && text !== undefined && text !== view.state.doc.toString()) {
      view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: text } });
    }
  });

  // Mirror the last run's located runtime error into the editor as a squiggle,
  // when it's in the shown tab. Reactive on both `runErrorSpan` (the byte span)
  // and `runError` (the message shown in the tooltip). mahina spans are UTF-8
  // byte offsets → map to UTF-16.
  createEffect(() => {
    const span = state.runErrorSpan;
    const message = state.runError ?? "runtime error";
    const path = state.activePath;
    if (!view) return;
    if (!span || span.path !== path || !fileMapped(path)) {
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

  // Mirror the step-replay current line into the editor: while replay is
  // open, paused on a suspended (not finished) step in the shown tab, and that
  // file is unchanged since the run (`replayLoc` checks both).
  createEffect(() => {
    if (!view) return;
    const loc = replayLoc();
    view.dispatch({ effects: setReplayLine.of(loc !== null && loc.path === state.activePath ? loc.line : null) });
  });

  // Mirror the trace IR's hovered (else pinned) row into the editor as its
  // source line, when it's in the shown tab and that file is unchanged since
  // the run.
  createEffect(() => {
    if (!view) return;
    const loc = state.irHoverLoc ?? state.irPinnedLoc;
    const show = loc !== null && loc.path === state.activePath && fileMapped(loc.path);
    view.dispatch({ effects: setTraceLine.of(show ? loc.line : null) });
  });

  // `revealLoc` (an IR row click, an error link) scrolls the editor to its
  // line — every time, via the reveal counter, not just when the target
  // changes. Tracks the counter alone; the reads inside are untracked, so
  // typing never re-scrolls. `revealLoc` shows the target's tab first.
  createEffect(
    on(
      () => state.revealSeq,
      () => {
        const loc = state.revealTarget;
        if (!view || loc === null || loc.path !== shownPath) return;
        if (loc.line < 1 || loc.line > view.state.doc.lines) return;
        view.dispatch({ effects: EditorView.scrollIntoView(view.state.doc.line(loc.line).from, { y: "center" }) });
      },
      { defer: true },
    ),
  );

  // Mirror the last run's JIT coverage of the shown tab into the editor as
  // per-line shading. `coverageLinesOf` is empty once the file is edited
  // (the field also clears itself on any docChange); here we only (re)apply
  // when a fresh map arrives. Empty map → clear.
  createEffect(() => {
    if (!view) return;
    const byLine = coverageLinesOf(state.activePath);
    const entries = Array.from(byLine, ([line, c]) => ({ line, cls: c.cls, title: coverageLineTitle(c) }));
    view.dispatch({ effects: setCoverage.of(entries.length > 0 ? entries : null) });
  });

  onCleanup(() => view?.destroy());

  return <div class="cm-host" ref={host} />;
}
