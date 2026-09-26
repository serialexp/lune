# mahina — task runner. Thin wrappers over `zig build`; see CLAUDE.md for the
# rules these encode. Run `just` with no args to list recipes.

_default:
    @just --list

# Build the CLI (debug).
build:
    zig build

# Build the optimized CLI (ReleaseFast) — the binary benchmarks must use.
release:
    zig build -Doptimize=ReleaseFast

# Run the unit-test gate. Depends on `build` so it also refreshes
# zig-out/bin/mahina (Debug) — otherwise a test-only run leaves the installed CLI
# stale and you debug a binary that predates your changes (costs a few seconds,
# saves a debugging detour).
test: build check-jit-boundaries
    zig build test

# Enforce the implemented JIT dependency boundaries, including scanner tests.
check-jit-boundaries:
    python3 -m unittest discover -s tools -p test_jit_boundaries.py
    python3 tools/check-jit-boundaries.py

# Run the CLI (debug):  just run -- script.lua [args...]
run *args:
    zig build run -- {{args}}

# NB: leaves zig-out/bin/mahina as DEBUG — re-run `just release`/`just bench`
# before timing anything afterward.
# Hard-fail on Zig toolchain drift (CI).
check-version:
    zig build -Denforce-zig-version=true

# Args pass through to bench/run.py: just bench --filter str / --reps 7 / --no-luajit
# Run the benchmark suite (rebuilds ReleaseFast first, so never a stale Debug binary).
bench *args: release
    python3 bench/run.py {{args}}

# Frozen-output gate: every benchmark's stdout must match the digests committed
# in bench/refs/. This is the half `bench/run.py` cannot do — it proves the tiers
# agree with each OTHER, which a change that moves all three identically still
# passes. Builds ReleaseFast first because the refs were generated that way.
#
# TWO LEGS. The corpus is run under the ReleaseFast binary the refs describe AND
# under a safety-checked Debug build (installed to its own prefix, since both
# would otherwise be zig-out/bin/mahina). The Debug leg is not redundant: it is the
# only thing that exercises `std.debug.assert` and the `@enumFromInt` safety
# check across all 84 configurations, and it is what finally caught two
# memory-safety bugs that ReleaseFast had been sailing through. Both legs gate
# against the same refs — they must agree.
# Regenerate deliberately (and say why in the commit): just hashgate --generate
hashgate *args: release
    zig build --prefix zig-out-debug
    python3 tools/hashgate.py --also-mahina zig-out-debug/bin/mahina {{args}}

# Copy this tree to DEST for an A/B shadow build (baseline binaries), stripping
# .zig-cache/zig-out so the shadow build can never reuse THIS tree's artifacts.
# A copied cache once made the "pre" baseline a post-source binary and burned an
# hour on a phantom regression (CURRENT_TASK LATEST-69). After this, restore the
# baseline sources in DEST (`git show HEAD:<file> > <file>`), build there, and
# verify the binary is really the baseline: `nm DEST/zig-out/bin/mahina | grep
# <new-symbol>` must come up empty. The caches are never copied at all (the
# local .zig-cache runs to tens of GB; copy-then-delete once filled /tmp).
shadow dest:
    rm -rf {{dest}}
    rsync -a --exclude /.zig-cache --exclude /zig-out ./ {{dest}}/

# Regenerate src/gen/unicode_case.zig from the vendored UCD (design doc 06, S-C).
# Pure + offline; only needed when re-vendoring a new pinned Unicode version.
gen-unicode:
    python3 tools/gen_unicode_case.py --version 16.0.0 --ucd vendor/ucd/16.0.0/UnicodeData.txt --out src/gen/unicode_case.zig
