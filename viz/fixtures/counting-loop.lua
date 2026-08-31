-- Cross-language fixture source for the mahina trace inspector.
--
-- Running this under the tracing JIT records one hot root trace at the loop
-- header. The committed trace cache is serialized to counting-loop.mahinatrace
-- (see this directory's note / tools/regen-trace-schema.sh sibling step):
--
--   zig build && ./zig-out/bin/mahina --emit-traces \
--       viz/fixtures/counting-loop.mahinatrace viz/fixtures/counting-loop.lua
--
-- viz/test/decode.test.ts decodes the committed artifact in TypeScript and
-- asserts its structure — the Zig-encode ↔ TS-decode cross-language proof.
local n = 0
for i = 1, 2000 do
  n = n + i * 2
end
print(n)
