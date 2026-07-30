# Design: Bundle nfqws-keenetic-web + nfqws2-keenetic into the container, add GHCR CI

Date: 2026-07-30

## Goal

Turn `nfqws2-mikrotik` into a single multi-arch (linux/arm64 + linux/amd64) container image that:

1. Runs `nfqws2` (DPI bypass) using the **nfqws2-keenetic** file layout, and
2. Serves the **nfqws-keenetic-web** PHP web UI on port 90 to manage it.

Plus GitHub Actions CI that builds and pushes the image to GitHub Container Registry (GHCR).

## Background / key facts (from research)

- The `nfqws2` binary is **fully static** (no INTERP, no NEEDED) — it runs on bare Alpine musl. Canonical source: `bol-van/zapret2` release asset `zapret2-vX.Y.Z-openwrt-embedded.tar.gz`, path `binaries/linux-<arch>/nfqws2` plus a sibling `lua/` dir.
- `nfqws2-keenetic` repackages that binary and adds: `lua/` strategy scripts, `blobs/{quic_initial.bin,tls_clienthello.bin}`, a default `nfqws2.conf`, default lists, and an init script. Its init logic uses **iptables/ip6tables + NFQUEUE** (queue num 300), **not nftables**. It requires host kernel modules `nfnetlink_queue`, `xt_NFQUEUE`, `xt_multiport`, `xt_connbytes`, `xt_CONNMARK`, `nf_conntrack`. On MikroTik RouterOS these arrived in 7.21beta2 (arm64) — see the wiktorbgu gist.
- `nfqws-keenetic-web`: React 19 + Vite 7 + TanStack, yarn 4 (vendored). Build = `yarn install --immutable`, `yarn openapi`, `yarn build` in `web/` → output `web/dist/` (the SPA **plus** `index.php`, which Vite copies from `web/public/`). Output is architecture-independent.
- `index.php` auto-detects the install root: `ROOT_DIR='/opt'` if `/opt/usr/bin/nfqws2` exists, else `''` (OpenWRT-style). The OpenWRT layout (`ROOT_DIR=''`) is the natural container fit:
  - binary `/usr/bin/nfqws2`
  - config `/etc/nfqws2/nfqws2.conf`, lists `/etc/nfqws2/lists`, lua `/etc/nfqws2/lua`, blobs `/etc/nfqws2/blobs`
  - logs `/var/log/nfqws2.log`
  - service script `/etc/init.d/nfqws2-keenetic` (this exact name is what `index.php` calls when `ROOT_DIR=''`)
  - web docroot `/www/nfqws`, lighttpd cgi `/usr/bin/php-cgi`
- The web UI's `upgrade` and installed-version actions shell out to `opkg`/`apk`. With no package manager in the container these **noop/return empty** — non-fatal; file editing and service start/stop/restart/reload all work.

## Decisions

