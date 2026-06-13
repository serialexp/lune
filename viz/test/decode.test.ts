// Cross-language fixture test: a .lunetrace encoded by the Zig VM
// (lune --emit-traces) must decode in TypeScript to the same structure.
// This is the Zig-encode ↔ TS-decode proof for the binschema wire format.
//
// The fixture is committed (viz/fixtures/counting-loop.lunetrace); regenerate it
// with:
//   zig build && ./zig-out/bin/lune --emit-traces \
//       viz/fixtures/counting-loop.lunetrace viz/fixtures/counting-loop.lua

import { test, expect } from "bun:test";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { decodeTraceFile } from "../src/decode";
import { traceToView, traceToText } from "../src/disasm";

const fixturePath = fileURLToPath(new URL("../fixtures/counting-loop.lunetrace", import.meta.url));
const bytes = new Uint8Array(readFileSync(fixturePath));

test("decodes the fixture header + trace count", () => {
  const file = decodeTraceFile(bytes);
  expect(file.version).toBe(1);
  expect(file.traces.length).toBe(1);
});

test("trace anchor + array shapes match the recorded counting loop", () => {
  const file = decodeTraceFile(bytes);
  const t = file.traces[0];

  // Anchor: root proto (id 0), loop header at pc 5.
  expect(t.anchor_proto_id).toBe(0);
  expect(t.anchor_pc).toBe(5);

  // Shape recorded for `for i=1,2000 do n = n + i*2 end` (see --dump-traces).
  expect(t.instrs.length).toBe(18);
  expect(t.entry_slots).toEqual([0, 4, 1, 2, 3]);
  expect(t.exit_stores.length).toBe(8);

  // The straight-line body terminates in a `loop` back-edge (op ordinal 26).
  expect(t.instrs[t.instrs.length - 1].op).toBe(26);
});

test("the single const is the integer literal 2 (i*2)", () => {
  const file = decodeTraceFile(bytes);
  const consts = file.traces[0].consts;
  expect(consts.length).toBe(1);
  // tag 2 == int (mirrors value.Tag.int); body is the runtime {type,value} envelope.
  expect(consts[0].tag).toBe(2);
  const body = consts[0].body as unknown as { type: string; value: { v: bigint } };
  expect(body.type).toBe("ConstInt");
  expect(body.value.v).toBe(2n);
});

test("disasm view-model renders operands like writeIrInstr", () => {
  const file = decodeTraceFile(bytes);
  const view = traceToView(file.traces[0]);

  expect(view.instrs[0]).toMatchObject({ index: "000", op: "slot_load", operands: "r0" });
  expect(view.instrs[2]).toMatchObject({ op: "konst", operands: "k0" });
  // mul %1 %2  (two operands)
  expect(view.instrs[4]).toMatchObject({ op: "mul", operands: "%1  %2" });
  // a guard renders a single operand
  expect(view.instrs[3]).toMatchObject({ op: "guard_int", operands: "%1" });
  // loop terminator has no operands
  expect(view.instrs[17]).toMatchObject({ op: "loop", operands: "" });

  expect(view.consts[0]).toEqual({ slot: "k0", kind: "int", text: "2" });
  expect(view.exitStores[0]).toEqual({ slot: 0, ref: 7 });
});

test("traceToText reproduces the dump body (header uses proto id)", () => {
  const file = decodeTraceFile(bytes);
  const text = traceToText(file.traces[0]);
  // Header + first/last instruction lines, byte-for-byte vs --dump-traces
  // (the artifact carries the proto id, so the header shows `0:5` not `main:5`).
  expect(text.startsWith("trace 0:5  entry=[r0 r4 r1 r2 r3]\n")).toBe(true);
  expect(text).toContain("\n  %000  slot_load    r0\n");
  expect(text).toContain("\n  %004  mul          %1  %2\n");
  expect(text).toContain("\n  %017  loop         \n");
  expect(text).toContain("\n  exit: r0<-%7 r1<-%14 r4<-%14 r5<-%7 r6<-%0 r7<-%4 r8<-%1 r9<-%2\n");
});
