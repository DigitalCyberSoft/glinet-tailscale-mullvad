#!/bin/sh
# Build, verify, and publish into the opkg feed working copy (../glinet-tailscale).
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(dirname "$HERE")
FEED=${FEED_DIR:-"$REPO/../glinet-tailscale"}

[ -d "$FEED/all" ] || { echo "feed dir $FEED/all not found (set FEED_DIR)"; exit 1; }

"$REPO/build.py"
cp "$REPO"/out/*.ipk "$FEED/all/"
"$HERE/mkindex.py" "$FEED/all"
echo "published to $FEED/all:"
ls -l "$FEED/all"
