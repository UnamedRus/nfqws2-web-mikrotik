# nfqws2-mikrotik: bundle web UI + native-nft engine + GHCR CI — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild the container so one multi-arch image runs `nfqws2` (keenetic layout, native nftables) as a MikroTik veth gateway AND serves the `nfqws-keenetic-web` PHP UI on port 90, and add CI that builds+pushes it to GHCR.

**Architecture:** Multi-stage Dockerfile: a `$BUILDPLATFORM` node stage builds the React UI once (arch-independent); a per-arch `fetch` stage pulls the static `nfqws2` binary + lua from `bol-van/zapret2` and the config/lists/blobs from `nfqws2-keenetic`; the final Alpine stage installs lighttpd+php-cgi+nftables and lays everything out at OpenWRT-style paths (`ROOT_DIR=''`). A hand-written init script drives nfqws2 with native nft NFQUEUE rules; the entrypoint sets up the gateway masquerade and starts both services.

**Tech Stack:** Docker Buildx (multi-arch), Alpine, lighttpd + php83-cgi, nftables, POSIX sh, React/Vite (yarn 4), GitHub Actions.

## Global Constraints

- Target arches only: `linux/arm64`, `linux/amd64`.
- Firewall is **native nftables** (`nft`). No iptables rules authored (the `iptables` pkg may be present for compat but is unused by our scripts).
- Layout is OpenWRT-style, `ROOT_DIR=''`: binary `/usr/bin/nfqws2`; config `/etc/nfqws2/nfqws2.conf`; lists `/etc/nfqws2/lists`; lua `/etc/nfqws2/lua`; blobs `/etc/nfqws2/blobs`; logs `/var/log/nfqws2.log`; service `/etc/init.d/nfqws2-keenetic`.
- The service `status` action MUST print a line containing the substring `is running` when up (the web UI greps for it).
- Pinned versions (build ARGs, overridable): `ZAPRET2_VERSION=1.0.3`, `NFQWS2_KEENETIC_VERSION=1.2.4`.
- All `/opt/` path references in fetched config are rewritten to `/` (`sed 's#/opt/#/#g'`).
- Web UI is nfqws2-only; no `V=`/`V=2` engine switch. Keenetic router policy-mark / ndm logic is dropped.
- GHCR image name derives from `github.repository` at CI time (no hardcoded owner).

---

### Task 1: Add nfqws-keenetic-web as a git submodule

**Files:**
- Create: `.gitmodules`
- Create: `nfqws-keenetic-web/` (submodule)

- [ ] **Step 1: Add the submodule pinned to the current release tag**

```bash
git submodule add https://github.com/nfqws/nfqws-keenetic-web.git nfqws-keenetic-web
cd nfqws-keenetic-web && git fetch --tags && git checkout v3.0.23 && cd ..
git add .gitmodules nfqws-keenetic-web
```

- [ ] **Step 2: Verify the submodule is pinned and the build inputs exist**

Run:
```bash
git submodule status
test -f nfqws-keenetic-web/web/package.json && \
test -f nfqws-keenetic-web/web/public/index.php && \
test -f nfqws-keenetic-web/etc/lighttpd/conf.d/openwrt.conf && \
test -f nfqws-keenetic-web/etc/nfqws_web.conf && \
test -f nfqws-keenetic-web/VERSION && echo OK
```
Expected: `git submodule status` shows a commit prefixed with `+`/space at `nfqws-keenetic-web (v3.0.23)`, and `OK` prints.

- [ ] **Step 3: Commit**

```bash
git commit -m "build: vendor nfqws-keenetic-web as submodule (v3.0.23)"
```

---

### Task 2: Write the native-nft init script

**Files:**
- Create: `rootfs/etc/init.d/nfqws2-keenetic`

**Interfaces:**
- Consumes: `/etc/nfqws2/nfqws2.conf` variables (`ISP_INTERFACE`, `NFQWS_BASE_ARGS`, `NFQWS_ARGS`, `NFQWS_ARGS_QUIC`, `NFQWS_ARGS_UDP`, `NFQWS_EXTRA_ARGS`, `NFQWS_ARGS_IPSET`, `NFQWS_ARGS_CUSTOM`, `TCP_PORTS`, `UDP_PORTS`, `NFQUEUE_NUM`, `USER`, `IPV6_ENABLED`, `LOG_LEVEL`, `LOG_DEBUG_PATH`).
- Produces: an executable `/etc/init.d/nfqws2-keenetic` accepting `start|stop|restart|reload|status`; nft table `inet nfqws2`; pidfile `/var/run/nfqws2.pid`.