- **Inclusion:** add `nfqws-keenetic-web` as a **git submodule** pinned to a release tag. Frontend is built from source in the image.
- **nfqws2-keenetic assets** (init script, default `nfqws2.conf`, lua, blobs, default lists) are **fetched at build time** from the `nfqws2-keenetic` repo at a pinned tag; the static `nfqws2` binary is fetched from `bol-van/zapret2` release, arch-matched.
- **Layout:** OpenWRT-style, `ROOT_DIR=''` (paths under `/`, not `/opt`).
- **Firewall:** iptables (nft-compat is fine), matching the keenetic init. Container-level outbound masquerade retained for the gateway use case, expressed with iptables for consistency.
- **Old Dockerfiles removed:** both `Dockerfile` and `Dockerfile_latest_autoinstall` (they use bol-van/zapret2's single-`config` model and cannot carry the web UI). Replaced by one bundled Dockerfile.
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
├── files/                           # small pinned config/overrides if needed
│   └── lighttpd/…                   # (only if we override the shipped conf)
├── README.md                        # updated usage
└── docs/superpowers/specs/…         # this spec
```

(`Dockerfile_latest_autoinstall`, `entrypoint_latest_autoinstall.sh` deleted.)

### Dockerfile (multi-stage)

Build ARGs (pinned, overridable): `ZAPRET2_VERSION`, `NFQWS2_KEENETIC_VERSION`. `TARGETARCH`/`TARGETPLATFORM`/`BUILDPLATFORM` are provided by buildx.

1. **`webbuild` stage** — `FROM --platform=$BUILDPLATFORM node:20-alpine`.
   Copy the `nfqws-keenetic-web` submodule, run the yarn build, produce `/web/dist`.
   Pinned to `$BUILDPLATFORM` so it runs natively (no qemu) — output is arch-independent.

2. **`fetch` stage** — `FROM alpine` (runs per target arch).
   - Map `TARGETARCH` → zapret2 dir (`amd64`→`linux-x86_64`, `arm64`→`linux-arm64`).
   - Download `zapret2-v${ZAPRET2_VERSION}-openwrt-embedded.tar.gz`, extract `binaries/<dir>/nfqws2` and `lua/`.
   - Download the `nfqws2-keenetic` source tarball at `v${NFQWS2_KEENETIC_VERSION}`; take the **OpenWRT** init variant, default `nfqws2.conf`, `blobs/`, default lists. `sed 's#/opt/#/#g'` on paths.
   - Assemble a staging tree matching the final layout.

3. **Final stage** — `FROM alpine`.
   - `apk add --no-cache iptables ip6tables lighttpd lighttpd-mod-cgi lighttpd-mod-setenv lighttpd-mod-rewrite lighttpd-mod-redirect php83-cgi php83-session php83-curl php83-ctype php83-json netcat-openbsd curl tzdata ca-certificates tini` (exact php module set verified against `index.php` needs: session, curl; add others only if a require fails).
   - Copy from `fetch`: `nfqws2`→`/usr/bin/nfqws2`; `/etc/nfqws2/{nfqws2.conf,lua,blobs,lists}`; init→`/etc/init.d/nfqws2-keenetic`.
   - Copy from `webbuild`: `dist`→`/www/nfqws`.
   - Install the web UI's `etc/lighttpd/conf.d/openwrt.conf` as `/etc/lighttpd/conf.d/80-nfqws.conf`, ensure the base `/etc/lighttpd/lighttpd.conf` includes `conf.d/*.conf` and sets docroot `/www`. Install `etc/nfqws_web.conf` → `/etc/nfqws_web.conf`.
   - Copy `entrypoint.sh`, `chmod +x`.
   - `ENTRYPOINT ["tini","--","/entrypoint.sh"]`.

### entrypoint.sh

```
#!/bin/sh
set -e
# seed config on first run (volume-friendly)
[ -f /etc/nfqws2/nfqws2.conf ] || cp /etc/nfqws2/nfqws2.conf.default /etc/nfqws2/nfqws2.conf
# outbound masquerade (container as gateway)
iptables -t nat -C POSTROUTING -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -j MASQUERADE
# start web server
lighttpd -f /etc/lighttpd/lighttpd.conf
if [ $# -gt 0 ]; then exec "$@"; fi
echo "NFQWS2 $(/usr/bin/nfqws2 --version 2>&1 | head -n1)"
/etc/init.d/nfqws2-keenetic start || true
exec sleep infinity
```

(Exact masquerade scoping — interface/subnet — carried over from the current entrypoint's intent; refined during implementation. `nfqws2-keenetic status` parses "is running" for the UI.)

### CI — `.github/workflows/build.yml`

- Triggers: `push` to `master`, `push` tags `v*`, `workflow_dispatch`.
- Permissions: `contents: read`, `packages: write`.
- Steps: `actions/checkout@v4` (`submodules: recursive`) → `docker/setup-qemu-action` → `docker/setup-buildx-action` → `docker/login-action` (registry `ghcr.io`, user `${{ github.actor }}`, password `${{ secrets.GITHUB_TOKEN }}`) → `docker/metadata-action` (tags: `latest` on master, semver on tags, sha) → `docker/build-push-action` (`platforms: linux/arm64,linux/amd64`, `push: true`, pass pinned build-args).

## Runtime / usage notes (README)

- Requires host kernel NFQUEUE support (RouterOS ≥ 7.21beta2 arm64; or `--privileged` + host net on Linux).
- Web UI at `http://<host>:90`. Auth toggled in `/etc/nfqws_web.conf`; container has no `/etc/shadow` users by default, so document setting `enabled = false` or adding a user.
- Config persists via a volume on `/etc/nfqws2`.

## Out of scope

- Making the web UI's `upgrade`/version buttons work (no package manager in container — they noop).
- nftables-native nfqws2 ruleset (keenetic init is iptables-based; we follow it).
- Padavan/mips arches (image targets arm64 + amd64 only, per repo scope).

## Success criteria

- `docker buildx build --platform linux/arm64,linux/amd64` succeeds for the new Dockerfile.
- In a running container (privileged, host net, NFQUEUE-capable kernel): web UI loads at `:90`, lists config/list/log/lua files, edits + saves them, and start/stop/restart/reload toggle the nfqws2 service (status reflects it).
- CI publishes a multi-arch manifest to `ghcr.io/<owner>/nfqws2-mikrotik`.
