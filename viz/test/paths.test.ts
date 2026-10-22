// The TS mirror of src/relpath.zig: the same lexical normalization decides
// which workspace file a program's `require` reads in the browser and under
// `mahina viz`, so the two must agree.

import { test, expect } from "bun:test";
import { normalizePath, baseName } from "../src/paths";

test("normalizePath drops `.` and empty segments and resolves `..`", () => {
  expect(normalizePath("./mod.mah")).toBe("mod.mah");
  expect(normalizePath("lib//./x.mah")).toBe("lib/x.mah");
  expect(normalizePath("lib/../x.mah")).toBe("x.mah");
  expect(normalizePath("a/b/../../c/d.mah")).toBe("c/d.mah");
});

test("normalizePath refuses absolute, escaping and empty paths", () => {
  expect(normalizePath("/etc/passwd")).toBeNull();
  expect(normalizePath("../x.mah")).toBeNull();
  expect(normalizePath("lib/../../x.mah")).toBeNull();
  expect(normalizePath("")).toBeNull();
  expect(normalizePath("./")).toBeNull();
  // The Zig side's buffer bounds the normalized path, not the input.
  expect(normalizePath("x".repeat(1025))).toBeNull();
  expect(normalizePath("x".repeat(1024))).toBe("x".repeat(1024));
  expect(normalizePath("./".repeat(600) + "x.mah")).toBe("x.mah");
});

test("baseName is the last path segment", () => {
  expect(baseName("lib/x.mah")).toBe("x.mah");
  expect(baseName("x.mah")).toBe("x.mah");
});
