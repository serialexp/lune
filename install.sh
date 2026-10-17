#!/bin/sh
# Install the mahina CLI from a GitHub Release (Linux and macOS).
#
#   curl -fsSL https://raw.githubusercontent.com/serialexp/lune/master/install.sh | sh
#
# Picks the archive for this OS and CPU, checks it against the release's
# SHA256SUMS, and installs `mahina` into ~/.local/bin. Settings, all optional:
#
#   MAHINA_VERSION=v0.1.2       a release tag (default: the latest release)
#   MAHINA_INSTALL_DIR=<dir>    where `mahina` goes (default: ~/.local/bin)
#   MAHINA_BASE_URL=<url>       the releases root (default: the GitHub
#                               repo's; tools/install-smoke.sh points it at
#                               a local server)
#
# Windows: download mahina-<version>-<arch>-windows.zip from the release page.
set -eu

repo_releases=https://github.com/serialexp/lune/releases
base=${MAHINA_BASE_URL:-$repo_releases}
install_dir=${MAHINA_INSTALL_DIR:-$HOME/.local/bin}

say() { printf 'mahina-install: %s\n' "$*"; }
die() {
    printf 'mahina-install: error: %s\n' "$*" >&2
    exit 1
}

if command -v curl >/dev/null 2>&1; then
    fetch() { curl -fsSL -o "$2" "$1"; }
    # The URL `releases/latest` redirects to (…/tag/<tag>).
    latest_url() { curl -fsSLI -o /dev/null -w '%{url_effective}' "$1"; }
elif command -v wget >/dev/null 2>&1; then
    fetch() { wget -q -O "$2" "$1"; }
    latest_url() { wget -q -S --spider "$1" 2>&1 | sed -n 's/^ *[Ll]ocation: *//p' | tail -1 | tr -d '\r'; }
else
    die "needs curl or wget"
fi

if command -v sha256sum >/dev/null 2>&1; then
    sha256() { sha256sum "$1" | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then
    sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }
else
    die "needs sha256sum or shasum to verify the download"
fi

case $(uname -s) in
    Linux) os=linux ;;
    Darwin) os=macos ;;
    MINGW* | MSYS* | CYGWIN*) die "on Windows, download the .zip from $repo_releases" ;;
    *) die "no mahina build for $(uname -s)" ;;
esac
case $(uname -m) in
    x86_64 | amd64) arch=x86_64 ;;
    aarch64 | arm64) arch=aarch64 ;;
    *) die "no mahina build for $(uname -m)" ;;
esac
# A shell under Rosetta reports x86_64 on an Apple silicon Mac; take the
# native build.
if [ "$os" = macos ] && [ "$arch" = x86_64 ] &&
    [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" = 1 ]; then
    arch=aarch64
fi
platform=$arch-$os

version=${MAHINA_VERSION:-}
if [ -z "$version" ]; then
    url=$(latest_url "$base/latest") || die "cannot reach $base/latest"
    version=${url##*/}
    case $version in
        v*) ;;
        *) die "cannot tell the latest release from $url; set MAHINA_VERSION" ;;
    esac
fi

asset=mahina-$version-$platform.tar.gz
sums=mahina-$version-SHA256SUMS
work=$(mktemp -d "${TMPDIR:-/tmp}/mahina-install.XXXXXX")
trap 'rm -rf "$work"' EXIT INT TERM

say "installing mahina $version for $platform"
fetch "$base/download/$version/$asset" "$work/$asset" ||
    die "cannot download $asset (does release $version have it?)"
fetch "$base/download/$version/$sums" "$work/$sums" || die "cannot download $sums"
want=$(awk -v f="$asset" '$2 == f || $2 == "*" f { print $1 }' "$work/$sums")
[ -n "$want" ] || die "$sums has no entry for $asset"
got=$(sha256 "$work/$asset")
[ "$got" = "$want" ] || die "$asset: sha256 is $got, the release says $want"

tar -xzf "$work/$asset" -C "$work"
[ -f "$work/mahina-$platform/mahina" ] || die "$asset has no mahina-$platform/mahina"

mkdir -p "$install_dir"
# Copy beside the target, then rename over it: a running mahina is never
# left half-written.
cp "$work/mahina-$platform/mahina" "$install_dir/.mahina.$$"
chmod 755 "$install_dir/.mahina.$$"
mv -f "$install_dir/.mahina.$$" "$install_dir/mahina"
say "installed $install_dir/mahina"
"$install_dir/mahina" --version | sed -n '1p;2p' | sed 's/^/  /'

case :${PATH}: in
    *:"$install_dir":*) ;;
    *)
        say "$install_dir is not on your PATH; add it, e.g.:"
        printf '  echo '\''export PATH="%s:$PATH"'\'' >> ~/.profile\n' "$install_dir"
        ;;
esac
