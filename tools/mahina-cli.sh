#!/usr/bin/env bash
# The CLI release: a `mahina` binary per platform with the trace visualiser
# (viz/) embedded, so `mahina viz` serves it with nothing else installed.
# Run it via `just cli [out]` (default zig-out/mahina-cli). Needs zig (the
# pinned one), Node >= 22.13 and pnpm (the version viz/package.json pins;
# viz/pnpm-lock.yaml is the UI's lockfile).
#
#   <out>/
#     LUNE_COMMIT                       full sha of HEAD, "-dirty" if the tree wasn't clean
#     ZIG_VERSION                       the pinned toolchain the binaries were built with
#     mahina-<platform>.tar.gz          mahina-<platform>/mahina (Linux, macOS)
#     mahina-<platform>.zip             mahina-<platform>/mahina.exe (Windows)
#     SHA256SUMS                        one line per archive
#
# The web UI is built once: the wasm VM (ReleaseFast, stripped), then
# `vite build` against it into a scratch directory, which every binary embeds
# through `-Dviz-dist` (tools/embed_assets.zig). Every binary is ReleaseFast
# and stripped. The CLI links no libc on Linux, so one static binary per
# architecture covers glibc and musl hosts alike; the macOS floors are the
# vendor bundle's (10.12 x86-64, 11.0 arm64). The native JIT is x86-64 Linux
# only; elsewhere `--jit-native` falls back to the interpreter tiers.
#
# Reproducible: the same commit and toolchain give byte-identical archives
# (sorted names, zeroed owners, fixed mtimes, gzip -n, zip -X).
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
out=${1:-$root/zig-out/mahina-cli}

# platform  zig-target
TARGETS=(
    "x86_64-linux    x86_64-linux"
    "aarch64-linux   aarch64-linux"
    "x86_64-macos    x86_64-macos.10.12"
    "aarch64-macos   aarch64-macos.11.0"
    "x86_64-windows  x86_64-windows"
    "aarch64-windows aarch64-windows"
)

die() {
    echo "mahina-cli: $*" >&2
    exit 1
}

# The output is replaced wholesale, so refuse any existing directory that
# isn't a previous one.
if [[ -e $out && ! -f $out/LUNE_COMMIT ]]; then
    die "$out exists and is not a mahina-cli output; refusing to replace it"
fi

pinned=$(tr -d '[:space:]' <"$root/.zig-version")
active=$(zig version)
[[ $active == "$pinned" ]] || die "zig is $active but the repo pins $pinned"
command -v pnpm >/dev/null || die "pnpm is needed to build the web UI"
command -v node >/dev/null || die "node is needed to build the web UI"

commit=$(git -C "$root" rev-parse HEAD)
if [[ -n $(git -C "$root" status --porcelain) ]]; then
    commit="$commit-dirty"
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/mahina-cli.XXXXXX")
trap 'rm -rf "$work"' EXIT
stage=$work/out
mkdir -p "$stage"

echo "mahina-cli: wasm VM"
(cd "$root" && zig build wasm -Doptimize=ReleaseFast -Dwasm-strip=true --prefix "$work/wasm")

echo "mahina-cli: web UI"
(cd "$root/viz" && pnpm install --frozen-lockfile &&
    MAHINA_WASM="$work/wasm/bin/mahina.wasm" pnpm run build --outDir "$work/dist" --emptyOutDir)
[[ -f $work/dist/index.html && -f $work/dist/mahina.wasm ]] || die "vite build produced no index.html/mahina.wasm"

for entry in "${TARGETS[@]}"; do
    read -r platform zig_target <<<"$entry"
    echo "mahina-cli: $platform (zig $zig_target)"
    (cd "$root" && zig build -Dtarget="$zig_target" -Doptimize=ReleaseFast -Dcli-strip=true \
        -Dviz-dist="$work/dist" -Dversion-commit="$commit" --prefix "$work/build/$platform")
    pkg=$work/pkg/mahina-$platform
    mkdir -p "$pkg"
    case $platform in
        *-windows)
            cp "$work/build/$platform/bin/mahina.exe" "$pkg/"
            # zip stores local times: pin both the timestamp and the zone.
            TZ=UTC touch -t 198001010000 "$pkg" "$pkg/mahina.exe"
            (cd "$work/pkg" && TZ=UTC zip -X -q -r "$stage/mahina-$platform.zip" "mahina-$platform")
            ;;
        *)
            cp "$work/build/$platform/bin/mahina" "$pkg/"
            chmod 755 "$pkg/mahina"
            (cd "$work/pkg" && tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner \
                --mode='u+rwX,go+rX,go-w' --format=gnu -cf - "mahina-$platform" |
                gzip -9 -n >"$stage/mahina-$platform.tar.gz")
            ;;
    esac
done

echo "$commit" >"$stage/LUNE_COMMIT"
echo "$active" >"$stage/ZIG_VERSION"
(cd "$stage" && find . -maxdepth 1 -name 'mahina-*' -type f -printf '%f\n' | LC_ALL=C sort |
    xargs sha256sum) >"$stage/SHA256SUMS"

rm -rf "$out"
mkdir -p "$(dirname "$out")"
mv "$stage" "$out"
echo "mahina-cli: wrote $out ($commit)"
ls -l "$out"
