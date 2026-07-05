#!/bin/sh
# Build, verify, and stage into the glinet-tailscale-feed working copy.
#
# The feed's Pages site is assembled by its CI (tools/assemble_site.sh), which
# seeds every arch dir from gui/*_all.ipk - so publishing this arch-all package
# means: drop the ipk into gui/, commit, push, and let build-feed.yml deploy
# (daily cron, or `gh workflow run build-feed.yml` to publish immediately).
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(dirname "$HERE")
FEED=${FEED_DIR:-"$REPO/../glinet-tailscale"}

[ -d "$FEED/gui" ] || { echo "feed checkout not found at $FEED (set FEED_DIR)"; exit 1; }

"$REPO/build.py"
VER=$(sed -n 's/^Version: //p' "$REPO/gl-sdk4-tailscale-mullvad/control")
# drop any older revision first: assemble_site.sh copies gui/*_all.ipk wholesale,
# and two revisions of the same package would both land in the served feed.
# Copy ONLY the current control version - out/ accumulates every version ever
# built, and a glob copy resurrects superseded ipks into the feed.
rm -f "$FEED"/gui/gl-sdk4-tailscale-mullvad_*.ipk
cp "$REPO/out/gl-sdk4-tailscale-mullvad_${VER}_all.ipk" "$FEED/gui/"
echo "staged into $FEED/gui:"
ls -l "$FEED"/gui/gl-sdk4-tailscale-mullvad_*.ipk
echo "now commit + push the feed repo; CI publishes on the next build-feed run"