- [ ] **Step 1: Write the script**

Create `rootfs/etc/init.d/nfqws2-keenetic`:

```sh
#!/bin/sh
# nfqws2 service — native nftables, container-adapted.
# Firewall rules are a 1:1 nft translation of nfqws2-keenetic's NFQUEUE ruleset.
# _startup_args is derived verbatim from nfqws2-keenetic (engine-agnostic).

CONFFILE=/etc/nfqws2/nfqws2.conf
NFQWS_BIN=/usr/bin/nfqws2
PIDFILE=/var/run/nfqws2.pid
NFT_TABLE=nfqws2
REINJECT_MARK=0x40000000   # mark nfqws2 sets on packets it already handled
MAX_PKT=15

[ -f "$CONFFILE" ] && . "$CONFFILE"

is_running() {
  [ -f "$PIDFILE" ] || return 1
  PID_SAVED=$(cat "$PIDFILE" 2>/dev/null)
  [ -n "$PID_SAVED" ] || return 1
  kill -0 "$PID_SAVED" 2>/dev/null || return 1
  return 0
}

status_service() {
  if is_running; then
    echo 'Service NFQWS2 is running'
  else
    echo 'Service NFQWS2 is stopped'
  fi
}

reload_service() {
  if ! is_running; then
    echo 'Service NFQWS2 is not running' >&2
    return 1
  fi
  echo 'Reloading NFQWS2 service...'
  kill -HUP "$(cat "$PIDFILE")"
}

_ports_nft() { echo "$1" | sed 's/:/-/g'; }   # keenetic uses 590:600, nft wants 590-600

_startup_args() {
  args="--user=$USER --qnum=$NFQUEUE_NUM $NFQWS_BASE_ARGS"

  iface_count=$(echo $ISP_INTERFACE | wc -w)
  if [ "$iface_count" -gt 1 ]; then
    args="$args --bind-fix4"
    [ -n "$IPV6_ENABLED" ] && [ "$IPV6_ENABLED" -ne 0 ] && args="$args --bind-fix6"
  fi

  if [ "${LOG_LEVEL:-0}" -eq 1 ]; then
    if [ -n "$LOG_DEBUG_PATH" ]; then
      args="--debug=$LOG_DEBUG_PATH $args"
    else
      args="--debug=syslog $args"
    fi
  fi

  [ -n "$NFQWS_ARGS_CUSTOM" ] && args="$args $NFQWS_ARGS_CUSTOM --new"
  [ -n "$NFQWS_ARGS_UDP" ] && args="$args $NFQWS_ARGS_UDP --new"

  if [ -n "$NFQWS_ARGS_QUIC" ]; then
    [ -n "$NFQWS_ARGS_IPSET" ] && args="$args $NFQWS_ARGS_QUIC $NFQWS_ARGS_IPSET --ipset-ip=0.0.0.0 --new"
    args="$args $NFQWS_ARGS_QUIC $NFQWS_EXTRA_ARGS --new"
  fi

  [ -n "$NFQWS_ARGS_IPSET" ] && args="$args $NFQWS_ARGS $NFQWS_ARGS_IPSET --ipset-ip=0.0.0.0 --new"
  args="$args $NFQWS_ARGS $NFQWS_EXTRA_ARGS"

  echo "$args"
}

_fw_start() {
  N="$NFQUEUE_NUM"
  TCP=$(_ports_nft "$TCP_PORTS")
  UDP=$(_ports_nft "$UDP_PORTS")

  POST=""
  PRE=""
  for IFACE in $ISP_INTERFACE; do
    POST="$POST
      oifname \"$IFACE\" meta mark and $REINJECT_MARK != $REINJECT_MARK udp dport { $UDP } ct original packets 1-$MAX_PKT queue num $N bypass
      oifname \"$IFACE\" meta mark and $REINJECT_MARK != $REINJECT_MARK tcp dport { $TCP } ct original packets 1-$MAX_PKT queue num $N bypass
      oifname \"$IFACE\" meta mark and $REINJECT_MARK != $REINJECT_MARK tcp dport { $TCP } tcp flags fin queue num $N bypass
      oifname \"$IFACE\" meta mark and $REINJECT_MARK != $REINJECT_MARK tcp dport { $TCP } tcp flags rst queue num $N bypass"
    PRE="$PRE
      iifname \"$IFACE\" meta mark and $REINJECT_MARK == $REINJECT_MARK return
      iifname \"$IFACE\" meta mark and $REINJECT_MARK != $REINJECT_MARK udp sport { $UDP } ct reply packets 1-$MAX_PKT queue num $N bypass
      iifname \"$IFACE\" meta mark and $REINJECT_MARK != $REINJECT_MARK tcp sport { $TCP } ct reply packets 1-$MAX_PKT queue num $N bypass
      iifname \"$IFACE\" meta mark and $REINJECT_MARK != $REINJECT_MARK tcp sport { $TCP } tcp flags syn,ack queue num $N bypass
      iifname \"$IFACE\" meta mark and $REINJECT_MARK != $REINJECT_MARK tcp sport { $TCP } tcp flags fin queue num $N bypass
      iifname \"$IFACE\" meta mark and $REINJECT_MARK != $REINJECT_MARK tcp sport { $TCP } tcp flags rst queue num $N bypass"
  done

  nft delete table inet $NFT_TABLE 2>/dev/null || true
  nft -f - <<EOF
table inet $NFT_TABLE {
  chain post {
    type filter hook postrouting priority mangle; policy accept;$POST
  }
  chain pre {
    type filter hook prerouting priority mangle; policy accept;$PRE
  }
}
EOF
}

_fw_stop() {
  nft delete table inet $NFT_TABLE 2>/dev/null || true
}

system_config() {
  sysctl -w net.netfilter.nf_conntrack_checksum=0 >/dev/null 2>&1 || true
  sysctl -w net.netfilter.nf_conntrack_tcp_be_liberal=1 >/dev/null 2>&1 || true
}

start_service() {
  if is_running; then
    echo 'Service NFQWS2 is already running' >&2
    return 0
  fi
  modprobe -a -q nfnetlink_queue nf_conntrack >/dev/null 2>&1 || true
  system_config
  _fw_start
  # shellcheck disable=SC2046
  $NFQWS_BIN --daemon --pidfile="$PIDFILE" $(_startup_args)
}

stop_service() {
  _fw_stop
  if is_running; then
    kill "$(cat "$PIDFILE")" 2>/dev/null
  fi
  rm -f "$PIDFILE"
}

case "$1" in
  start)   start_service ;;
  stop)    stop_service ;;
  restart) stop_service; start_service ;;
  reload)  reload_service ;;
  status)  status_service ;;
  *) echo "Usage: $0 {start|stop|restart|reload|status}" >&2; exit 1 ;;
esac
```

