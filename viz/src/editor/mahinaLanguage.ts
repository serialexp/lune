// The mahina editor mode: syntax highlighting keyed to the *real* lexer
// (src/lexer.zig) and token set (src/token.zig), not a borrowed Lua grammar.
//
// Why our own mode and not @codemirror/legacy-modes/mode/lua: mahina is
// "Lua-shaped but not Lua." Today the keyword set happens to match classic Lua,
// but mahina supports `--[[ ]]` block *comments* while it has NO `[[ ]]` long
// *string* literals (deferred in the lexer), so a stock Lua grammar would
// mis-highlight `[[ … ]]` as a string. Keeping the keyword + builtin lists here,
// derived from the Zig source, makes this the single seam where the highlighter
// could drift — easy to eyeball against token.zig / interp.zig.

import { StreamLanguage, type StreamParser, HighlightStyle, syntaxHighlighting } from "@codemirror/language";
import { tags as t } from "@lezer/highlight";
import type { Extension } from "@codemirror/state";

/** Keywords — the exact set from src/token.zig's `keywords` map. */
const KEYWORDS = new Set([
  "and", "break", "do", "else", "elseif", "end", "false", "for", "function",
  "if", "in", "local", "nil", "not", "or", "return", "then", "true", "while",
]);

/** Builtins — the `base_natives` registry in src/interp.zig. The
 *  custom-vocabulary extension point: add a native here when it lands. */
const BUILTINS = new Set(["print", "clock"]);

interface MahinaState {
  /** True when a `--[[ … ]]` block comment is still open across line breaks. */
  inBlockComment: boolean;
}

const isIdentStart = (ch: string): boolean => /[A-Za-z_]/.test(ch);
const isIdentChar = (ch: string): boolean => /[A-Za-z0-9_]/.test(ch);

/** Consume a quoted string body (already past the opening quote), honoring `\`
 *  escapes. An unterminated string just ends at EOL — the linter reports the
 *  real diagnostic; the mode only needs to color what's there. */
function consumeString(stream: { eol(): boolean; next(): string | void }, quote: string): void {
  let escaped = false;
  while (!stream.eol()) {
    const c = stream.next();
    if (c === quote && !escaped) return;
    escaped = c === "\\" && !escaped;
  }
}

const mahinaParser: StreamParser<MahinaState> = {
  name: "mahina",
  startState: () => ({ inBlockComment: false }),
  token(stream, state) {
    // Continuation of a multi-line block comment.
    if (state.inBlockComment) {
      if (stream.skipTo("]]")) {
        stream.match("]]");
        state.inBlockComment = false;
      } else {
        stream.skipToEnd();
      }
      return "comment";
    }

    if (stream.eatSpace()) return null;
    const ch = stream.peek();
    if (ch == null) return null; // null or undefined → nothing to tokenize

    // Comments — block (`--[[ … ]]`) must be checked before the line form.
    if (stream.match("--[[")) {
      if (stream.skipTo("]]")) {
        stream.match("]]");
      } else {
        stream.skipToEnd();
        state.inBlockComment = true;
      }
      return "comment";
    }
    if (stream.match("--")) {
      stream.skipToEnd();
      return "comment";
    }

    // Strings.
    if (ch === '"' || ch === "'") {
      stream.next();
      consumeString(stream, ch);
      return "string";
    }

    // Numbers: hex (incl. hex float / binary-exponent), decimal int/float with
    // optional exponent, and leading-dot floats (`.5`).
    const next = stream.string.charAt(stream.pos + 1);
    if (/[0-9]/.test(ch) || (ch === "." && /[0-9]/.test(next))) {
      if (stream.match(/^0[xX][0-9a-fA-F]*(?:\.[0-9a-fA-F]*)?(?:[pP][-+]?[0-9]+)?/)) return "number";
      stream.match(/^[0-9]*\.?[0-9]*(?:[eE][-+]?[0-9]+)?/);
      return "number";
    }

    // Identifiers → keyword / builtin / plain variable.
    if (isIdentStart(ch)) {
      let word = "";
      while (!stream.eol() && isIdentChar(stream.peek() as string)) word += stream.next();
      if (KEYWORDS.has(word)) return "keyword";
      if (BUILTINS.has(word)) return "builtin";
      return "variable";
    }

    // Operators and brackets.
    if (stream.match(/^(?:==|~=|<=|>=|\.\.\.|\.\.|[-+*/%^#<>=])/)) return "operator";
    if (stream.match(/^[(){}\[\]]/)) return "bracket";

    stream.next();
    return null;
  },
  languageData: {
    commentTokens: { line: "--", block: { open: "--[[", close: "]]" } },
  },
};

/** The mahina language extension (highlighting only; the linter is separate). */
export function mahinaLanguage(): Extension {
  return StreamLanguage.define(mahinaParser);
}

/** A dark highlight style matching the viz UI palette. StreamLanguage maps the
 *  legacy token names above to these tags ("builtin" → standard(variableName)). */
export const mahinaHighlighting: Extension = syntaxHighlighting(
  HighlightStyle.define([
    { tag: t.keyword, color: "#c678dd" },
    { tag: t.comment, color: "#7f848e", fontStyle: "italic" },
    { tag: t.string, color: "#98c379" },
    { tag: t.number, color: "#d19a66" },
    { tag: t.operator, color: "#56b6c2" },
    { tag: t.standard(t.variableName), color: "#e5c07b" }, // builtins (print/clock)
    { tag: t.variableName, color: "#abb2bf" },
    { tag: t.bracket, color: "#abb2bf" },
  ]),
);
