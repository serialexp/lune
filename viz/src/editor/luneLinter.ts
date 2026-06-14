// Live validation glue: a CodeMirror `linter` that calls the lune compiler
// (compile-only, via the wasm `check`) and maps its diagnostics to inline
// squiggles. Two engines, one source of truth — the editor underlines exactly
// what the real frontend rejects, so it can never drift from the language.

import { linter, type Diagnostic } from "@codemirror/lint";
import type { Extension } from "@codemirror/state";
import type { LuneDiagnostic } from "../wasm/lune";

/**
 * Build a byte-offset → UTF-16-code-unit-index map for `src`.
 *
 * lune diagnostics carry UTF-8 *byte* spans (the lexer's native unit), but
 * CodeMirror document positions are UTF-16 code-unit indices. For ASCII the two
 * coincide; for multibyte text they diverge, so we map explicitly. `map[b]` is
 * the UTF-16 index of the character that byte `b` belongs to; `map[byteLen]` is
 * the document length (end sentinel). Token spans fall on character boundaries,
 * so `map[start]` / `map[end]` land exactly.
 */
export function byteToUtf16(src: string): number[] {
  const enc = new TextEncoder();
  const map: number[] = [];
  let byte = 0;
  for (let i = 0; i < src.length; ) {
    const cp = src.codePointAt(i)!;
    const ch = String.fromCodePoint(cp);
    const nbytes = enc.encode(ch).length;
    const nunits = ch.length; // 1, or 2 for a surrogate pair
    for (let b = 0; b < nbytes; b++) map[byte + b] = i;
    byte += nbytes;
    i += nunits;
  }
  map[byte] = src.length;
  return map;
}

/**
 * A debounced CodeMirror linter backed by `check` (the wasm compile-only entry,
 * surfaced through the store as `checkSource`). Maps each lune diagnostic's byte
 * span to a UTF-16 document range, clamped to the document.
 */
export function luneLinter(check: (src: string) => Promise<LuneDiagnostic[]>): Extension {
  return linter(
    async (view): Promise<Diagnostic[]> => {
      const src = view.state.doc.toString();
      const diags = await check(src);
      if (diags.length === 0) return [];

      const map = byteToUtf16(src);
      const docLen = view.state.doc.length;
      const at = (byteOff: number): number => {
        const i = Math.max(0, Math.min(byteOff, map.length - 1));
        return Math.max(0, Math.min(map[i] ?? docLen, docLen));
      };

      return diags.map((d): Diagnostic => {
        const from = at(d.start);
        const to = Math.max(from, at(d.end));
        return { from, to, severity: d.severity, message: d.message };
      });
    },
    { delay: 250 },
  );
}