- [ ] **Step 2: Lint the script**

Run: `shellcheck -s sh rootfs/etc/init.d/nfqws2-keenetic`
Expected: no errors (the `SC2046` on the daemon line is annotated/disabled; word-splitting there is intentional).

- [ ] **Step 3: Verify the generated nft ruleset parses**

This checks nft syntax without needing the real interface/kernel queue. Run in a privileged throwaway container (nft check needs a netns):
```bash
docker run --rm --privileged alpine sh -c '
  apk add --no-cache nftables >/dev/null
  N=300; TCP="80,443"; UDP="443,590-600"
  nft -c -f - <<EOF
table inet nfqws2 {
  chain post {
    type filter hook postrouting priority mangle; policy accept;
    oifname "eth0" meta mark and 0x40000000 != 0x40000000 udp dport { $UDP } ct original packets 1-15 queue num $N bypass
    oifname "eth0" meta mark and 0x40000000 != 0x40000000 tcp dport { $TCP } ct original packets 1-15 queue num $N bypass
    oifname "eth0" meta mark and 0x40000000 != 0x40000000 tcp dport { $TCP } tcp flags fin queue num $N bypass
  }
  chain pre {
    type filter hook prerouting priority mangle; policy accept;
    iifname "eth0" meta mark and 0x40000000 == 0x40000000 return
    iifname "eth0" meta mark and 0x40000000 != 0x40000000 tcp sport { $TCP } tcp flags syn,ack queue num $N bypass
  }
}
EOF
  echo "nft-syntax-ok"'
```
Expected: prints `nft-syntax-ok` with no parse error. **If `ct original packets`/`ct reply packets` is rejected by this nft version, adjust to the accepted spelling (`ct original pkts` / `ct reply pkts`) and re-run — this is the one syntax detail to confirm against the pinned Alpine nftables.**

