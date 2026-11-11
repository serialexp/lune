#!/usr/bin/env bash
# Install the Zig toolchain .zig-version pins, on an x86-64 Linux CI runner,
# from the community mirror list (as ziglang.org asks CI to) at a pinned
# digest rather than trusting whichever mirror answers first. Fails if
# .zig-version and ZIG_VERSION disagree.
#
#   ZIG_VERSION=0.17.0 ZIG_SHA256=<x86_64-linux tarball shasum> tools/install-zig.sh
#
# The digest is ziglang.org/download/index.json's shasum for the x86_64-linux
# tarball; update ZIG_VERSION *and* ZIG_SHA256 together with .zig-version.
# Installs into $ZIG_DIR (default: $RUNNER_TEMP/zig, else /tmp/zig) and, when
# $GITHUB_PATH is set (GitHub-compatible CI), puts it on the PATH of later steps.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
: "${ZIG_VERSION:?set ZIG_VERSION}"
: "${ZIG_SHA256:?set ZIG_SHA256}"
dest=${ZIG_DIR:-${RUNNER_TEMP:-/tmp}/zig}

pinned=$(tr -d '[:space:]' <"$root/.zig-version")
if [[ $pinned != "$ZIG_VERSION" ]]; then
    echo "::error::.zig-version says '$pinned' but this workflow pins '$ZIG_VERSION'"
    echo "Update ZIG_VERSION *and* ZIG_SHA256 together."
    exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
tarball="zig-x86_64-linux-${ZIG_VERSION}.tar.xz"
curl -fsSL -o "$work/mirrors.txt" https://ziglang.org/download/community-mirrors.txt
ok=
while read -r mirror; do
    [[ -n $mirror ]] || continue
    echo "trying $mirror"
    if curl -fsSL --max-time 180 -o "$work/zig.tar.xz" "$mirror/$tarball"; then
        if echo "$ZIG_SHA256  $work/zig.tar.xz" | sha256sum -c -; then
            ok=1
            break
        fi
        echo "digest mismatch from $mirror - discarding"
        rm -f "$work/zig.tar.xz"
    fi
done <"$work/mirrors.txt"
if [[ -z $ok ]]; then
    echo "::error::no mirror served $tarball at the pinned digest"
    exit 1
fi

mkdir -p "$dest"
tar -xJf "$work/zig.tar.xz" -C "$dest" --strip-components=1
[[ $("$dest/zig" version) == "$ZIG_VERSION" ]] || {
    echo "::error::the installed zig is not $ZIG_VERSION"
    exit 1
}
if [[ -n ${GITHUB_PATH:-} ]]; then
    echo "$dest" >>"$GITHUB_PATH"
fi
echo "zig $ZIG_VERSION at $dest"
