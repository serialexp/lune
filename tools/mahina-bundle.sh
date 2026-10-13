#!/usr/bin/env bash
# The vendor bundle: prebuilt, stripped, position-independent libmahina
# archives for every supported Rust target, plus the header and the Rust
# binding crates, in one directory a downstream repo copies in verbatim.
# Run it via `just bundle [out]` (default zig-out/mahina-bundle).
#
#   <out>/
#     LUNE_COMMIT          full sha of HEAD, "-dirty" if the tree wasn't clean
#     ZIG_VERSION          the pinned toolchain the archives were built with
#     include/mahina.h
#     rust/mahina/         the binding crates, as in embed/rust/
#     rust/mahina-sys/
#     lib/<rust-target-triple>/libmahina.a   (mahina.lib on MSVC)
#     SHA256SUMS           one line per archive
#
# A consumer points mahina-sys at <out>/lib with MAHINA_PREBUILT_ROOT; its
# build.rs picks lib/$TARGET/ and never invokes zig.
#
# Every archive is ReleaseFast, -Dlib-pic=true and -Dlib-strip=true. The
# directory names are Rust triples (what cargo's TARGET says); TARGETS maps
# each to the zig target it is built for. The glibc and macOS floors are the
# Rust targets' own (glibc 2.17; macOS 10.12 x86-64, 11.0 arm64), so an
# archive never asks more of the host than the Rust target already does.
# Linux ships separate gnu and musl archives: a musl-built archive is not
# libc-agnostic (on aarch64 glibc's pthread_attr_t is 64 bytes to musl's 56,
# and it calls statx/getrandom/copy_file_range, which need glibc >= 2.28).
#
# Reproducible: the same commit and toolchain give byte-identical archives
# wherever the checkout lives. zig names ELF/COFF archive members after their
# cache path (.zig-cache/o/<hash>/mahina_zcu.o), so each archive is re-packed
# with plain member names; `zig ar` writes zeroed timestamps and ids.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
out=${1:-$root/zig-out/mahina-bundle}

# rust-target-triple  zig-target
TARGETS=(
    "x86_64-unknown-linux-musl   x86_64-linux-musl"
    "aarch64-unknown-linux-musl  aarch64-linux-musl"
    "x86_64-unknown-linux-gnu    x86_64-linux-gnu.2.17"
    "aarch64-unknown-linux-gnu   aarch64-linux-gnu.2.17"
    "x86_64-apple-darwin         x86_64-macos.10.12"
    "aarch64-apple-darwin        aarch64-macos.11.0"
    "x86_64-pc-windows-msvc      x86_64-windows-msvc"
    "aarch64-pc-windows-msvc     aarch64-windows-msvc"
)

die() {
    echo "mahina-bundle: $*" >&2
    exit 1
}

# The bundle is replaced wholesale, so refuse any existing directory that
# isn't a previous bundle.
if [[ -e $out && ! -f $out/LUNE_COMMIT ]]; then
    die "$out exists and is not a mahina bundle; refusing to replace it"
fi

pinned=$(tr -d '[:space:]' <"$root/.zig-version")
active=$(zig version)
[[ $active == "$pinned" ]] || die "zig is $active but the repo pins $pinned"

commit=$(git -C "$root" rev-parse HEAD)
if [[ -n $(git -C "$root" status --porcelain) ]]; then
    commit="$commit-dirty"
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/mahina-bundle.XXXXXX")
trap 'rm -rf "$work"' EXIT
stage=$work/bundle
mkdir -p "$stage/lib" "$stage/include" "$stage/rust"

# Re-pack archive $1 into $2 with every member under its plain file name, in
# the original order. The format follows the object format: COFF for MSVC,
# darwin for Mach-O, gnu for ELF. `zig ar` regenerates the symbol index.
repack() {
    local src=$1 dst=$2 format=$3
    local members=() names=() m name
    mapfile -t members < <(zig ar t "$src" | grep -v '^__\.SYMDEF')
    [[ ${#members[@]} -gt 0 ]] || die "$src has no members"
    mkdir -p "$work/members"
    rm -f "$work/members"/*
    for m in "${members[@]}"; do
        name=${m##*/}
        [[ ! -e $work/members/$name ]] || die "$src: two members named $name"
        zig ar p "$src" "$m" >"$work/members/$name"
        names+=("$name")
    done
    rm -f "$dst"
    (cd "$work/members" && zig ar rcsD --format="$format" "$dst" "${names[@]}")
}

for entry in "${TARGETS[@]}"; do
    read -r rust_triple zig_target <<<"$entry"
    case $rust_triple in
        *-msvc) archive=mahina.lib format=coff ;;
        *-apple-*) archive=libmahina.a format=darwin ;;
        *) archive=libmahina.a format=gnu ;;
    esac
    echo "mahina-bundle: $rust_triple (zig $zig_target)"
    (cd "$root" && zig build lib -Dtarget="$zig_target" -Doptimize=ReleaseFast \
        -Dlib-pic=true -Dlib-strip=true --prefix "$work/build/$rust_triple")
    mkdir -p "$stage/lib/$rust_triple"
    repack "$work/build/$rust_triple/lib/$archive" "$stage/lib/$rust_triple/$archive" "$format"
done

cp "$root/include/mahina.h" "$stage/include/"
# The crates' sources: tracked files plus untracked-but-not-ignored ones, so
# a dirty bundle carries exactly the tree LUNE_COMMIT says it does.
for crate in mahina mahina-sys; do
    (cd "$root/embed/rust" && git ls-files -co --exclude-standard -- "$crate") |
        while IFS= read -r f; do
            mkdir -p "$stage/rust/$(dirname "$f")"
            cp "$root/embed/rust/$f" "$stage/rust/$f"
        done
done

echo "$commit" >"$stage/LUNE_COMMIT"
echo "$active" >"$stage/ZIG_VERSION"
(cd "$stage" && find lib -type f | LC_ALL=C sort | xargs sha256sum) >"$stage/SHA256SUMS"

rm -rf "$out"
mkdir -p "$(dirname "$out")"
mv "$stage" "$out"
echo "mahina-bundle: wrote $out ($commit)"
ls -l "$out"/lib/*/*
