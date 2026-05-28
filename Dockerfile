# syntax=docker/dockerfile:1
# =============================================================================
# Multi-architecture build
# =============================================================================
# Supported MikroTik Container architectures (build with `docker buildx`):
#   linux/amd64        x86 / CHR
#   linux/arm64        RB5009, CCR2xxx, hAP ax3, L009, Chateau (most modern)
#   linux/arm/v7       ARMv7: hAP ac2, RB3011, RB4011, RB1100AHx4
#
# NOT supported here: ARMv5 (hEX Refresh / hAP ax S, EN7562CT CPU). ARMv5 has
# no Alpine/musl base image, so it cannot use the musl + scratch design below;
# it would need a glibc (Debian) base and produces a much larger image. See
# README for details if you need it.
#
# The Go builder cross-compiles, so it always runs NATIVELY on the build host
# ($BUILDPLATFORM) for speed; only the busybox stage and the final image run on
# the target platform.

# =============================================================================
# Stage 1: Build Tailscale combined binary (cross-compiled, runs natively)
# =============================================================================
FROM --platform=$BUILDPLATFORM golang:1.26-alpine AS builder

ARG TAILSCALE_VERSION=v1.98.3

# Provided automatically by buildx for the target platform.
ARG TARGETOS
ARG TARGETARCH
ARG TARGETVARIANT

RUN apk add --no-cache \
    git \
    upx \
    ca-certificates

# Clone the exact release tag (no full history)
RUN git clone --depth 1 --branch ${TAILSCALE_VERSION} \
    https://github.com/tailscale/tailscale.git /src/tailscale

WORKDIR /src/tailscale

# Build a minimal combined binary (tailscale CLI + tailscaled daemon in one file).
#
# Tag strategy — ALLOWLIST, not blocklist:
#   1. cmd/featuretags --min --add=osrouter generates the full ts_omit_* set
#      (identical to build_dist.sh --extra-small), omitting every optional feature.
#   2. We pipe that through sed to REMOVE the ts_omit_ tags for the features
#      we explicitly want, leaving everything else omitted.
#   3. We prepend ts_include_cli (combined daemon+CLI binary).
#
# This means any NEW ts_omit_* tag added in a future Tailscale release will
# automatically be omitted — we only get features we consciously opt into.
#
# Features opted in (removed from the omit list):
#   advertiseexitnode   — run as exit node for the tailnet
#   advertiseroutes     — advertise LAN subnets to the tailnet
#   useexitnode         — route router's own traffic via a remote exit node
#   useroutes           — accept routes advertised by other tailnet nodes
#   dns                 — MagicDNS; configure MikroTik DNS to forward
#                         *.ts.net → 100.100.100.100; use --no-dns daemon
#                         flag to skip writing /etc/resolv.conf
#   portmapper          — NAT-PMP / PCP / UPnP to punch through upstream NAT
#   listenrawdisco      — raw sockets for more robust disco/NAT-traversal
#   health              — health subsystem required by 'tailscale status'
#   cachenetmap         — cache netmap on disk for faster reconnect after reboot
#                         IMPORTANT: mount cache dir on tmpfs, not internal flash
#   iptables            — Linux iptables support for routing rules
#
# Everything else remains omitted, including (rationale):
#   clientupdate  — updates managed via Docker image rebuild
#   logtail       — no persistent log writes to flash; also pass
#                   --no-logs-no-support at runtime
#   netstack+gro  — userspace networking; router uses kernel TUN
#   ssh           — not needed; access via MikroTik SSH + tailscale CLI
#   all GUI/desktop/cloud/k8s features — irrelevant for a headless router