- [ ] **Step 4: Commit**

```bash
git add rootfs/etc/init.d/nfqws2-keenetic
git commit -m "feat: native-nft nfqws2 init script"
```

---

### Task 3: Write the base lighttpd config

**Files:**
- Create: `rootfs/etc/lighttpd/lighttpd.conf`

**Interfaces:**
- Consumes: the UI's `conf.d/80-nfqws.conf` (installed in Task 5) which sets the `:90` socket handler, php-cgi assignment, rewrite `^/(.*)`→`/nfqws/$1`, and 404→`/nfqws/index.html`.
- Produces: a base config that loads the needed modules, serves docroot `/www`, and includes `conf.d/*`.

- [ ] **Step 1: Write the config**

Create `rootfs/etc/lighttpd/lighttpd.conf`:

```lighttpd
server.modules = (
  "mod_cgi",
  "mod_setenv",
  "mod_rewrite",
  "mod_redirect",
)

server.document-root = "/www"
server.errorlog      = "/dev/stderr"
server.pid-file      = "/run/lighttpd.pid"
server.port          = 8088

index-file.names = ( "index.html" )

mimetype.assign = (
  ".html"  => "text/html",
  ".js"    => "application/javascript",
  ".css"   => "text/css",
  ".json"  => "application/json",
  ".svg"   => "image/svg+xml",
  ".png"   => "image/png",
  ".ico"   => "image/x-icon",
  ".woff2" => "font/woff2",
  ".webmanifest" => "application/manifest+json",
)

include "conf.d/80-nfqws.conf"
```

- [ ] **Step 2: Verify it references the include the UI ships**

