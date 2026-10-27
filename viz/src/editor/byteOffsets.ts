// Byte offsets → CodeMirror positions. mahina spans (runtime-error squiggles,
// replay highlights) are UTF-8 byte offsets; the editor counts UTF-16 units.
// (Diagnostics from the language server arrive in UTF-16 already.)

/**
 * Build a byte-offset → UTF-16-code-unit-index map for `src`.
 *
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
