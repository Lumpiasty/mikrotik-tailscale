# Design & rationale

Why `mikrotik-tailscale` is built the way it is: size optimizations, the
feature allowlist, deliberate omissions, flash-wear protection, and the
versioning/release/update architecture.

For deployment, see [USAGE.md](USAGE.md); for building and releasing, see
[DEVELOPMENT.md](DEVELOPMENT.md).

## Image size

On-disk footprint once extracted (this is what matters — RouterOS stores the
**extracted** rootfs on disk via overlayfs, not the compressed layers).
Measured flattened rootfs for the arm64 image:

| Component | On-disk size |
|---|---|
| `tailscale.combined` (UPX-compressed) | ~2.98 MB |
| custom static busybox (UPX, ~100 applets) | ~218 kB |
| CA certificates | ~213 kB |
| **Total extracted rootfs** | **~3.4 MB** |

(The compressed image / transfer tarball is ~3.3–4.3 MB depending on arch.)

| Arch | Image (compressed) |
|---|---|
| amd64  | ~4.2 MB |
| arm64  | ~3.5 MB |
| arm/v7 | ~3.5 MB |

> The extracted rootfs must contain the binary only **once**. If you measure
> ~7 MB on the device with `du -sx /`, the Dockerfile has reintroduced an
> overlayfs copy-up — see
> [Avoiding overlayfs layer duplication](#avoiding-overlayfs-layer-duplication).

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
  [`busybox-applets.config`](../busybox-applets.config).

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

### Avoiding overlayfs layer duplication

A subtle but important detail: **the final image must not run a `RUN` that
mutates a directory already populated by an earlier layer**, or the extracted
on-disk size roughly doubles for that directory's contents.

RouterOS Container uses overlayfs and stores the **extracted** layers on disk.
Each Dockerfile instruction is its own layer. If `/usr/local/bin/` is created by
a `COPY` (containing the ~3 MB `tailscale.combined`) and a later `RUN ln -s …`
adds a symlink *inside that same directory*, overlayfs performs a **copy-up**:
it copies the entire `/usr/local/bin/` directory — including the 3 MB binary —
into the new layer's upper dir. RouterOS then extracts both copies to flash, so
`du -sx /` reports ~7 MB instead of ~3.4 MB for a directory whose only real file
is 3 MB. (The compressed image hides this — compression dedupes identical blocks
— which is why it only shows up when you measure the *extracted* rootfs on the
device.)

The fix: assemble `/usr/local/bin/` completely in the **builder** stage (binary
+ both `argv[0]` symlinks) and bring it into the final image with a **single
`COPY` layer**, never mutating it afterwards. The Dockerfile does this; don't
reintroduce a post-`COPY` `RUN` against that path.

To verify the extracted footprint on a deployed router:

```
/container/shell [find where name=tailscale]
du -sx /        # expect ~3500 KiB (1 KiB blocks), not ~7000
```

## Architecture support

A single Dockerfile builds all three supported RouterOS architectures. The Go
binary is **cross-compiled** (the builder stage runs natively on the host for
speed), while the busybox stage and final image are built for the target
platform (via `buildx` + QEMU/binfmt for non-native targets).

**ARMv5 is not supported** (hEX Refresh / hAP ax S, EN7562CT CPU — RouterOS
calls these `arm32v5`). ARMv5 has no Alpine/musl base image, so it cannot use
this image's musl + `scratch` design; it would require a glibc (Debian) base
and produce a substantially larger image (~50 MB+ vs ~4 MB). If you need it,
that's a separate build, not just a `--platform` change.

## Features included

| Feature | Why |
|---|---|
| `advertise-exit-node` | Run the router as a Tailscale exit node |
| `advertise-routes` | Expose LAN subnets to the tailnet |
| `use-exit-node` | Route the router's own traffic via a remote exit node |
| `accept-routes` | Receive subnet routes from other tailnet nodes |
| DNS / MagicDNS | Resolve `*.ts.net` names |
| portmapper (NAT-PMP/PCP/UPnP) | Punch through upstream NAT |
| listenrawdisco | Raw socket disco for better NAT traversal |
| health | Powers `tailscale status` output |
| iptables | Linux iptables support for routing rules |
| osrouter | Configure kernel network stack and routing tables |
| unixsocketidentity | **Required** — without it the localapi denies every CLI call with "access denied" ([tailscale#17873](https://github.com/tailscale/tailscale/issues/17873)) |

## Features intentionally omitted

| Feature | Reason |
|---|---|
| `clientupdate` | **Deliberately removed** — see [Why the built-in updater is removed](#why-the-built-in-updater-is-removed) |
| `cachenetmap` | **Deliberately removed** — see [Why netmap disk-caching is removed](#why-netmap-disk-caching-is-removed) |
| `logtail` | Would attempt persistent log writes; wear flash |
| `netlog` | Network flow logging; separate concern |
| `netstack` + `gro` | Userspace/gVisor networking; router uses kernel TUN |
| `ssh` | Access via MikroTik SSH + `tailscale` CLI instead |
| `linuxdnsfight` | inotify on `/etc/resolv.conf`; no systemd in container |
| `networkmanager` / `resolved` / `dbus` / `sdnotify` | No systemd stack in container |
| `drive` / `taildrop` / `webclient` | Not useful on a headless router |
| All GUI / desktop / cloud / k8s features | Irrelevant |

### Why the built-in updater is removed

Tailscale's `clientupdate` feature (and `tailscale update` / auto-update) is
**intentionally compiled out**, for several compounding reasons:

- **It would defeat the entire purpose of this build.** `clientupdate`
  downloads the *full official upstream binary* — built with every feature, tens
  of megabytes — and writes it onto the device. This image exists precisely to
  be a few MB with only router-relevant features; letting it pull the upstream
  binary would undo all of that.
- **It would risk filling the flash.** On a 16 MB-class device, downloading and
  unpacking a large upstream binary can simply run the device out of space, and
  the download itself causes significant flash writes.
- **It can't work on a container image anyway.** The binary lives in a
  read-only, content-addressed image layer. An in-place self-update has nowhere
  valid to write and would not survive a container recreate — the next pull
  would replace it regardless.
- **Updates should be controlled and reproducible.** Instead of the client
  silently swapping its own binary, new versions are produced by rebuilding and
  republishing *this* image through CI (pinned dependencies, known feature set,
  multi-arch). The device then pulls a new image **only when it actually
  changed** — see [Versioning & releases](#versioning--releases).

Net effect: the update path is explicit, version-pinned, flash-safe, and keeps
the on-device footprint minimal — none of which the built-in updater could
provide here.

### Why netmap disk-caching is removed

The `cachenetmap` feature is **intentionally omitted**. It is worth being
precise about what it does and doesn't do:

- The network map always lives in the daemon's **memory** — this is core
  behavior, not gated by any feature flag. A daemon that has connected once and
  then **loses its control-plane connection keeps that map** and can still
  reach known peers. The data path is direct WireGuard / DERP between nodes; the
  control plane is only for coordination, not for relaying your traffic. So
  initiating a connection to a reachable peer during a control outage works
  **without** this feature, as long as the daemon stays running.
- `cachenetmap` *only* adds writing that map to **disk**, so the node can come
  online from the last-known config after a **cold start that coincides with a
  control-plane outage** — a narrow case (it requires a reboot *and* control
  being unreachable at that moment *and* needing connectivity before control
  recovers).

The cost of the feature is that it writes the netmap to flash, and the netmap
changes frequently on an active tailnet (every peer endpoint/DERP/online-status
change). For a flash-constrained router that is the wrong trade: frequent writes
to internal flash to buy resilience for a rare corner case. Omitting it keeps
the in-memory resilience (the common case) while eliminating per-netmap flash
writes. Only `tailscaled.state` (written on auth / key rotation) ever touches
flash.

## Volume layout

Two mount points, with different persistence requirements:

```
/var/lib/tailscale          persistent — node identity, auth state
                            bind-mount to MikroTik disk storage
                            written rarely (only on auth / key rotation /
                            prefs change); netmap is not cached to disk
                            (cachenetmap omitted), so no per-netmap writes

/var/run/tailscale          ephemeral — daemon Unix socket
                            mount as tmpfs
                            lost on reboot, recreated on start
```

Only the small, rarely-written state file touches flash; the socket dir is
tmpfs. The netmap is held in memory only — see
[Why netmap disk-caching is removed](#why-netmap-disk-caching-is-removed).

## Flash wear protection

Several measures are in place to avoid wearing out internal flash:

- `clientupdate` omitted from binary — no background update downloads
  ([why](#why-the-built-in-updater-is-removed))
- `cachenetmap` omitted from binary — netmap is never written to disk, so the
  frequent netmap updates cause no flash writes
  ([why](#why-netmap-disk-caching-is-removed))
- `logtail` omitted from binary — no log upload attempts
- `--no-logs-no-support` passed to daemon — suppresses any remaining log
  buffering
- `/var/run/tailscale` socket on tmpfs — runtime files never reach flash
- Only `/var/lib/tailscale/tailscaled.state` touches persistent storage,
  and it is written only when the node authenticates or rotates its key

## Versioning & releases

Released images are versioned as:

```
v<TAILSCALE_VERSION>-mt.<N>
```

e.g. `v1.98.3-mt.1`. The two parts mean:

- **`v<TAILSCALE_VERSION>`** — the bundled Tailscale version (the "what's
  inside" identifier), taken from `ARG TAILSCALE_VERSION` in the Dockerfile.
- **`mt.<N>`** — the local revision. It only changes on a *meaningful* release,
  never on a build-system-only rebuild.

### When a release happens

| Trigger | Result |
|---|---|
| Renovate bumps `TAILSCALE_VERSION` (merged to `main`) | CI **auto-creates** git tag `v<new>-mt.1` → image published |
| You make a meaningful fix/change on the current Tailscale version | **You** create the next tag manually (`v<ts>-mt.2`, `mt.3`, …) → image published |
| Dependency-only bump (Go / Alpine / busybox / Dockerfile syntax) | **No release.** Rides along with the next Tailscale bump or manual tag |

So routers only ever see a new release for Tailscale bumps or your deliberate
fixes — build-system churn doesn't trigger updates.

Each published image is stamped with `org.opencontainers.image.version` equal to
its full tag; this is the value the MikroTik update job compares against the
registry to decide whether to recreate the container.

### How it's wired (Woodpecker)

- **`.woodpecker/release-tag.yaml`** — on push to `main`, parses
  `TAILSCALE_VERSION`; if no `v<ts>-mt.*` tag exists yet, creates and pushes
  `v<ts>-mt.1` (using the Gitea token from OpenBao). It never creates `mt.2+`.
- **`.woodpecker/release.yaml`** — on a `v*-mt.*` tag push, builds the
  multi-arch manifest (amd64 + arm64 + arm/v7) and pushes it to
  `gitea.lumpiasty.xyz/lumpiasty/mikrotik-tailscale` as both `:<tag>` and
  `:stable`. Registry creds come from OpenBao (`secret/container-registry`).

To cut a release manually, see
[DEVELOPMENT.md → Cutting a manual release](DEVELOPMENT.md#cutting-a-manual-release).

### How the router consumes releases

The RouterOS update script (`routeros/update-tailscale.rsc`) compares the
`:stable` **manifest digest** against the digest from the last deploy:

- It fetches the digest using an anonymous bearer token (the Gitea package is
  public) — no credentials stored on the router.
- **Unchanged → does nothing** (no pull, no recreate, no flash wear).
- **Changed → recreates the container** from the new image, then records the
  new digest.

Because `:stable` only moves on a meaningful release, dependency-only rebuilds
never trigger an update on the router. Setup is in
[USAGE.md → step 7](USAGE.md#7-enable-automatic-updates).

## Dependency pinning & automated updates

All upstream dependencies are version-pinned for reproducible builds, fully
qualified (no floating `major.minor` tags):

| Dependency | Where | Pinned form |
|---|---|---|
| Go toolchain | `Dockerfile` `FROM golang:…` | full version tag + `@sha256` digest |
| Alpine (busybox build base) | `Dockerfile` `FROM alpine:…` | full version tag + `@sha256` digest |
| Tailscale | `Dockerfile` `ARG TAILSCALE_VERSION` | full git release tag |
| busybox | `Dockerfile` `ARG BUSYBOX_VERSION` | full release version |
| Renovate / OpenBao | `.woodpecker/*.yaml` `image:` | full version tag |

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

Validate the configs locally:

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
