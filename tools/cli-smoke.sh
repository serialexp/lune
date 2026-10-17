#!/usr/bin/env bash
# Smoke-check the CLI release (tools/mahina-cli.sh) the way a user runs it:
# unpack a platform's archive, then
#   - run scripts (tier-0, and --jit-native, which falls back off x86-64 Linux);
#   - emit a .mahinatrace and serve it with `mahina viz --no-open`;
#   - fetch the page, the wasm VM and the trace over HTTP;
#   - POST /run (the differential validator's native side) and check the
#     program's output and artifacts come back;
#   - check a cross-site POST /run is refused.
#
#   tools/cli-smoke.sh [--strict] <cli-dir> [platform...]
#
# No platform runs the host's own. A platform this host can't execute is a
# SKIP; --strict turns a SKIP into a failure (CI, on a native runner per
# platform). Needs curl.
set -euo pipefail

strict=
if [[ ${1:-} == --strict ]]; then
    strict=1
    shift
fi
[[ $# -ge 1 ]] || {
    echo "usage: tools/cli-smoke.sh [--strict] <cli-dir> [platform...]" >&2
    exit 2
}
cli=$(cd "$1" && pwd)
shift

host_platform() {
    local arch os
    case $(uname -m) in
        x86_64 | amd64) arch=x86_64 ;;
        aarch64 | arm64) arch=aarch64 ;;
        *) arch=$(uname -m) ;;
    esac
    case $(uname -s) in
        Linux) os=linux ;;
        Darwin) os=macos ;;
        MINGW* | MSYS* | CYGWIN*)
            os=windows
            # Git Bash on Windows on Arm is an emulated x64 build, so uname
            # says x86_64; PROCESSOR_IDENTIFIER is the machine's own.
            if [[ ${PROCESSOR_IDENTIFIER:-} == ARM* ]]; then arch=aarch64; fi
            ;;
        *) os=$(uname -s) ;;
    esac
    echo "$arch-$os"
}

