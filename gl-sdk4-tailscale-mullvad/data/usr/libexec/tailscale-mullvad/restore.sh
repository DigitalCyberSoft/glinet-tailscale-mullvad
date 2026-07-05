#!/bin/sh
# Reinstall the Mullvad picker after a firmware upgrade.
#
# sysupgrade replaces the rootfs, wiping everything opkg installed under /usr
# and the patched view under /www. postinst stashes a copy of this script and
# the package payload in /etc/tailscale-mullvad/ (preserved via keep.d +
# /etc/sysupgrade.conf) and hooks it from /etc/rc.local, so on first boot after
# an upgrade the picker puts itself back. No-op while the package is intact.

P=/etc/tailscale-mullvad
VIEW=/www/views/gl-sdk4-ui-tailscaleview.common.js.gz
LOG=/tmp/tsmullvad-restore.log

[ -f "$P/payload/rpc-mullvad" ] || exit 0

# intact = rpc handler present AND the served bundle carries our marker
if [ -f /usr/lib/oui-httpd/rpc/mullvad ] \
   && gunzip -c "$VIEW" 2>/dev/null | head -c 32 | grep -q "tsmullvad:"; then
    exit 0
fi

exec >> "$LOG" 2>&1
echo "=== $(date) tailscale-mullvad restore: package files missing, restoring"

if [ ! -f "$VIEW" ]; then
    echo "no Tailscale panel view bundle on this firmware; not restoring"
    exit 1
fi

mkdir -p /usr/lib/oui-httpd/rpc /usr/libexec/tailscale-mullvad /usr/share/tailscale-mullvad
cp "$P/payload/rpc-mullvad"     /usr/lib/oui-httpd/rpc/mullvad
cp "$P/payload/patch-view.lua"  /usr/libexec/tailscale-mullvad/patch-view.lua
cp "$P/payload/render.js"       /usr/share/tailscale-mullvad/render.js
cp "$P/payload/block.js"        /usr/share/tailscale-mullvad/block.js
cp "$P/restore.sh"              /usr/libexec/tailscale-mullvad/restore.sh
chmod 755 /usr/lib/oui-httpd/rpc/mullvad /usr/libexec/tailscale-mullvad/patch-view.lua \
          /usr/libexec/tailscale-mullvad/restore.sh

# fails closed if the new firmware ships a bundle whose anchors don't match;
# the panel stays stock and the reason lands in $LOG
lua /usr/libexec/tailscale-mullvad/patch-view.lua apply || exit 1

# rc.local runs after the nginx initscript, but guard anyway: if nginx is not
# up yet there is nothing to reload and the workers load the handler on start
if [ -f /var/run/nginx.pid ] || pgrep nginx >/dev/null 2>&1; then
    nginx -s reload || echo "nginx reload failed; restart nginx manually"
fi

echo "restore complete (note: opkg does not know about these files until you"
echo "reinstall gl-sdk4-tailscale-mullvad from the feed; functionality is live)"
