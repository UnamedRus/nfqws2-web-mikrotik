# Design: Bundle nfqws-keenetic-web + nfqws2 into the MikroTik container, add GHCR CI

Date: 2026-07-30

## Goal

Turn `nfqws2-mikrotik` into a single multi-arch (linux/arm64 + linux/amd64) container image that:

1. Runs `nfqws2` (DPI bypass) using the **nfqws2-keenetic** file layout and config format, driven by **native nftables** (matching how wiktorbgu/nfqws2-mikrotik runs on MikroTik RouterOS), and
2. Serves the **nfqws-keenetic-web** PHP web UI on port 90 to manage it.

Plus GitHub Actions CI that builds and pushes the image to GitHub Container Registry (GHCR).

The MikroTik runtime model of wiktorbgu/nfqws2-mikrotik (veth gateway + masquerade, ROS 7.21+) is preserved; only the engine internals gain the keenetic layout + web UI, and the firewall stays native nft.

## Background / key facts (from research)

- The `nfqws2` binary is **fully static** (no INTERP, no NEEDED) — it runs on bare Alpine musl. Canonical source: `bol-van/zapret2` release asset `zapret2-vX.Y.Z-openwrt-embedded.tar.gz`, path `binaries/linux-<arch>/nfqws2`, plus the sibling `lua/` dir (gzipped `.lua.gz` strategy scripts).
- `nfqws2-keenetic` provides the management layer around that binary: default `nfqws2.conf`, default lists (`user/exclude/auto/ipset/ipset_exclude.list`), `blobs/{quic_initial.bin,tls_clienthello.bin}`, and an init script. Its config is shell-sourced `KEY="value"`.
- `nfqws2-keenetic`'s init firewall is written for iptables + NFQUEUE, but every rule maps 1:1 to native nftables (see "nft translation" below). MikroTik RouterOS ≥ 7.21 provides the kernel netfilter/NFQUEUE support; wiktorbgu's existing image already uses native `nft`.
- `nfqws-keenetic-web`: React 19 + Vite 7 + TanStack, yarn 4 (vendored). Build = `yarn install --immutable`, `yarn openapi`, `yarn build` in `web/` → output `web/dist/` (the SPA **plus** `index.php`, copied from `web/public/`). Output is architecture-independent.
- `index.php` auto-detects the install root: `ROOT_DIR='/opt'` if `/opt/usr/bin/nfqws2` exists, else `''` (OpenWRT-style). We use `ROOT_DIR=''`:
  - binary `/usr/bin/nfqws2`
  - config `/etc/nfqws2/nfqws2.conf`, lists `/etc/nfqws2/lists`, lua `/etc/nfqws2/lua`, blobs `/etc/nfqws2/blobs`
  - logs `/var/log/nfqws2.log`
  - service script `/etc/init.d/nfqws2-keenetic` (this exact name is what `index.php` calls when `ROOT_DIR=''`; its `status` output must contain the substring `is running`)
  - web docroot `/www/nfqws`, lighttpd cgi `/usr/bin/php-cgi`
- The web UI's `upgrade` and installed-version actions shell out to `opkg`/`apk`. With no package manager in the container these **noop / return empty** — non-fatal; file editing and service start/stop/restart/reload all work.

## MikroTik runtime model (preserved from wiktorbgu, unchanged)

The container is attached to a RouterOS veth and acts as a routing gateway; RouterOS routing-marks selected client traffic to the container, which masquerades it outbound and DPI-mangles it via NFQUEUE. RouterOS-side setup (documented in README, unchanged):

```
/interface/bridge add name=Bridge-Docker port-cost-mode=short
/ip/address add address=192.168.254.1/24 interface=Bridge-Docker
/interface/veth add address=192.168.254.7/24 gateway=192.168.254.1 name=NFQWS2
/interface/bridge/port add bridge=Bridge-Docker interface=NFQWS2
/container/add remote-image=ghcr.io/<owner>/nfqws2-mikrotik interface=NFQWS2 \
  root-dir=/usb1/docker/nfqws2-mikrotik start-on-boot=yes logging=yes dns=1.1.1.1,8.8.8.8,9.9.9.9
# routing-mark selected sources to the container (mangle or routing rule) …
```