host=$(host_platform)
platforms=("$@")
[[ ${#platforms[@]} -gt 0 ]] || platforms=("$host")

work=$(mktemp -d "${TMPDIR:-/tmp}/cli-smoke.XXXXXX")
server_pid=
# Stop the `mahina viz` started in the background. Under msys (Git Bash) the
# server is a native Windows process, so end it by its Windows pid too.
stop_server() {
    [[ -n $server_pid ]] || return 0
    if [[ -r /proc/$server_pid/winpid ]]; then
        taskkill //F //PID "$(cat "/proc/$server_pid/winpid")" >/dev/null 2>&1 || true
    fi
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
    server_pid=
}
cleanup() {
    stop_server
    rm -rf "$work"
}
trap cleanup EXIT

# Unpack zip $1 into directory $2: unzip where there is one, else Windows'
# own Expand-Archive (Git Bash on the runners may lack unzip).
unpack_zip() {
    if command -v unzip >/dev/null; then
        (cd "$2" && unzip -q "$1")
    else
        powershell -NoProfile -Command \
            "Expand-Archive -LiteralPath '$(cygpath -w "$1")' -DestinationPath '$(cygpath -w "$2")'"
    fi
}

fail() {
    echo "cli-smoke: FAIL $platform: $*" >&2
    if [[ -f $work/viz.log ]]; then
        echo "--- mahina viz output:" >&2
        cat "$work/viz.log" >&2
    fi
    exit 1
}

expect_eq() { # what got want
    [[ $2 == "$3" ]] || fail "$1: got '$2', want '$3'"
}

smoke() {
    local dir=$work/$platform exe
    mkdir -p "$dir"
    case $platform in
        *-windows)
            [[ -f $cli/mahina-$platform.zip ]] || fail "no mahina-$platform.zip in $cli"
            unpack_zip "$cli/mahina-$platform.zip" "$dir"
            exe=$dir/mahina-$platform/mahina.exe
            ;;
        *)
            [[ -f $cli/mahina-$platform.tar.gz ]] || fail "no mahina-$platform.tar.gz in $cli"
            tar -xzf "$cli/mahina-$platform.tar.gz" -C "$dir"
            exe=$dir/mahina-$platform/mahina
            ;;
    esac
    cd "$dir"

    # --version names the commit the archive was built from, and the UI.
    local version
    version=$("$exe" --version | tr -d '\r') || fail "--version exited $?"
    [[ $version == "mahina "* ]] || fail "--version: $version"
    [[ $version == *"commit: $(cat "$cli/LUNE_COMMIT")"* ]] || fail "--version lacks the commit: $version"
    [[ $version == *"web UI (\`mahina viz\`): built in"* ]] || fail "--version says no web UI: $version"

    expect_eq "-e" "$("$exe" -e 'print(1 + 2)' | tr -d '\r')" 3
    cat >loop.mahina <<'EOF'
local s = 0
for i = 1, 100000 do s = s + i end
print(s)
EOF
    expect_eq "script" "$("$exe" loop.mahina | tr -d '\r')" 5000050000
    expect_eq "--jit-native" "$("$exe" --jit-native loop.mahina 2>jit.err | tr -d '\r')" 5000050000
    # Native code is x86-64 Linux only; everywhere else --jit-native warns.
    if [[ $platform == x86_64-linux ]]; then
        [[ ! -s jit.err ]] || fail "--jit-native warned on x86-64 Linux: $(cat jit.err)"
    else
        grep -q 'warning: --jit-native: native code is x86-64 Linux only' jit.err ||
            fail "--jit-native did not warn: $(cat jit.err)"
    fi
    "$exe" viz --help >/dev/null || fail "mahina viz --help exited $?"

    "$exe" --emit-traces t.mahinatrace loop.mahina >/dev/null
    [[ -s t.mahinatrace ]] || fail "--emit-traces wrote no trace"

    "$exe" viz --no-open --port 0 t.mahinatrace >"$work/viz.log" 2>&1 &
    server_pid=$!
    local url= i
    for i in $(seq 1 100); do
        url=$(sed -n 's|^mahina viz: serving on \(http://[^ ]*\) .*|\1|p' "$work/viz.log")
        [[ -n $url ]] && break
        kill -0 "$server_pid" 2>/dev/null || fail "mahina viz exited before serving"
        sleep 0.1
    done
    [[ -n $url ]] || fail "mahina viz never printed its URL"
    local base=${url%%/\?*}
    base=${base%/}
    expect_eq "page URL" "$url" "$base/?src=trace/t.mahinatrace"

    curl -fsS -o page.html "$base/" || fail "GET /"
    grep -qi '<!doctype html' page.html || fail "GET / is not the visualiser page"
    # Every script and stylesheet the page references is served.
    local refs ref
    refs=$(grep -oE '(src|href)="[^"]*"' page.html | sed -E 's/^[a-z]+="(\.?\/)?(.*)"$/\2/')
    [[ -n $refs ]] || fail "the page references no assets"
    for ref in $refs; do
        curl -fsS -o /dev/null "$base/$ref" || fail "GET /$ref (referenced by the page)"
    done
    local ct
    ct=$(curl -fsS -o vm.wasm -w '%{content_type}' "$base/mahina.wasm") || fail "GET /mahina.wasm"
    expect_eq "wasm content-type" "$ct" application/wasm
    expect_eq "wasm magic" "$(head -c 4 vm.wasm | od -An -tx1 | tr -d ' \n')" 0061736d
    curl -fsS -o served.mahinatrace "$base/trace/t.mahinatrace" || fail "GET /trace/t.mahinatrace"
    cmp -s t.mahinatrace served.mahinatrace || fail "the served trace differs from the file"

    local reply origin=${base}
    reply=$(curl -fsS -H 'Content-Type: application/json' -H "Origin: $origin" \
        --data '{"source":"local s = 0\nfor i = 1, 100000 do s = s + i end\nprint(s)\n","args":[]}' \
        "$base/run") || fail "POST /run"
    [[ $reply == *'"status":0,'* ]] || fail "POST /run status: $reply"
    [[ $reply == *'"stdout":"5000050000\n"'* ]] || fail "POST /run stdout: $reply"
    [[ $reply == *'"keyframe":"'[A-Za-z0-9+/]* ]] || fail "POST /run returned no keyframe: $reply"
    [[ $reply == *'"trace":"'[A-Za-z0-9+/]* ]] || fail "POST /run returned no trace: $reply"

    local code
    code=$(curl -sS -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' \
        -H 'Origin: http://evil.example' --data '{"source":"print(1)"}' "$base/run")
    expect_eq "cross-site POST /run" "$code" 403

    stop_server
    rm -f "$work/viz.log"
    cd "$work"
    echo "cli-smoke: PASS $platform"
}

skips=0
for platform in "${platforms[@]}"; do
    if [[ $platform != "$host" ]]; then
        echo "cli-smoke: SKIP $platform (this host is $host)"
        skips=$((skips + 1))
        continue
    fi
    smoke
done
if [[ -n $strict && $skips -gt 0 ]]; then
    echo "cli-smoke: $skips platform(s) skipped under --strict" >&2
    exit 1
fi
