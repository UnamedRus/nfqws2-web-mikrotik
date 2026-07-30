#!/bin/sh
set -e

# C1 — Seed /etc/nfqws2 from baked defaults at /usr/share/nfqws2 (idempotent; never clobbers user edits).
DEFAULTS=/usr/share/nfqws2
mkdir -p /etc/nfqws2/lists /etc/nfqws2/lua /etc/nfqws2/blobs
# seed main config (with iface autodetect) only if absent
if [ ! -f /etc/nfqws2/nfqws2.conf ]; then
  cp "$DEFAULTS/nfqws2.conf.default" /etc/nfqws2/nfqws2.conf
  DEF_IFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
  [ -n "$DEF_IFACE" ] && sed -i "s#^ISP_INTERFACE=.*#ISP_INTERFACE=\"$DEF_IFACE\"#" /etc/nfqws2/nfqws2.conf
fi
# populate immutable assets if the target dir is empty (empty-volume case); don't overwrite user files
[ -z "$(ls -A /etc/nfqws2/lua 2>/dev/null)" ]   && cp "$DEFAULTS"/lua/*   /etc/nfqws2/lua/   2>/dev/null || true
[ -z "$(ls -A /etc/nfqws2/blobs 2>/dev/null)" ] && cp "$DEFAULTS"/blobs/* /etc/nfqws2/blobs/ 2>/dev/null || true
[ -z "$(ls -A /etc/nfqws2/lists 2>/dev/null)" ] && cp "$DEFAULTS"/lists/* /etc/nfqws2/lists/ 2>/dev/null || true

# I1 — Ensure nfqws2 (nobody) can write to logs and lists.
touch /var/log/nfqws2.log /var/log/nfqws2-debug.log 2>/dev/null || true
chown -R nobody /etc/nfqws2/lists /var/log/nfqws2.log /var/log/nfqws2-debug.log 2>/dev/null || true

# Gateway role: enable IPv4/IPv6 forwarding so routed client traffic passes through the container.
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1 || true

# Gateway role: masquerade routed client traffic outbound (native nft), as wiktorbgu does.
nft add table ip nat 2>/dev/null || true
nft add chain ip nat postrouting '{ type nat hook postrouting priority srcnat; }' 2>/dev/null || true
nft add rule ip nat postrouting masquerade 2>/dev/null || true

# M2 — IPv6 masquerade when IPV6_ENABLED=1.
nft add table ip6 nat 2>/dev/null || true
nft add chain ip6 nat postrouting '{ type nat hook postrouting priority srcnat; }' 2>/dev/null || true
nft add rule ip6 nat postrouting masquerade 2>/dev/null || true

# Web UI.
lighttpd -f /etc/lighttpd/lighttpd.conf

if [ $# -gt 0 ]; then
  exec "$@"
fi

# M1 — Print version (fixed: use literal path, no empty fallback needed).
echo "NFQWS2 $(/usr/bin/nfqws2 --version 2>&1 | head -n1)"
/etc/init.d/nfqws2-keenetic start || true
exec sleep infinity