Run: `grep -q 'include "conf.d/80-nfqws.conf"' rootfs/etc/lighttpd/lighttpd.conf && echo OK`
Expected: `OK`. (Full lighttpd validation happens in Task 5's container smoke test.)

- [ ] **Step 3: Commit**

```bash
git add rootfs/etc/lighttpd/lighttpd.conf
git commit -m "feat: base lighttpd config (docroot /www, load mods, include conf.d)"
```

---

### Task 4: Write the entrypoint

**Files:**
- Create: `entrypoint.sh`

**Interfaces:**
- Consumes: `/etc/nfqws2/nfqws2.conf.default` (baked in Task 5), `/etc/init.d/nfqws2-keenetic` (Task 2), `/etc/lighttpd/lighttpd.conf` (Task 3).
- Produces: `/entrypoint.sh` — seeds config, auto-detects `ISP_INTERFACE`, sets up gateway masquerade, starts lighttpd + nfqws2.

- [ ] **Step 1: Write the entrypoint**

Create `entrypoint.sh`:

```sh
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
```

- [ ] **Step 2: Lint**

Run: `shellcheck -s sh entrypoint.sh`
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add entrypoint.sh
git commit -m "feat: entrypoint — seed config, autodetect iface, masquerade, start services"
```

---

### Task 5: Write the Dockerfile and remove old build files

**Files:**
- Create: `Dockerfile`
- Delete: `Dockerfile_latest_autoinstall`, `entrypoint_latest_autoinstall.sh`
- Modify (replace): the current `Dockerfile`, `entrypoint.sh` are superseded (the old `entrypoint.sh` was already replaced in Task 4).

**Interfaces:**
- Consumes: submodule (Task 1), `rootfs/` (Tasks 2–3), `entrypoint.sh` (Task 4).
- Produces: an image tagged `nfqws2-mikrotik:test` with the full layout.

- [ ] **Step 1: Write the Dockerfile**

Create `Dockerfile` (overwrite the existing one):

```dockerfile
# syntax=docker/dockerfile:1
ARG ZAPRET2_VERSION=1.0.3
ARG NFQWS2_KEENETIC_VERSION=1.2.4

# --- Build the React UI once, on the native builder arch (output is arch-independent) ---
FROM --platform=$BUILDPLATFORM node:20-alpine AS webbuild
WORKDIR /src
COPY nfqws-keenetic-web/ ./
RUN corepack enable && \
    cd web && \
    yarn install --immutable && \
    yarn openapi && \
    yarn build
# result: /src/web/dist  (SPA + index.php)

# --- Fetch static nfqws2 binary + lua (bol-van/zapret2) and config/lists/blobs (nfqws2-keenetic) ---
FROM alpine AS fetch
ARG ZAPRET2_VERSION
ARG NFQWS2_KEENETIC_VERSION
ARG TARGETARCH
RUN apk add --no-cache curl tar gzip
WORKDIR /tmp/build
RUN set -eux; \
    case "$TARGETARCH" in \
      amd64) ZDIR=linux-x86_64 ;; \
      arm64) ZDIR=linux-arm64 ;; \
      *) echo "unsupported arch: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/bol-van/zapret2/releases/download/v${ZAPRET2_VERSION}/zapret2-v${ZAPRET2_VERSION}-openwrt-embedded.tar.gz" -o z.tgz; \
    tar xzf z.tgz; \
    Z="zapret2-v${ZAPRET2_VERSION}"; \
    mkdir -p /out/usr/bin /out/etc/nfqws2/lua; \
    cp "$Z/binaries/$ZDIR/nfqws2" /out/usr/bin/nfqws2; \
    chmod +x /out/usr/bin/nfqws2; \
    cp "$Z"/lua/*.lua.gz /out/etc/nfqws2/lua/; \
    for f in /out/etc/nfqws2/lua/*.lua.gz; do gunzip -f "$f"; done; \
    curl -fsSL "https://github.com/nfqws/nfqws2-keenetic/archive/refs/tags/v${NFQWS2_KEENETIC_VERSION}.tar.gz" -o kt.tgz; \
    tar xzf kt.tgz; \
    K="nfqws2-keenetic-${NFQWS2_KEENETIC_VERSION}"; \
    cp -r "$K/etc/nfqws2/lists" /out/etc/nfqws2/lists; \
    cp -r "$K/etc/nfqws2/blobs" /out/etc/nfqws2/blobs; \
    sed 's#/opt/#/#g' "$K/etc/nfqws2/nfqws2.conf" > /out/etc/nfqws2/nfqws2.conf.default

# --- Final runtime image ---
FROM alpine
RUN apk add --no-cache \
      nftables iproute2 \
      lighttpd lighttpd-mod-cgi lighttpd-mod-setenv lighttpd-mod-rewrite lighttpd-mod-redirect \
      php83-cgi php83-session php83-curl php83-ctype php83-openssl \
      netcat-openbsd curl tzdata ca-certificates tini && \
    ln -sf php-cgi83 /usr/bin/php-cgi && \
    rm -rf /var/cache/apk/*

# nfqws2 + config/lists/lua/blobs
COPY --from=fetch /out/ /
# built web UI (SPA + index.php) -> docroot
COPY --from=webbuild /src/web/dist/ /www/nfqws/
# lighttpd site config from the UI repo + our runtime files (init, base lighttpd.conf)
COPY nfqws-keenetic-web/etc/lighttpd/conf.d/openwrt.conf /etc/lighttpd/conf.d/80-nfqws.conf
COPY nfqws-keenetic-web/etc/nfqws_web.conf /etc/nfqws_web.conf
COPY rootfs/ /
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh /etc/init.d/nfqws2-keenetic && \
    sed -i 's/^enabled = true/enabled = false/' /etc/nfqws_web.conf

ENTRYPOINT ["tini", "--", "/entrypoint.sh"]
```

- [ ] **Step 2: Delete the superseded build files**

```bash
git rm Dockerfile_latest_autoinstall entrypoint_latest_autoinstall.sh
```

- [ ] **Step 3: Build the image for the local arch**

Run: `docker buildx build --platform linux/amd64 -t nfqws2-mikrotik:test --load .`
Expected: build succeeds; the `webbuild` and `fetch` stages complete without errors.

- [ ] **Step 4: Verify the layout inside the image**

Run:
```bash
docker run --rm nfqws2-mikrotik:test sh -c '
  /usr/bin/nfqws2 --version 2>&1 | head -n1 && \
  test -f /etc/nfqws2/nfqws2.conf.default && \
  ls /etc/nfqws2/lua/zapret-lib.lua /etc/nfqws2/blobs/tls_clienthello.bin >/dev/null && \
  test -f /www/nfqws/index.php && test -f /www/nfqws/index.html && \
  test -x /etc/init.d/nfqws2-keenetic && \
  grep -q "^enabled = false" /etc/nfqws_web.conf && \
  php-cgi -v >/dev/null && \
  echo LAYOUT_OK'
```
Expected: an nfqws2 version line then `LAYOUT_OK`.

- [ ] **Step 5: Smoke-test the web server (php + SPA)**

Run:
```bash
cid=$(docker run -d --cap-add NET_ADMIN --cap-add NET_RAW nfqws2-mikrotik:test)
sleep 3
docker exec "$cid" sh -c 'wget -qO- http://127.0.0.1:90/ | head -c 200'   # SPA index.html
docker exec "$cid" sh -c 'wget -qO- --post-data="cmd=status" http://127.0.0.1:90/index.php'  # JSON from PHP
docker logs "$cid" | tail -n 5
docker rm -f "$cid"
```
Expected: the first request returns HTML (the SPA shell); the POST to `index.php` returns a JSON object containing `"nfqws2"` and `"service"` keys (proves php-cgi + the service `status` path work). `nft` masquerade errors in logs are acceptable if the test host lacks NET_ADMIN — rerun with `--privileged` if so.

- [ ] **Step 6: Commit**

```bash
git add Dockerfile
git commit -m "feat: bundled Dockerfile (nfqws2 keenetic layout + web UI); drop autoinstall variant"
```

---

### Task 6: Update the README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Rewrite README** with: project summary (nfqws2 + web UI, arm64/amd64), the MikroTik RouterOS setup (verbatim block below), the web UI access note, and config persistence.

Replace `README.md` content with:

````markdown
# nfqws2-mikrotik

Контейнер для запуска **NFQWS2 (zapret2)** на MikroTik RouterOS (7.21+) со встроенным
веб-интерфейсом [nfqws-keenetic-web](https://github.com/nfqws/nfqws-keenetic-web).
Поддерживаются архитектуры **ARM64** и **AMD64**.

Образ: `ghcr.io/<owner>/nfqws2-mikrotik`

## Установка на MikroTik

```
/interface/bridge add name=Bridge-Docker port-cost-mode=short
/ip/address add address=192.168.254.1/24 interface=Bridge-Docker
/interface/veth add address=192.168.254.7/24 gateway=192.168.254.1 name=NFQWS2
/interface/bridge/port add bridge=Bridge-Docker interface=NFQWS2
/container/add remote-image=ghcr.io/<owner>/nfqws2-mikrotik interface=NFQWS2 \
  root-dir=/usb1/docker/nfqws2-mikrotik start-on-boot=yes logging=yes \
  dns=1.1.1.1,8.8.8.8,9.9.9.9
```

Направьте нужный трафик в контейнер (mark-routing на шлюз `192.168.254.7`), например:

```
/routing table add disabled=no fib name=to_nfqws2
/ip route add check-gateway=ping gateway=192.168.254.7 routing-table=to_nfqws2
/ip firewall mangle add action=mark-routing chain=prerouting dst-address-type=!local \
  in-interface-list=LAN new-routing-mark=to_nfqws2 passthrough=no src-address=<client-ip> place-before=0
```

## Веб-интерфейс

Доступен на `http://192.168.254.7:90` (адрес veth). Авторизация по умолчанию
отключена (`/etc/nfqws_web.conf`, `[auth] enabled = false`), т.к. интерфейс доступен
только во внутренней Docker-сети.

## Конфигурация

Настройки и списки хранятся в `/etc/nfqws2` (`nfqws2.conf`, `lists/*.list`). Смонтируйте
этот путь как volume, чтобы правки сохранялись между перезапусками. Файрвол —
нативный nftables; `nfqws2` работает через NFQUEUE.

> Кнопки обновления/версии в веб-интерфейсе не работают в контейнере (нет opkg/apk) —
> это ожидаемо; редактирование конфигов и управление сервисом работают.
````

- [ ] **Step 2: Verify**

Run: `grep -q 'ghcr.io' README.md && grep -q '192.168.254.7:90' README.md && echo OK`
Expected: `OK`.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: README for bundled image + MikroTik setup + web UI"
```

---

### Task 7: Add the GHCR build workflow

**Files:**
- Create: `.github/workflows/build.yml`

- [ ] **Step 1: Write the workflow**

Create `.github/workflows/build.yml`:

```yaml
name: build

on:
  push:
    branches: [master]
    tags: ['v*']
  workflow_dispatch:

permissions:
  contents: read
  packages: write

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          submodules: recursive

      - uses: docker/setup-qemu-action@v3

      - uses: docker/setup-buildx-action@v3

      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - id: meta
        uses: docker/metadata-action@v5
        with:
          images: ghcr.io/${{ github.repository }}
          tags: |
            type=ref,event=branch
            type=semver,pattern={{version}}
            type=raw,value=latest,enable={{is_default_branch}}
            type=sha

      - uses: docker/build-push-action@v6
        with:
          context: .
          platforms: linux/arm64,linux/amd64
          push: true
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
          cache-from: type=gha
          cache-to: type=gha,mode=max
```

- [ ] **Step 2: Validate the workflow syntax**

Run: `actionlint .github/workflows/build.yml` (or, if actionlint is unavailable, `python -c 'import yaml,sys; yaml.safe_load(open("_")); print("yaml-ok")'.replace("_",".github/workflows/build.yml")`)
Expected: no errors / `yaml-ok`.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/build.yml
git commit -m "ci: multi-arch build + push to GHCR"
```

---

### Task 8: Full multi-arch build verification

- [ ] **Step 1: Build both arches without loading (buildx validates the arm64 path under qemu)**

Run: `docker buildx build --platform linux/arm64,linux/amd64 -t nfqws2-mikrotik:multi .`
Expected: both platforms build successfully (no push). This confirms the arm64 `fetch` stage picks `linux-arm64` and the node build (on `$BUILDPLATFORM`) is reused across arches.

- [ ] **Step 2: Confirm the plan's success criteria are met**

Verify against the spec's success criteria: image builds multi-arch; container serves the UI on :90; `index.php` returns status JSON; init `start`/`stop` create/remove the `inet nfqws2` table (requires `--privileged` on a Linux host with NFQUEUE — note if the CI/dev host cannot exercise this and defer to on-device testing).

- [ ] **Step 3: Push branch and open PR**

```bash
git push -u origin feat/web-ui-integration
gh pr create --fill
```

---

## Self-Review

**Spec coverage:**
- Static binary from zapret2, arch-matched → Task 5 `fetch` stage. ✓
- Keenetic layout, `ROOT_DIR=''` paths → Tasks 2/5 + Global Constraints. ✓
- Native nft init, 1:1 NFQUEUE translation, reuse `_startup_args`, drop ndm/policy → Task 2. ✓
- Web UI submodule + build stage → Tasks 1/5. ✓
- lighttpd + php-cgi on :90, docroot `/www` → Tasks 3/5. ✓
- Entrypoint: seed config, autodetect iface, masquerade, start services → Task 4. ✓
- Remove old Dockerfiles → Task 5. ✓
- Auth default false → Task 5. ✓
- GHCR multi-arch CI → Task 7/8. ✓
- README with MikroTik setup + web UI → Task 6. ✓

**Placeholder scan:** `<owner>` / `<client-ip>` in README are user-supplied runtime values, not plan gaps. No TBD/TODO in steps. The one deliberate open item (nft `ct … packets` spelling) is a verify-and-adjust step with an explicit fallback, not a placeholder.

**Type/name consistency:** init actions `start|stop|restart|reload|status` used consistently across Tasks 2/4/5; `nfqws2.conf.default` name consistent Tasks 4/5; docroot `/www` + `/www/nfqws` consistent Tasks 3/5; conf.d file `80-nfqws.conf` consistent Tasks 3/5; image name via `github.repository` consistent Task 7. ✓
