#!/bin/sh
set -e

# Seed config on first run (so a mounted /etc/nfqws2 volume persists edits).
if [ ! -f /etc/nfqws2/nfqws2.conf ]; then
  cp /etc/nfqws2/nfqws2.conf.default /etc/nfqws2/nfqws2.conf
  # Bind nfqws2 to the container's default-route interface (the RouterOS veth).
  DEF_IFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
  if [ -n "$DEF_IFACE" ]; then
    sed -i "s#^ISP_INTERFACE=.*#ISP_INTERFACE=\"$DEF_IFACE\"#" /etc/nfqws2/nfqws2.conf
  fi
fi

# Gateway role: masquerade routed client traffic outbound (native nft), as wiktorbgu does.
nft add table ip nat 2>/dev/null || true
nft add chain ip nat postrouting '{ type nat hook postrouting priority srcnat; }' 2>/dev/null || true
nft add rule ip nat postrouting masquerade 2>/dev/null || true

# Web UI.
lighttpd -f /etc/lighttpd/lighttpd.conf

if [ $# -gt 0 ]; then
  exec "$@"
fi

echo "NFQWS2 $($NFQWS_BIN --version 2>&1 | head -n1)" 2>/dev/null || echo "NFQWS2 $(/usr/bin/nfqws2 --version 2>&1 | head -n1)"
/etc/init.d/nfqws2-keenetic start || true
exec sleep infinity
