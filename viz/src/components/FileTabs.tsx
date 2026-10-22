// The editor's file tabs: the program's files (the entry marked ▶), then the
// last run's read-only chunks (a `load`ed string has no file to edit). Click
// shows a tab, double-click renames it, × closes it, + adds a file.

import { For, Show, createSignal } from "solid-js";
import { state, tabs, setActivePath, setEntryPath, newFile, renameFile, closeFile, activeReadOnly } from "../store";

export default function FileTabs() {
  /** The tab being renamed, and why the typed name was refused. */
  const [renaming, setRenaming] = createSignal<string | null>(null);
  const [renameError, setRenameError] = createSignal<string | null>(null);

  const commitRename = (from: string, to: string) => {
    const problem = renameFile(from, to);
    setRenameError(problem);
    if (problem === null) setRenaming(null);
  };

  return (
    <div class="file-tabs" role="tablist" aria-label="Program files">
      <For each={tabs()}>
        {(t) => (
          <Show
            when={renaming() === t.path}
            fallback={
              <span
                class="file-tab"
                role="tab"
                aria-selected={state.activePath === t.path}
                classList={{ active: state.activePath === t.path, virtual: t.virtual, entry: t.entry }}
                title={
                  t.virtual
                    ? "Read-only: a chunk the last run compiled from a string (load), not a file"
                    : t.entry
                      ? "The entry file: Run executes it. Double-click to rename."
                      : "Double-click to rename"
                }
                onClick={() => setActivePath(t.path)}
                onDblClick={() => {
                  if (t.virtual) return;
                  setRenameError(null);
                  setRenaming(t.path);
                }}
              >
                <Show when={t.entry}>
                  <span class="entry-mark" aria-label="entry">▶</span>
                </Show>
                {t.path}
                <Show when={!t.virtual && state.files.length > 1}>
                  <button
                    type="button"
                    class="tab-close"
                    title={`Close ${t.path} (removes it from the program)`}
                    aria-label={`Close ${t.path}`}
                    onClick={(e) => {
                      e.stopPropagation();
                      closeFile(t.path);
                    }}
                  >
                    ×
                  </button>
                </Show>
              </span>
            }
          >
            <input
              class="tab-rename"
              type="text"
              value={t.path}
              aria-label={`Rename ${t.path}`}
              ref={(el) => queueMicrotask(() => el.select())}
              onKeyDown={(e) => {
                if (e.key === "Enter") commitRename(t.path, e.currentTarget.value);
                else if (e.key === "Escape") setRenaming(null);
              }}
              onBlur={(e) => {
                if (renaming() === t.path) commitRename(t.path, e.currentTarget.value);
                if (renameError() !== null) setRenaming(null);
              }}
            />
          </Show>
        )}
      </For>
      <button type="button" class="tab-add" title="Add a file to the program (require it by name)" aria-label="New file" onClick={() => newFile()}>
        +
      </button>
      <Show when={!activeReadOnly() && state.activePath !== state.entryPath}>
        <button type="button" class="secondary tab-entry" title="Make this file the one Run executes" onClick={() => setEntryPath(state.activePath)}>
          Run this file
        </button>
      </Show>
      <Show when={renameError()}>
        <span class="source-error" role="alert">{renameError()}</span>
      </Show>
    </div>
  );
}