RUN mkdir -p /out && \
    ALL_OMIT=$(GOOS= GOARCH= go run ./cmd/featuretags --min --add=osrouter) && \
    TAGS=$(echo "ts_include_cli,${ALL_OMIT}" | \
        sed \
          -e 's/ts_omit_advertiseexitnode,\{0,1\}//g' \
          -e 's/ts_omit_advertiseroutes,\{0,1\}//g' \
          -e 's/ts_omit_useexitnode,\{0,1\}//g' \
          -e 's/ts_omit_useroutes,\{0,1\}//g' \
          -e 's/ts_omit_dns,\{0,1\}//g' \
          -e 's/ts_omit_portmapper,\{0,1\}//g' \
          -e 's/ts_omit_listenrawdisco,\{0,1\}//g' \
          -e 's/ts_omit_health,\{0,1\}//g' \
          -e 's/ts_omit_cachenetmap,\{0,1\}//g' \
          -e 's/ts_omit_iptables,\{0,1\}//g' \
          -e 's/,$//' \
    ) && \
    echo "Build tags: ${TAGS}" && \
    # Map Docker's TARGETARCH/TARGETVARIANT to Go's GOARCH/GOARM.
    # For arm/v7 -> GOARM=7 (hardfloat). Other arches leave GOARM unset.
    GOARM="" && \
    if [ "${TARGETARCH}" = "arm" ]; then \
      case "${TARGETVARIANT}" in \
        v7) GOARM=7 ;; \
        v6) GOARM=6 ;; \
        v5) GOARM=5 ;; \
        *)  GOARM=7 ;; \
      esac; \
    fi && \
    echo "Cross-compiling: GOOS=${TARGETOS:-linux} GOARCH=${TARGETARCH} GOARM=${GOARM}" && \
    CGO_ENABLED=0 GOOS=${TARGETOS:-linux} GOARCH=${TARGETARCH} GOARM=${GOARM} \
    go build \
      -tags "${TAGS}" \
      -gcflags="all=-l" \
      -ldflags="-s -w" \
      -trimpath \
      -o /out/tailscale.combined \
      ./cmd/tailscaled

# Compress with UPX LZMA.
# Expected: ~14 MB raw → ~3.8 MB compressed (with -gcflags=all=-l)
RUN upx --lzma --best /out/tailscale.combined

# =============================================================================
# Stage 2: Custom minimal busybox
# =============================================================================
# The official busybox:musl image ships all ~404 applets at ~1.24 MB. For a
# debug shell on a flash-constrained router we only need ~100 applets, so we
# build a static busybox from source with a curated applet set, then UPX it
# down to ~230 kB on disk.
#
# UPX is normally dangerous with busybox: the ash shell's standalone applet
# dispatch re-execs /proc/self/exe, which UPX breaks, so typed commands fail
# (https://github.com/upx/upx/issues/248, closed as "invalid"). We sidestep
# this by building WITHOUT the standalone/nofork features (see
# busybox-applets.config) and providing an explicit /bin/<applet> symlink
# farm. Commands then resolve via the ordinary PATH -> symlink -> argv[0]
# dispatch, which works fine under UPX. The cost is a fork+exec per command,
# acceptable for an occasional debug shell. RouterOS stores the EXTRACTED
# rootfs on disk (overlayfs), so the ~190 kB UPX saving is real on-disk space.
#
# This stage runs on the TARGET platform (no --platform override): gcc then
# produces native target-arch binaries directly. Under buildx this is
# transparently emulated via binfmt/QEMU for non-native targets.
FROM alpine:3.21 AS busybox

ARG BUSYBOX_VERSION=1.37.0

RUN apk add --no-cache build-base linux-headers wget bzip2 perl upx

RUN wget -q https://busybox.net/downloads/busybox-${BUSYBOX_VERSION}.tar.bz2 \
 && tar xf busybox-${BUSYBOX_VERSION}.tar.bz2
WORKDIR /busybox-${BUSYBOX_VERSION}

