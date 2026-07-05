#!/bin/sh
# Full local test suite. Needs: lua (5.1+), node, python3, gzip.
#   test/run-tests.sh <captured-tailscale-status.json>
# The capture comes from any tailnet device with the Mullvad add-on visible:
#   tailscale status --json > status.json
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(dirname "$HERE")
STATUS=${1:?usage: run-tests.sh <tailscale-status.json>}

echo "== 1. build (includes anchor + node --check verification) =="
"$REPO/build.py"

echo "== 2. patch-view.lua end-to-end in a fake root =="
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/www/views" "$T/usr/share/tailscale-mullvad"
gzip -c "$HERE/view-reference.js" > "$T/www/views/gl-sdk4-ui-tailscaleview.common.js.gz"
cp "$REPO"/gl-sdk4-tailscale-mullvad/data/usr/share/tailscale-mullvad/*.js "$T/usr/share/tailscale-mullvad/"
PATCHER="$REPO/gl-sdk4-tailscale-mullvad/data/usr/libexec/tailscale-mullvad/patch-view.lua"
ORIG_SUM=$(gunzip -c "$T/www/views/gl-sdk4-ui-tailscaleview.common.js.gz" | sha256sum | cut -d' ' -f1)

TSMV_ROOT="$T" lua "$PATCHER" apply
gunzip -c "$T/www/views/gl-sdk4-ui-tailscaleview.common.js.gz" > "$T/patched.js"
grep -q 'tsmullvad:v1' "$T/patched.js" || { echo "FAIL: marker missing after apply"; exit 1; }
node --check "$T/patched.js" || { echo "FAIL: patched bundle does not parse"; exit 1; }
[ -f "$T/www/views/gl-sdk4-ui-tailscaleview.common.js.gz.tsmullvad-orig" ] || { echo "FAIL: no backup"; exit 1; }
echo "apply: marker present, bundle parses, backup created"

TSMV_ROOT="$T" lua "$PATCHER" apply | grep -q "already applied" || { echo "FAIL: not idempotent"; exit 1; }
echo "apply twice: idempotent"

TSMV_ROOT="$T" lua "$PATCHER" remove
RESTORED_SUM=$(gunzip -c "$T/www/views/gl-sdk4-ui-tailscaleview.common.js.gz" | sha256sum | cut -d' ' -f1)
[ "$ORIG_SUM" = "$RESTORED_SUM" ] || { echo "FAIL: restore is not byte-identical"; exit 1; }
[ ! -f "$T/www/views/gl-sdk4-ui-tailscaleview.common.js.gz.tsmullvad-orig" ] || { echo "FAIL: backup left behind"; exit 1; }
echo "remove: original restored byte-identical"

echo "== 3. rpc/mullvad against captured tailnet data (differential vs python) =="
python3 - "$STATUS" > "$T/expected.txt" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
groups = {}
for p in d.get("Peer", {}).values():
    loc = p.get("Location") or {}
    if not (p.get("ExitNodeOption") is True
            and ".mullvad.ts.net" in (p.get("DNSName") or "")
            and p.get("TailscaleIPs")
            and loc.get("CountryCode") and loc.get("City")):
        continue
    key = (loc["CountryCode"], loc.get("Country") or loc["CountryCode"], loc["City"])
    cand = (p["TailscaleIPs"][0], p.get("HostName") or "", loc.get("Priority") or 0,
            p.get("Online") is True)
    g = groups.setdefault(key, {"n": 0, "best": None})
    g["n"] += 1
    def better(a, b):
        if a[3] != b[3]: return a[3]
        if a[2] != b[2]: return a[2] > b[2]
        return a[1] < b[1]
    if g["best"] is None or better(cand, g["best"]):
        g["best"] = cand
for (cc, country, city), g in sorted(groups.items()):
    ip, _, _, online = g["best"]
    print(f"{cc}|{country}|{city}|{g['n']}|{ip}|{'true' if online else 'false'}")
EOF
lua "$HERE/rpc-test.lua" "$STATUS" "$T/expected.txt"

echo "== all tests passed =="