Inside the container the outbound interface is the veth (default route dev), so the default `ISP_INTERFACE` is set accordingly (see entrypoint). The web UI is reachable at `http://192.168.254.7:90`.

## Decisions

- **Engine internals + UI:** nfqws2-keenetic file layout + config format + the `nfqws-keenetic-web` UI (option #3). We ship **our own small init** rather than adopting the keenetic init wholesale.
- **Firewall:** **native nftables** (`nft`), not iptables. The container also keeps a blanket outbound masquerade for the gateway role (native nft), as wiktorbgu does.
- **Inclusion:** add `nfqws-keenetic-web` as a **git submodule** pinned to a release tag. Frontend built from source in the image.
- **nfqws2-keenetic assets** (default `nfqws2.conf`, default lists, blobs) fetched at build from the `nfqws2-keenetic` repo at a pinned tag. `lua/` + the static `nfqws2` binary come from `bol-van/zapret2` release, arch-matched. All `/opt/` paths rewritten to `/` (`sed 's#/opt/#/#g'`).
- **Layout:** OpenWRT-style, `ROOT_DIR=''`.
- **Old files removed:** `Dockerfile`, `Dockerfile_latest_autoinstall`, `entrypoint_latest_autoinstall.sh`. Replaced by one bundled Dockerfile + one entrypoint.
- **Scope:** nfqws2 only (drop the `V=`/`V=2` nfqws1/nfqws2 switch — the web UI is nfqws2-oriented).
- **Registry:** GHCR only (`ghcr.io/<owner>/nfqws2-mikrotik`), auth via `GITHUB_TOKEN`.

## Architecture

### Repo structure (after change)

```
nfqws2-mikrotik/
├── .github/workflows/build.yml      # multi-arch build + push to GHCR
├── .gitmodules                      # nfqws-keenetic-web submodule
├── nfqws-keenetic-web/              # submodule (pinned tag)
├── Dockerfile                       # new bundled build (replaces old)
├── entrypoint.sh                    # new entrypoint
├── rootfs/                          # files baked into the image
│   ├── etc/init.d/nfqws2-keenetic   # our nft-native init
│   └── etc/lighttpd/…               # base lighttpd.conf if the alpine default needs overriding
├── README.md                        # updated: MikroTik setup + web UI
└── docs/superpowers/specs/…         # this spec
```

(`Dockerfile_latest_autoinstall`, `entrypoint_latest_autoinstall.sh` deleted.)

### Dockerfile (multi-stage)

Build ARGs (pinned, overridable): `ZAPRET2_VERSION`, `NFQWS2_KEENETIC_VERSION`. `TARGETARCH`/`BUILDPLATFORM` provided by buildx.

1. **`webbuild` stage** — `FROM --platform=$BUILDPLATFORM node:20-alpine`. Copy the `nfqws-keenetic-web` submodule, run `corepack enable` (yarn 4 is vendored), `yarn install --immutable`, `yarn openapi`, `yarn build` → `/web/dist`. Pinned to `$BUILDPLATFORM` (native, no qemu); output is arch-independent.
2. **`fetch` stage** — `FROM alpine` (per target arch). Map `TARGETARCH`→zapret2 dir (`amd64`→`linux-x86_64`, `arm64`→`linux-arm64`). Download the zapret2 embedded tarball, extract `binaries/<dir>/nfqws2` + `lua/`. Download the `nfqws2-keenetic` source at the pinned tag; take `etc/nfqws2/{nfqws2.conf,lists,blobs}`. `sed 's#/opt/#/#g'` on the config. Assemble a staging tree.
3. **Final stage** — `FROM alpine`. `apk add --no-cache nftables iptables ip6tables lighttpd lighttpd-mod-cgi lighttpd-mod-setenv lighttpd-mod-rewrite lighttpd-mod-redirect php83-cgi php83-session php83-curl php83-ctype php83-openssl netcat-openbsd curl tzdata ca-certificates tini` (final php module set confirmed against a runtime smoke test; add only what `index.php` requires — session + curl are the known hard deps). Copy: `nfqws2`→`/usr/bin/nfqws2`; `/etc/nfqws2/{nfqws2.conf(.default),lists,lua,blobs}`; web `dist`→`/www/nfqws`; the UI's `etc/lighttpd/conf.d/openwrt.conf`→`/etc/lighttpd/conf.d/80-nfqws.conf`; `etc/nfqws_web.conf`→`/etc/nfqws_web.conf`; `rootfs/etc/init.d/nfqws2-keenetic`; `entrypoint.sh`. Ensure `/etc/lighttpd/lighttpd.conf` includes `conf.d/*.conf` and sets docroot `/www`. `ENTRYPOINT ["tini","--","/entrypoint.sh"]`.

### Our init script — `/etc/init.d/nfqws2-keenetic`

POSIX-ish `sh` (busybox/ash). Sources `/etc/nfqws2/nfqws2.conf`. Reuses keenetic's `_startup_args` verbatim (engine-agnostic; builds the `nfqws2` CLI from `NFQWS_BASE_ARGS`/`NFQWS_ARGS`/`NFQWS_ARGS_QUIC`/`NFQWS_ARGS_UDP`/`NFQWS_EXTRA_ARGS`/`NFQWS_ARGS_IPSET`/`NFQWS_ARGS_CUSTOM`, `--user`, `--qnum`). Drops Keenetic-only pieces: ndm/`create_running_config` policy marks, and the `insmod`-from-`/lib/modules` fallback (on the host ROS the modules are built in; we `modprobe -a -q … || true` best-effort).

Actions: `start | stop | restart | reload | status`.

- `status`: prints `Service NFQWS2 is running` / `… is stopped` (UI matches substring `is running`). Uses a pidfile `/var/run/nfqws2.pid`.
- `start`: `system_config` (best-effort sysctls) → build nft ruleset → launch daemon.
- daemon: `/usr/bin/nfqws2 --daemon --pidfile=/var/run/nfqws2.pid $(_startup_args)`.
- `stop`: kill pid + tear down the nft table. `reload`: `kill -HUP`. `restart`: stop+start.

**nft ruleset (native).** One table `inet nfqws2` with two chains at mangle priority, replacing the keenetic mangle chains. `NFQUEUE_NUM`, `TCP_PORTS`, `UDP_PORTS`, `ISP_INTERFACE`, `IPV6_ENABLED` come from the config. `MAX_PKT=15`. The reinject mark `0x40000000` is what nfqws2 sets on packets it already handled.

```
table inet nfqws2 {
  chain post {
    type filter hook postrouting priority mangle; policy accept;
    # for each $ISP_INTERFACE (oifname):
    oifname "<iface>" meta mark and 0x40000000 != 0x40000000 \
      udp dport { <UDP_PORTS> } ct original packets 1-15 queue num <N> bypass
    oifname "<iface>" meta mark and 0x40000000 != 0x40000000 \
      tcp dport { <TCP_PORTS> } ct original packets 1-15 queue num <N> bypass
    oifname "<iface>" meta mark and 0x40000000 != 0x40000000 tcp dport { <TCP_PORTS> } tcp flags fin queue num <N> bypass
    oifname "<iface>" meta mark and 0x40000000 != 0x40000000 tcp dport { <TCP_PORTS> } tcp flags rst queue num <N> bypass
  }
  chain pre {
    type filter hook prerouting priority mangle; policy accept;
    iifname "<iface>" meta mark and 0x40000000 == 0x40000000 return
    iifname "<iface>" udp sport { <UDP_PORTS> } ct reply packets 1-15 queue num <N> bypass
    iifname "<iface>" tcp sport { <TCP_PORTS> } ct reply packets 1-15 queue num <N> bypass
    iifname "<iface>" tcp sport { <TCP_PORTS> } tcp flags syn,ack queue num <N> bypass
    iifname "<iface>" tcp sport { <TCP_PORTS> } tcp flags fin queue num <N> bypass
    iifname "<iface>" tcp sport { <TCP_PORTS> } tcp flags rst queue num <N> bypass
  }
}
```

Port ranges use nft syntax (`590-600`), so `UDP_PORTS` from the config (`443,590:600,…`) is normalized `:`→`-`. `inet` family covers v4+v6 in one table; when `IPV6_ENABLED=0` we still queue (nfqws2 handles v4 only per its args) — acceptable, or restrict with `meta nfproto ipv4`. Masquerade is NOT in this table (see entrypoint).

### entrypoint.sh

```
#!/bin/sh
set -e
# seed config on first run (volume-friendly)
[ -f /etc/nfqws2/nfqws2.conf ] || cp /etc/nfqws2/nfqws2.conf.default /etc/nfqws2/nfqws2.conf
# default ISP_INTERFACE to the container's default-route iface if unset by user
# (written into nfqws2.conf on first seed only)
# blanket outbound masquerade for the gateway role (native nft), as wiktorbgu does
nft add table ip nat 2>/dev/null || true
nft add chain ip nat postrouting '{ type nat hook postrouting priority srcnat; }' 2>/dev/null || true
nft add rule ip nat postrouting masquerade 2>/dev/null || true
# web server
lighttpd -f /etc/lighttpd/lighttpd.conf
if [ $# -gt 0 ]; then exec "$@"; fi
echo "NFQWS2 $(/usr/bin/nfqws2 --version 2>&1 | head -n1)"
/etc/init.d/nfqws2-keenetic start || true
exec sleep infinity
```

`ISP_INTERFACE` seeding: on first-run seed, detect the default-route interface (`ip route show default`) and write it into the fresh `nfqws2.conf` so the nft rules bind the right veth. Exact detection refined in implementation.

### CI — `.github/workflows/build.yml`

- Triggers: `push` to `master`, `push` tags `v*`, `workflow_dispatch`.
- Permissions: `contents: read`, `packages: write`.
- Steps: `actions/checkout@v4` (`submodules: recursive`) → `docker/setup-qemu-action` → `docker/setup-buildx-action` → `docker/login-action` (registry `ghcr.io`, user `${{ github.actor }}`, password `${{ secrets.GITHUB_TOKEN }}`) → `docker/metadata-action` (tags: `latest` on master, semver on `v*`, plus sha) → `docker/build-push-action` (`platforms: linux/arm64,linux/amd64`, `push: true`, pass pinned build-args).

## Runtime / usage notes (README)

- Requires host kernel NFQUEUE support (RouterOS ≥ 7.21). Container needs the netfilter capabilities (RouterOS `/container` provides host net namespace on the veth).
- Web UI at `http://192.168.254.7:90` (the veth address). Auth toggled in `/etc/nfqws_web.conf`; the container has no `/etc/shadow` users, so ship `[auth] enabled = false` by default (documented) — the UI is only reachable on the internal Docker bridge.
- Config + lists persist via a volume/mount on `/etc/nfqws2`.

## Out of scope

- The web UI's `upgrade`/installed-version buttons (no package manager in container — they noop).
- `V=`/`V=2` nfqws1 vs nfqws2 switching (nfqws2 only).
- Keenetic router policy marks / ndm integration (useless in a container).
- Padavan/mips arches (arm64 + amd64 only).

## Success criteria

- `docker buildx build --platform linux/arm64,linux/amd64` succeeds for the new Dockerfile.
- In a running container on ROS ≥ 7.21 (veth gateway per README): web UI loads at `:90`, lists conf/list/log/lua files, edits + saves them; start/stop/restart/reload toggle the nfqws2 service and `status` reflects it; the nft `inet nfqws2` table is populated on start and removed on stop; routed client traffic on the configured ports is DPI-bypassed.
- CI publishes a multi-arch manifest to `ghcr.io/<owner>/nfqws2-mikrotik`.
