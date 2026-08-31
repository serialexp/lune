// Unit test for the byte→UTF-16 offset map the editor's linter uses to place
// squiggles. mahina diagnostics are UTF-8 byte spans; CodeMirror positions are
// UTF-16 code-unit indices. ASCII is the identity; multibyte text shifts.

import { test, expect } from "bun:test";
import { byteToUtf16 } from "../src/editor/mahinaLinter";

test("ASCII is the identity map", () => {
  const src = "local x = 1\n";
  const map = byteToUtf16(src);
  for (let i = 0; i <= src.length; i++) {
    // For pure ASCII, byte offset i maps to UTF-16 index i.
    expect(map[i]).toBe(i);
  }
});

test("end sentinel is the document length", () => {
  const src = "print(1)";
  const map = byteToUtf16(src);
  const byteLen = new TextEncoder().encode(src).length;
  expect(map[byteLen]).toBe(src.length);
});

test("a 2-byte char shifts subsequent byte offsets by one", () => {
  // "é" is 2 UTF-8 bytes but 1 UTF-16 unit. Bytes: a(0) é(1,2) b(3).
  const src = "aéb";
  const map = byteToUtf16(src);
  expect(map[0]).toBe(0); // 'a'
  expect(map[1]).toBe(1); // first byte of 'é'
  expect(map[2]).toBe(1); // second byte of 'é' still maps to 'é'
  expect(map[3]).toBe(2); // 'b' is UTF-16 index 2
  expect(map[4]).toBe(3); // end sentinel = src.length
});

test("a 4-byte astral char occupies a surrogate pair (2 UTF-16 units)", () => {
  // "�localx": 𝑙... use an emoji. "a😀b": a(0) 😀(1..4, 4 bytes, 2 units) b(5).
  const src = "a😀b";
  const map = byteToUtf16(src);
  expect(map[0]).toBe(0); // 'a' at unit 0
  expect(map[1]).toBe(1); // first byte of emoji → unit 1 (start of surrogate pair)
  expect(map[4]).toBe(1); // last byte of emoji still the emoji's start unit
  expect(map[5]).toBe(3); // 'b' is at UTF-16 unit 3 (after the 2-unit pair)
  expect(map[6]).toBe(src.length); // end sentinel; src.length == 4 (a + 2 + b)
});
