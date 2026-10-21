// Unit test for the URL the worker client hands the mahina worker to fetch the
// wasm from. The worker resolves a relative URL against its own script
// (`/assets/…`), so the client must hand it an absolute URL resolved against
// the page — a relative `./mahina.wasm` made Run 404 in `mahina viz`.

import { test, expect } from "bun:test";
import { resolveWasmUrl } from "../src/wasm/mahina-client";

test("the built base `./` resolves next to the page, not the worker script", () => {
  // `mahina viz` serves index.html at `/` and the bundle under `/assets/`.
  const url = resolveWasmUrl("./", "http://127.0.0.1:8137/");
  expect(url).toBe("http://127.0.0.1:8137/mahina.wasm");
});

test("a page under a sub-path keeps the wasm beside it", () => {
  const url = resolveWasmUrl("./", "https://example.com/tools/viz/index.html");
  expect(url).toBe("https://example.com/tools/viz/mahina.wasm");
});

test("the dev server's absolute base `/` resolves from the origin", () => {
  const url = resolveWasmUrl("/", "http://localhost:5173/some/page");
  expect(url).toBe("http://localhost:5173/mahina.wasm");
});

test("the result is absolute, so the worker cannot re-resolve it", () => {
  const url = resolveWasmUrl("./", "http://127.0.0.1:8137/");
  expect(new URL(url).href).toBe(url);
  expect(new URL(url, "http://127.0.0.1:8137/assets/mahina.worker-abc.js").href).toBe(url);
});
