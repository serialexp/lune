# Per-op probes (tier-0 cost survey, doc 66)

Microprobes for the tier-0 interpreter: what one construct costs in
instructions, against LuaJIT `-joff`. These are not `@bench` programs, so
`bench/run.py` and hashgate don't run them.

- `ops.lua`: compare, `eq`, `mod`, arithmetic, field and array access,
  calls, `#`, table construction and concatenation. LuaJIT-compatible.
- `ops2.lua`: probes with mahina-only syntax (`//`). The LuaJIT column is
  skipped for it.
- `ops3.lua`: doc 66's probes: constant loads, local-table fields,
  compare-and-branch, `== nil`, and one `pairs` step.
- `fields.lua`: field reads, writes and `__index` method lookup (item 2).

Usage, from the repo root, with a ReleaseFast build (`just release`):

```sh
bench/opprobe/measure.sh bench/opprobe/ops3.lua pairs kint lfget
M=/abs/path/mahina bench/opprobe/measure.sh lt eq     # ops.lua by default
bench/opprobe/abench.sh /abs/base/mahina /abs/new/mahina   # every @bench, both tiers
```

`measure.sh` prints marginal instructions per iteration: probe minus `base`,
each from a two-point (N, 2N) difference. `abench.sh` needs absolute binary
paths, because it runs each program from that program's own directory.
