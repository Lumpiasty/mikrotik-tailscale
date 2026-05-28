# mikrotik-tailscale

A minimal Tailscale Docker image built for MikroTik routers running
[Container](https://help.mikrotik.com/docs/display/ROS/Container). Fits in
16 MB internal flash. Built from source with only router-relevant features
included.

## Supported architectures

| Docker platform | RouterOS arch | Example devices |
|---|---|---|
| `linux/amd64`  | x86 / CHR | x86 installs, Cloud Hosted Router |
| `linux/arm64`  | arm64 | RB5009, CCR2004/2116/2216, hAP ax³, L009, Chateau |
| `linux/arm/v7` | arm (ARMv7) | hAP ac², RB3011, RB4011, RB1100AHx4 |

A single Dockerfile builds all three. The Go binary is **cross-compiled** (the
builder stage runs natively on the host for speed), while the busybox stage and
final image are built for the target platform (via `buildx` + QEMU/binfmt for
non-native targets).

**ARMv5 is not supported** (hEX Refresh / hAP ax S, EN7562CT CPU — RouterOS
calls these `arm32v5`). ARMv5 has no Alpine/musl base image, so it cannot use
this image's musl + `scratch` design; it would require a glibc (Debian) base
and produce a substantially larger image (~50 MB+ vs ~4 MB). If you need it,
that's a separate build, not just a `--platform` change.

## Image size

On-disk footprint once extracted (this is what matters — RouterOS stores the
**extracted** rootfs on disk via overlayfs, not the compressed layers):

| Component | On-disk size |
|---|---|
| tailscale.combined (UPX-compressed) | ~3.84 MB |
| custom static busybox (UPX, ~100 applets) | ~229 kB |
| CA certificates | ~218 kB |
| **Total extracted rootfs** | **~4.1 MB** |

(The compressed image / transfer tarball is ~4.3 MB.)

The binary is built with Tailscale's `--extra-small` feature tag set as the
baseline. Features are opted in explicitly — any new feature Tailscale adds
in a future release stays omitted until deliberately added to the Dockerfile.

### Size optimizations applied

- **Feature allowlist** (`--extra-small` baseline + ~10 opt-ins) keeps the
  binary minimal and forward-safe against new Tailscale features.
- **`-gcflags=all=-l`** disables function inlining across all packages,
  shrinking the compressed binary by ~600 kB. Inlining is a performance
  optimization only; disabling it does not affect correctness. The CPU cost
  is negligible for an I/O-bound router daemon.
- **`-ldflags="-s -w"`** strips the symbol table and DWARF debug info.
- **`-trimpath`** removes local filesystem paths from the binary.
- **UPX `--lzma --best`** compresses the Tailscale binary (~14 MB → ~3.8 MB).
- **Custom static busybox** — instead of the official `busybox:musl` image
  (all ~404 applets, ~1.24 MB), a static busybox is built from source with
  only ~100 curated applets (~420 kB), then UPX-compressed to ~229 kB on
  disk. The applet set is defined in
  [`busybox-applets.config`](busybox-applets.config).

  **busybox UPX requires care.** UPX normally breaks busybox's standalone
  applet dispatch: the ash shell re-execs `/proc/self/exe` to run built-in
  applets, and UPX breaks that path so typed commands fail
  ([upx#248](https://github.com/upx/upx/issues/248), closed as "invalid").
  We work around it by building **without** the standalone/nofork features
  and providing an explicit `/bin/<applet>` symlink farm. Commands then
  resolve via the normal `PATH` → symlink → `argv[0]` dispatch, which works
  under UPX. The cost is a `fork+exec` per command instead of a nofork
  internal call — fine for an occasional debug shell.

  Because RouterOS stores the extracted rootfs on disk, UPX'ing busybox
  saves a real ~195 kB of flash (424 kB → 229 kB), not just transfer size.

The final image is built `FROM scratch` — there is no base distro layer.
It contains only the busybox binary + applet symlinks, the CA bundle, and
the Tailscale binary.

## Features included

| Feature | Why |
|---|---|
| `advertise-exit-node` | Run the router as a Tailscale exit node |
| `advertise-routes` | Expose LAN subnets to the tailnet |
| `use-exit-node` | Route the router's own traffic via a remote exit node |
| `accept-routes` | Receive subnet routes from other tailnet nodes |
| DNS / MagicDNS | Resolve `*.ts.net` names (see DNS section below) |
| portmapper (NAT-PMP/PCP/UPnP) | Punch through upstream NAT |
| listenrawdisco | Raw socket disco for better NAT traversal |
| health | Powers `tailscale status` output |
| cachenetmap | Cache network map for faster reconnect after reboot |
| iptables | Linux iptables support for routing rules |
| osrouter | Configure kernel network stack and routing tables |

## Features intentionally omitted

| Feature | Reason |
|---|---|
| `clientupdate` | Updates are managed by rebuilding the Docker image |
| `logtail` | Would attempt persistent log writes; wear flash |
| `netlog` | Network flow logging; separate concern |
| `netstack` + `gro` | Userspace/gVisor networking; router uses kernel TUN |
| `ssh` | Access via MikroTik SSH + `tailscale` CLI instead |
| `linuxdnsfight` | inotify on `/etc/resolv.conf`; no systemd in container |
| `networkmanager` / `resolved` / `dbus` / `sdnotify` | No systemd stack in container |
| `drive` / `taildrop` / `webclient` | Not useful on a headless router |
| All GUI / desktop / cloud / k8s features | Irrelevant |

## Volume layout

Three mount points, with different persistence requirements:

```
/var/lib/tailscale          persistent — node identity, auth state
                            bind-mount to MikroTik disk storage
                            written rarely (only on auth / key rotation)

/var/lib/tailscale/cache    ephemeral — netmap cache
                            mount as tmpfs to avoid flash writes
                            recreated automatically on next connect

/var/run/tailscale          ephemeral — daemon Unix socket
                            mount as tmpfs
                            lost on reboot, recreated on start
```

Keeping the cache and socket directories on tmpfs prevents unnecessary
flash wear while still allowing fast reconnect after reboot (the cache
is repopulated from the Tailscale coordination server on first connect).

## Building

### All architectures at once

Use the helper script (requires `docker buildx` + QEMU/binfmt for non-native
targets):

```sh
# One-time: register emulators for cross-arch builds
docker run --privileged --rm tonistiigi/binfmt --install arm64,arm

# Build all arches and load into local docker
./build.sh

# Build all arches and also export per-arch tarballs into ./dist/
./build.sh --tar

# Build a single arch
./build.sh arm64
./build.sh --tar armv7
```

### Manual single-arch build

The architecture is selected via `buildx --platform`; the Dockerfile maps it to
the correct `GOARCH`/`GOARM` automatically:

```sh
docker buildx build --platform linux/arm64  --load -t mikrotik-tailscale:arm64 .
docker buildx build --platform linux/arm/v7 --load -t mikrotik-tailscale:armv7 .
docker buildx build --platform linux/amd64  --load -t mikrotik-tailscale:amd64 .
```

To build for a different Tailscale version, add:

```sh
--build-arg TAILSCALE_VERSION=v1.98.3
```

### Notes

- The Go builder cross-compiles natively (fast); only the busybox stage runs
  under emulation for non-native targets.
- The build prints the resolved target and Go build tags, e.g.:

  ```
  Cross-compiling: GOOS=linux GOARCH=arm64 GOARM=
  Build tags: ts_include_cli,ts_omit_ace,ts_omit_acme,...
  ```

### Per-architecture image sizes

| Arch | Image |
|---|---|
| amd64  | ~4.2 MB |
| arm64  | ~3.5 MB |
| arm/v7 | ~3.5 MB |

## Running (local test)

```sh
# Create a volume for persistent state
docker volume create tailscale-state

# Start the daemon
docker run -d \
  --name tailscale \
  --cap-add NET_ADMIN \
  --cap-add NET_RAW \
  --device /dev/net/tun \
  --tmpfs /var/lib/tailscale/cache \
  --tmpfs /var/run/tailscale \
  -v tailscale-state:/var/lib/tailscale \
  mikrotik-tailscale

# Authenticate (opens browser / prints auth URL)
docker exec tailscale tailscale login

# Check status
docker exec tailscale tailscale status

# Advertise a subnet
docker exec tailscale tailscale set --advertise-routes=192.168.88.0/24

# Advertise as exit node
docker exec tailscale tailscale set --advertise-exit-node
```

Subnet routes and exit node advertisement must also be approved in the
[Tailscale admin console](https://login.tailscale.com/admin/machines).

## Unattended authentication

For automated / headless deployment, use an auth key:

```sh
docker exec tailscale tailscale up \
  --authkey=tskey-auth-<key> \
  --advertise-routes=192.168.88.0/24 \
  --advertise-exit-node
```

Auth keys can be created in the Tailscale admin console under
**Settings → Keys**. Use a reusable key tagged with a device tag for
infrastructure nodes.

## MagicDNS

The binary includes DNS support but the daemon is started with
`--no-logs-no-support`, which does not affect DNS. To use MagicDNS name
resolution, configure MikroTik's DNS to forward `.ts.net` queries to
Tailscale's magic DNS resolver:

```
/ip dns static
add name="ts.net" type=FWD forward-to=100.100.100.100 match-subdomain=yes
```

This avoids writing to `/etc/resolv.conf` inside the container (which would
happen if `--accept-dns` is passed to `tailscale up`). The container resolves
Tailscale node names; the rest of the router uses its own DNS.

## Flash wear protection

Several measures are in place to avoid wearing out internal flash:

- `clientupdate` omitted from binary — no background update downloads
- `logtail` omitted from binary — no log upload attempts
- `--no-logs-no-support` passed to daemon — suppresses any remaining log
  buffering
- `netmap` cache mounted on tmpfs — cache writes never reach flash
- `/var/run/tailscale` socket on tmpfs — runtime files never reach flash
- Only `/var/lib/tailscale/tailscaled.state` touches persistent storage,
  and it is written only when the node authenticates or rotates its key

## Upgrading

Version bumps (Tailscale, busybox, base image digests) are normally proposed
automatically via Renovate — see
[Dependency pinning & automated updates](#dependency-pinning--automated-updates).
Merge the Renovate PR, then rebuild and redeploy.

The feature allowlist in the Dockerfile carries forward automatically across
Tailscale versions — any new `ts_omit_*` tags introduced in a new release will
be omitted by default.

To bump manually, edit `ARG TAILSCALE_VERSION` in the `Dockerfile` (so the pin
stays in version control) and rebuild:

```sh
./build.sh --tar      # rebuild all arches at the pinned version
# or, override at build time without editing the Dockerfile:
docker buildx build --platform linux/arm64 \
  --build-arg TAILSCALE_VERSION=v1.100.0 \
  --load -t mikrotik-tailscale:arm64 .
```

## Dependency pinning & automated updates

All upstream dependencies are version-pinned for reproducible builds:

All versions are fully qualified (no floating `major.minor` tags):

| Dependency | Where | Pinned form |
|---|---|---|
| Go toolchain | `Dockerfile` `FROM golang:…` | full version tag + `@sha256` digest |
| Alpine (busybox build base) | `Dockerfile` `FROM alpine:…` | full version tag + `@sha256` digest |
| Tailscale | `Dockerfile` `ARG TAILSCALE_VERSION` | full git release tag |
| busybox | `Dockerfile` `ARG BUSYBOX_VERSION` | full release version |
| Renovate / OpenBao | `.woodpecker/renovate.yaml` `image:` | full version tag |

Updates are proposed automatically by [Renovate](https://docs.renovatebot.com/),
run **self-hosted** from a Woodpecker cron pipeline (Woodpecker has no native
Renovate support):

- `renovate.json` — repository rules. All dependencies follow the latest
  upstream releases (including major versions); each bump arrives as its own PR
  that the multi-arch build validates before you merge. Base image tags also
  get their `@sha256` digests refreshed via `pinDigests`. The one special rule:
  - `tailscale` only follows **stable** releases — Tailscale uses even minor
    versions for stable (`v1.98.x`) and odd for unstable (`v1.99.x`), so the
    rule filters to even minors.
- `.woodpecker/renovate.yaml` — the scheduled job that runs `renovate/renovate`
  against this repo.

```sh
# Renovate repo config
docker run --rm -e RENOVATE_CONFIG_TYPE=repo -v "$PWD":/work -w /work \
  --entrypoint renovate-config-validator renovate/renovate

# Woodpecker pipeline
docker run --rm -v "$PWD":/work -w /work \
  woodpeckerci/woodpecker-cli:v3 lint .woodpecker/renovate.yaml
```

## References

- [Tailscale: Smaller binaries for embedded devices](https://tailscale.com/docs/how-to/set-up-small-tailscale)
- [Renovate self-hosting](https://docs.renovatebot.com/getting-started/running/)
- [Woodpecker cron jobs](https://woodpecker-ci.org/docs/usage/cron)
- [MikroTik Container documentation](https://help.mikrotik.com/docs/display/ROS/Container)
- [Tailscale subnet routers](https://tailscale.com/kb/1019/subnets)
- [Tailscale exit nodes](https://tailscale.com/kb/1103/exit-nodes)
