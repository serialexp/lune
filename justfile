# lune — task runner. Thin wrappers over `zig build`; see CLAUDE.md for the
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
# zig-out/bin/lune (Debug) — otherwise a test-only run leaves the installed CLI
# stale and you debug a binary that predates your changes (costs a few seconds,
# saves a debugging detour).
test: build
    zig build test

# Run the CLI (debug):  just run -- script.lua [args...]
run *args:
    zig build run -- {{args}}

# NB: leaves zig-out/bin/lune as DEBUG — re-run `just release`/`just bench`
# before timing anything afterward.
# Hard-fail on Zig toolchain drift (CI).
check-version:
    zig build -Denforce-zig-version=true

# Args pass through to bench/run.py: just bench --filter str / --reps 7 / --no-luajit
# Run the benchmark suite (rebuilds ReleaseFast first, so never a stale Debug binary).
bench *args: release
    python3 bench/run.py {{args}}

# Copy this tree to DEST for an A/B shadow build (baseline binaries), stripping
# .zig-cache/zig-out so the shadow build can never reuse THIS tree's artifacts.
# A copied cache once made the "pre" baseline a post-source binary and burned an
# hour on a phantom regression (CURRENT_TASK LATEST-69). After this, restore the
# baseline sources in DEST (`git show HEAD:<file> > <file>`), build there, and
# verify the binary is really the baseline: `nm DEST/zig-out/bin/lune | grep
# <new-symbol>` must come up empty.
shadow dest:
    rm -rf {{dest}}
    cp -r . {{dest}}
    rm -rf {{dest}}/.zig-cache {{dest}}/zig-out

# Regenerate src/gen/unicode_case.zig from the vendored UCD (design doc 06, S-C).
# Pure + offline; only needed when re-vendoring a new pinned Unicode version.
gen-unicode:
    python3 tools/gen_unicode_case.py --version 16.0.0 --ucd vendor/ucd/16.0.0/UnicodeData.txt --out src/gen/unicode_case.zig
