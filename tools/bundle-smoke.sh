#!/usr/bin/env bash
# Smoke-check a vendor bundle (tools/mahina-bundle.sh) the way a downstream
# repo consumes it: a minimal Rust crate (tests/bundle_smoke/main.rs) that
# depends on <bundle>/rust/mahina, built with MAHINA_PREBUILT_ROOT=<bundle>/lib
# and NO zig reachable, then run. Run it via
# `just bundle-smoke [bundle] [rust-triple...]` (default: zig-out/mahina-bundle,
# every target in the bundle), or directly:
#
#   tools/bundle-smoke.sh [--strict] [bundle] [rust-triple...]
#
# --strict turns every SKIP into a failure (CI: .github/workflows/bundle.yml
# gives each target a native runner, so nothing there may be skipped).
#
# Per target the result is PASS, FAIL, or SKIP with the missing tool named:
#   - same platform as the host (arch + OS; musl and gnu are both "linux"):
#     native build and run, on any OS — this is the CI path;
#   - linux aarch64 from another host: linked with aarch64-linux-gnu-gcc, run
#     under qemu-aarch64 (-L /usr/aarch64-linux-gnu for gnu);
#   - windows msvc from another host: linked with `cargo xwin` (MSVC CRT +
#     Windows SDK); x86-64 runs under wine, aarch64 is link-only;
#   - apple darwin from another host: needs a macOS SDK + ld64, so a SKIP.
# Plus the archive-level checks, on an x86-64 linux host:
#   - the x86-64 musl archive also links into (and runs in) a gnu binary;
#   - no R_X86_64_32/32S relocation outside .rela.debug* in either x86-64
#     linux archive (the bundle is stripped, so there is no .debug* at all).
# Exits non-zero on any FAIL. SKIPs are listed at the end.
#
# Portable to macOS's stock bash 3.2 (no mapfile; empty arrays are expanded
# with the ${a[@]+...} guard, which `set -u` needs there) and to Git Bash on
# Windows (paths handed to cargo go through `cygpath -m`).
set -uo pipefail

strict=0
if [[ ${1:-} == --strict ]]; then
    strict=1
    shift
fi

root=$(cd "$(dirname "$0")/.." && pwd)
bundle=$(cd "${1:-$root/zig-out/mahina-bundle}" && pwd) || exit 1
shift || true
[[ -f $bundle/LUNE_COMMIT ]] || { echo "bundle-smoke: $bundle is not a mahina bundle" >&2; exit 1; }

targets=()
if [[ $# -gt 0 ]]; then
    targets=("$@")
else
    for d in "$bundle"/lib/*/; do
        d=${d%/}
        targets+=("${d##*/}")
    done
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/mahina-bundle-smoke.XXXXXX")
trap 'rm -rf "$work"' EXIT

passes=() fails=() skips=()
pass() { echo "PASS: $*"; passes+=("$*"); }
fail() { echo "FAIL: $*"; fails+=("$*"); }
skip() { echo "SKIP: $*"; skips+=("$*"); }

have() { command -v "$1" >/dev/null; }

# A path as a native (non-MSYS) program wants it: D:/a/... under Git Bash,
# unchanged elsewhere.
native_path() {
    if have cygpath; then cygpath -m "$1"; else echo "$1"; fi
}

# arch + OS family of a Rust triple: musl and gnu linux binaries both run
# on a linux host of that arch.
platform() {
    local os
    case $1 in
        *-linux-*) os=linux ;;
        *-apple-darwin) os=darwin ;;
        *-windows-*) os=windows ;;
        *) os=other ;;
    esac
    echo "${1%%-*}-$os"
}

host=$(rustc -vV | sed -n 's/^host: //p')
[[ -n $host ]] || { echo "bundle-smoke: could not read the rustc host triple" >&2; exit 1; }

# The consumer crate: standalone (its own [workspace]) so no enclosing
# manifest is consulted.
crate=$work/crate
mkdir -p "$crate/src"
cp "$root/tests/bundle_smoke/main.rs" "$crate/src/main.rs"
cat >"$crate/Cargo.toml" <<EOF
[package]
name = "mahina-bundle-smoke"
version = "0.0.0"
edition = "2021"
publish = false

[dependencies]
mahina = { path = "$(native_path "$bundle/rust/mahina")" }

[workspace]
EOF

# PATH with every directory that holds a zig removed, and ZIG pointed nowhere:
# the build must not be able to reach a zig even by accident.
nozig_path=$(
    IFS=:
    keep=()
    for d in $PATH; do
        [[ -x $d/zig || -x $d/zig.exe ]] || keep+=("$d")
    done
    echo "${keep[*]+"${keep[*]}"}"
)
if PATH=$nozig_path command -v zig >/dev/null; then
    echo "bundle-smoke: could not hide zig from PATH" >&2
    exit 1
fi

# cargo_for <rust-triple> <subcommand...>: build the consumer crate for the
# target against the bundle, zig-free, with `extra_env` (VAR=value entries)
# added to the environment.
extra_env=()
cargo_for() {
    local triple=$1
    shift
    env PATH="$nozig_path" ZIG=/nonexistent/zig \
        MAHINA_PREBUILT_ROOT="$(native_path "$bundle/lib")" \
        CARGO_TARGET_DIR="$(native_path "$work/target")" \
        ${extra_env[@]+"${extra_env[@]}"} \
        cargo "$@" --quiet --release --target "$triple" --manifest-path "$(native_path "$crate/Cargo.toml")"
}

