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
    mkdir -p /out/usr/bin /out/usr/share/nfqws2/lua; \
    cp "$Z/binaries/$ZDIR/nfqws2" /out/usr/bin/nfqws2; \
    chmod +x /out/usr/bin/nfqws2; \
    cp "$Z"/lua/*.lua.gz /out/usr/share/nfqws2/lua/; \
    for f in /out/usr/share/nfqws2/lua/*.lua.gz; do gunzip -f "$f"; done; \
    curl -fsSL "https://github.com/nfqws/nfqws2-keenetic/archive/refs/tags/v${NFQWS2_KEENETIC_VERSION}.tar.gz" -o kt.tgz; \
    tar xzf kt.tgz; \
    K="nfqws2-keenetic-${NFQWS2_KEENETIC_VERSION}"; \
    cp -r "$K/etc/nfqws2/lists" /out/usr/share/nfqws2/lists; \
    cp -r "$K/etc/nfqws2/blobs" /out/usr/share/nfqws2/blobs; \
    sed 's#/opt/#/#g' "$K/etc/nfqws2/nfqws2.conf" > /out/usr/share/nfqws2/nfqws2.conf.default

# --- Final runtime image ---
FROM alpine
RUN apk add --no-cache \
      nftables iproute2 \
      lighttpd \
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
