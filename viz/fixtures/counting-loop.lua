-- Cross-language fixture source for the lune trace inspector.
--
-- Running this under the tracing JIT records one hot root trace at the loop
-- header. The committed trace cache is serialized to counting-loop.lunetrace
-- (see this directory's note / tools/regen-trace-schema.sh sibling step):
--
--   zig build && ./zig-out/bin/lune --emit-traces \
--       viz/fixtures/counting-loop.lunetrace viz/fixtures/counting-loop.lua
--
-- viz/test/decode.test.ts decodes the committed artifact in TypeScript and
-- asserts its structure — the Zig-encode ↔ TS-decode cross-language proof.
local n = 0
for i = 1, 2000 do
  n = n + i * 2
end
print(n)