bin_of() {
    local ext=
    [[ $1 == *-windows-* ]] && ext=.exe
    echo "$work/target/$1/release/mahina-bundle-smoke$ext"
}

# run_check <label> <cmd...>: run the smoke binary, PASS iff it printed ok.
run_check() {
    local label=$1 out
    shift
    if out=$("$@" 2>&1) && [[ $out == *"bundle-smoke ok"* ]]; then
        pass "$label"
    else
        fail "$label (run: $out)"
    fi
}

for t in ${targets[@]+"${targets[@]}"}; do
    rustup target list --installed | grep -qx "$t" || { skip "$t: rust target not installed (rustup target add $t)"; continue; }

    if [[ $(platform "$t") == "$(platform "$host")" ]]; then
        if cargo_for "$t" build; then
            run_check "$t (native on $host)" "$(bin_of "$t")"
        else
            fail "$t: build"
        fi
        continue
    fi

    case $t in
        aarch64-unknown-linux-gnu | aarch64-unknown-linux-musl)
            have aarch64-linux-gnu-gcc || { skip "$t: aarch64-linux-gnu-gcc not installed"; continue; }
            extra_env=("CARGO_TARGET_$(echo "$t" | tr 'a-z-' 'A-Z_')_LINKER=aarch64-linux-gnu-gcc")
            if ! cargo_for "$t" build; then
                extra_env=()
                fail "$t: build"
                continue
            fi
            extra_env=()
            have qemu-aarch64 || { skip "$t: linked, but qemu-aarch64 is not installed to run it"; continue; }
            if [[ $t == *-gnu ]]; then
                run_check "$t (qemu)" qemu-aarch64 -L /usr/aarch64-linux-gnu "$(bin_of "$t")"
            else
                run_check "$t (qemu)" qemu-aarch64 "$(bin_of "$t")"
            fi
            ;;
        *-pc-windows-msvc)
            have cargo-xwin || { skip "$t: cargo-xwin not installed (MSVC CRT/SDK for the link)"; continue; }
            if ! cargo_for "$t" xwin build; then
                fail "$t: build"
                continue
            fi
            if [[ $t == x86_64-* ]]; then
                have wine || { skip "$t: linked, but wine is not installed to run it"; continue; }
                run_check "$t (wine)" wine "$(bin_of "$t")"
            else
                skip "$t: linked, but there is no aarch64 windows runner here"
            fi
            ;;
        *-apple-darwin)
            skip "$t: no macOS SDK/ld64 on this host; archive link unproven"
            ;;
        *)
            fail "$t: no smoke recipe for this target from $host"
            ;;
    esac
done

if [[ $host == x86_64-unknown-linux-gnu ]]; then
    # The x86-64 musl archive in a gnu binary (glibc host): MAHINA_LIB_DIR at
    # the musl directory, gnu target.
    musl_dir=$bundle/lib/x86_64-unknown-linux-musl
    if [[ -f $musl_dir/libmahina.a ]]; then
        if env -u MAHINA_PREBUILT_ROOT PATH="$nozig_path" ZIG=/nonexistent/zig \
            MAHINA_LIB_DIR="$musl_dir" CARGO_TARGET_DIR="$work/target-musl-in-gnu" \
            cargo build --quiet --release --target x86_64-unknown-linux-gnu --manifest-path "$crate/Cargo.toml"; then
            run_check "x86_64 musl archive in a gnu binary" "$work/target-musl-in-gnu/x86_64-unknown-linux-gnu/release/mahina-bundle-smoke"
        else
            fail "x86_64 musl archive in a gnu binary: build"
        fi
    fi

    # Absolute 32-bit relocations would break every PIE/shared link.
    for t in x86_64-unknown-linux-musl x86_64-unknown-linux-gnu; do
        a=$bundle/lib/$t/libmahina.a
        [[ -f $a ]] || continue
        have readelf || { skip "$t: relocation check needs readelf"; continue; }
        n=$(readelf -rW "$a" | awk '/^Relocation section/ { sec = $3 } /R_X86_64_(32|32S) / && sec !~ /\.rela\.debug/ { n++ } END { print n + 0 }')
        if [[ $n == 0 ]]; then
            pass "$t: no R_X86_64_32/32S outside .rela.debug*"
        else
            fail "$t: $n R_X86_64_32/32S relocations outside .rela.debug*"
        fi
    done
fi

echo
echo "bundle-smoke: ${#passes[@]} passed, ${#fails[@]} failed, ${#skips[@]} skipped on $host ($(cat "$bundle/LUNE_COMMIT"))"
for s in ${skips[@]+"${skips[@]}"}; do echo "  skipped: $s"; done
for f in ${fails[@]+"${fails[@]}"}; do echo "  failed: $f"; done
[[ ${#fails[@]} == 0 ]] || exit 1
if [[ $strict == 1 && ${#skips[@]} -gt 0 ]]; then
    echo "bundle-smoke: --strict, and ${#skips[@]} check(s) were skipped" >&2
    exit 1
fi