# allnoconfig = every feature OFF; then enable only the curated applet set.
COPY busybox-applets.config /tmp/applets.config
RUN make allnoconfig && \
    while read -r sym; do \
      case "$sym" in ''|\#*) continue ;; esac; \
      if grep -q "^# CONFIG_${sym} is not set" .config; then \
        sed -i "s/^# CONFIG_${sym} is not set/CONFIG_${sym}=y/" .config; \
      elif ! grep -q "^CONFIG_${sym}=y" .config; then \
        echo "CONFIG_${sym}=y" >> .config; \
      fi; \
    done < /tmp/applets.config && \
    yes "" | make oldconfig >/dev/null 2>&1 && \
    make -j"$(nproc)" >/dev/null 2>&1 && \
    strip busybox

# Lay out a minimal rootfs with busybox + an applet symlink per applet.
# Symlinks (argv[0] dispatch) are how busybox selects an applet and make the
# applets resolvable via $PATH from inside the shell. We derive the applet
# names from the build .config: a symbol is an applet if its lowercase name
# resolves to a runnable applet (busybox returns "applet not found" on stderr
# for non-applet symbols like FEATURE_* / STATIC, which we filter out).
# We generate symlinks from the UNCOMPRESSED binary (so the probe is reliable),
# then UPX-compress the binary in place afterwards.
RUN mkdir -p /rootfs/bin && \
    grep '^CONFIG_.*=y' .config \
      | sed -e 's/^CONFIG_//' -e 's/=y$//' \
      | tr 'A-Z' 'a-z' \
      | while read -r app; do \
          if ! ./busybox "$app" --help 2>&1 | grep -q "applet not found"; then \
            ln -sf /bin/busybox /rootfs/bin/"$app"; \
          fi; \
        done && \
    ln -sf /bin/busybox /rootfs/bin/sh && \
    echo "Applet symlinks created: $(ls /rootfs/bin | wc -l)" && \
    upx --lzma --best busybox && \
    cp busybox /rootfs/bin/busybox

# =============================================================================
# Stage 3: Final runtime image
# =============================================================================
FROM scratch

# Custom static busybox + applet symlinks (provides /bin/sh and utilities)
COPY --from=busybox /rootfs/ /

# CA certificates (needed to reach Tailscale coordination server)
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/

# Combined Tailscale binary
COPY --from=builder /out/tailscale.combined /usr/local/bin/tailscale.combined

# Symlinks: combined binary behavior switches on argv[0]
RUN ["/bin/busybox", "ln", "-s", "/usr/local/bin/tailscale.combined", "/usr/local/bin/tailscale"]
RUN ["/bin/busybox", "ln", "-s", "/usr/local/bin/tailscale.combined", "/usr/local/bin/tailscaled"]

# Ensure /usr/local/bin and busybox dirs are on PATH for interactive shells
ENV PATH=/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# -----------------------------------------------------------------------------
# Volume layout (to be created by deploy script):
#
#   /var/lib/tailscale       — persistent state (authkey, node identity)
#                              → bind-mount to MikroTik disk storage
#                              → survives reboots, written infrequently
#
#   /var/lib/tailscale/cache — netmap cache (cachenetmap feature)
#                              → mount as tmpfs so it never touches flash
#                              → speeds up reconnect but is recreatable
#
#   /var/run/tailscale       — runtime socket dir
#                              → tmpfs, lost on reboot (expected)
# -----------------------------------------------------------------------------
VOLUME ["/var/lib/tailscale"]

ENTRYPOINT ["/usr/local/bin/tailscaled"]

# Default flags:
#   --no-logs-no-support  disables logtail uploads (logtail binary code is
#                         omitted, but the flag also suppresses any remaining
#                         log buffering and prevents the daemon from trying
#                         to write log files)
#   --state               persistent node identity / authkey storage
#   --socket              CLI communication socket (on tmpfs)
#   --statedir            where cache and other runtime files land
CMD ["--no-logs-no-support", \
     "--state=/var/lib/tailscale/tailscaled.state", \
     "--socket=/var/run/tailscale/tailscaled.sock", \
     "--statedir=/var/lib/tailscale"]
