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
import { irOpName } from "../src/enums";

const fixturePath = fileURLToPath(new URL("../fixtures/counting-loop.lunetrace", import.meta.url));
const bytes = new Uint8Array(readFileSync(fixturePath));

test("decodes the fixture header + trace count", () => {
  const file = decodeTraceFile(bytes);
  expect(file.version).toBe(2); // v2: loop-carry moved into the instr stream as φ nodes
  expect(file.traces.length).toBe(1);
});

test("trace anchor + array shapes match the recorded counting loop", () => {
  const file = decodeTraceFile(bytes);
  const t = file.traces[0];

  // Anchor: root proto (id 0), loop header at pc 5.
  expect(t.anchor_proto_id).toBe(0);
  expect(t.anchor_pc).toBe(5);

  // Shape recorded for `for i=1,2000 do n = n + i*2 end` (see --dump-traces).
  // v2: loop-carried writebacks ride the instr stream as slot-bound φ nodes
  // (the separate `exit_stores` list is gone), so the body is longer and the
  // `loop` terminator sits past the φ rows.
  expect(t.instrs.length).toBe(21);
  expect(t.entry_slots).toEqual([0, 4, 1, 2, 3]);

  // The straight-line body terminates in a single `loop` back-edge.
  expect(irOpName(t.instrs[t.instrs.length - 1].op)).toBe("loop");
  // Three carried slots survive the dead-temporary filter, as slot-bound φ rows
  // just before the loop (r0, r1, r4 — the live loop-carried registers).
  const phis = t.instrs.filter((i) => irOpName(i.op) === "phi");
  expect(phis.length).toBe(3);
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
  // a slot-bound φ renders its back-edge update and target register
  expect(view.instrs[17]).toMatchObject({ op: "phi", operands: "update=%7 -> r0" });
  // loop terminator has no operands (now past the φ rows)
  expect(view.instrs[20]).toMatchObject({ op: "loop", operands: "" });

  expect(view.consts[0]).toEqual({ slot: "k0", kind: "int", text: "2" });
});

test("traceToText reproduces the dump body (header uses proto id)", () => {
  const file = decodeTraceFile(bytes);
  const text = traceToText(file.traces[0]);
  // Header + first/last instruction lines, byte-for-byte vs --dump-traces
  // (the artifact carries the proto id, so the header shows `0:5` not `main:5`).
  expect(text.startsWith("trace 0:5  entry=[r0 r4 r1 r2 r3]\n")).toBe(true);
  expect(text).toContain("\n  %000  slot_load    r0\n");
  expect(text).toContain("\n  %004  mul          %1  %2\n");
  // v2: loop-carry rides the instr stream as slot-bound φ rows; the `exit:`
  // footer is gone and the `loop` terminator sits past the φ block.
  expect(text).toContain("\n  %017  phi          update=%7 -> r0\n");
  expect(text).toContain("\n  %020  loop         \n");
});
