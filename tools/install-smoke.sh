#!/usr/bin/env bash
# Smoke-check install.sh against CLI archives (tools/mahina-cli.sh output)
# without publishing a release: lay them out the way the release job names
# them, serve that over loopback, and run the installer at it.
#
#   tools/install-smoke.sh <cli-dir>
#
# Checks, on this host's platform (Linux or macOS):
#   - the latest-release lookup (a `releases/latest` redirect) and a pinned
#     MAHINA_VERSION both install a `mahina` whose --version names the commit
#     the archives were built from, and which runs a script;
#   - installing again replaces the binary in place;
#   - a SHA256SUMS that doesn't match the archive makes the install fail and
#     leaves the installed binary alone.
# Needs python3 (the server) and curl.
set -euo pipefail

[[ $# -eq 1 ]] || {
    echo "usage: tools/install-smoke.sh <cli-dir>" >&2
    exit 2
}
root=$(cd "$(dirname "$0")/.." && pwd)
cli=$(cd "$1" && pwd)
version=v0.0.0-smoke

work=$(mktemp -d "${TMPDIR:-/tmp}/install-smoke.XXXXXX")
server_pid=
cleanup() {
    [[ -z $server_pid ]] || kill "$server_pid" 2>/dev/null || true
    rm -rf "$work"
}
trap cleanup EXIT

fail() {
    echo "install-smoke: FAIL: $*" >&2
    exit 1
}

# The release job's layout: download/<tag>/mahina-<tag>-<platform>.<ext>
# plus mahina-<tag>-SHA256SUMS over them.
rel=$work/srv/download/$version
mkdir -p "$rel"
for f in "$cli"/mahina-*; do
    cp "$f" "$rel/mahina-$version-${f##*/mahina-}"
done
(cd "$rel" && sha256sum mahina-* >"mahina-$version-SHA256SUMS" 2>/dev/null ||
    shasum -a 256 mahina-* >"mahina-$version-SHA256SUMS")

# A static server that also answers /latest the way GitHub does: a redirect
# to /tag/<tag>, whose page the installer never needs.
python3 - "$work/srv" "$version" >"$work/server.log" 2>&1 <<'EOF' &
import http.server, os, sys
root, version = sys.argv[1], sys.argv[2]
os.chdir(root)
class H(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/latest":
            self.send_response(302)
            self.send_header("Location", f"/tag/{version}")
            self.end_headers()
        elif self.path.startswith("/tag/"):
            self.send_response(200)
            self.end_headers()
        else:
            super().do_GET()
    do_HEAD = do_GET
s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
print(f"port {s.server_address[1]}", flush=True)
s.serve_forever()
EOF
server_pid=$!
port=
for _ in $(seq 1 100); do
    port=$(sed -n 's/^port //p' "$work/server.log")
    [[ -n $port ]] && break
    sleep 0.1
done
[[ -n $port ]] || fail "the server didn't start: $(cat "$work/server.log")"
base=http://127.0.0.1:$port
commit=$(cat "$cli/LUNE_COMMIT")
bin=$work/bin

check_installed() {
    local v
    v=$("$bin/mahina" --version) || fail "$1: the installed mahina doesn't run"
    [[ $v == *"commit: $commit"* ]] || fail "$1: installed the wrong build: $v"
    [[ $("$bin/mahina" -e 'print(6 * 7)') == 42 ]] || fail "$1: the installed mahina can't run a chunk"
}

# Latest release, through the redirect.
MAHINA_BASE_URL=$base MAHINA_INSTALL_DIR=$bin sh "$root/install.sh" >"$work/out" 2>&1 ||
    fail "latest install: $(cat "$work/out")"
grep -q "installing mahina $version for" "$work/out" || fail "latest install picked: $(cat "$work/out")"
check_installed "latest install"

# Pinned, over the existing install.
MAHINA_BASE_URL=$base MAHINA_VERSION=$version MAHINA_INSTALL_DIR=$bin sh "$root/install.sh" >"$work/out" 2>&1 ||
    fail "pinned reinstall: $(cat "$work/out")"
check_installed "pinned reinstall"

# A tampered checksum: refused, and the install stays as it was.
before=$(cksum <"$bin/mahina")
cp "$rel/mahina-$version-SHA256SUMS" "$work/sums"
awk '{ $1 = "0000000000000000000000000000000000000000000000000000000000000000"; print }' \
    "$work/sums" >"$rel/mahina-$version-SHA256SUMS"
if MAHINA_BASE_URL=$base MAHINA_VERSION=$version MAHINA_INSTALL_DIR=$bin sh "$root/install.sh" >"$work/out" 2>&1; then
    fail "a bad checksum installed anyway: $(cat "$work/out")"
fi
grep -q "sha256 is" "$work/out" || fail "a bad checksum failed for another reason: $(cat "$work/out")"
[[ $(cksum <"$bin/mahina") == "$before" ]] || fail "a refused install changed the installed binary"

echo "install-smoke: PASS ($(uname -s) $(uname -m))"
