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

On a deployed RouterOS device the container consumes **~3.7 MiB of flash**
(measured by `free-hdd-space` delta). Note that `du` *inside* the container
reports roughly double that (~7 MB) — that is RouterOS block-allocation
rounding, **not** real usage or duplication; see
[Avoiding overlayfs layer duplication](#avoiding-overlayfs-layer-duplication)
for how to measure correctly.

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
It contains only the busybox binary + applet symlinks, the CA bundle, the
Tailscale binary, and a tiny `entrypoint.sh`.

### Entrypoint: IP forwarding

`ENTRYPOINT` is a small `entrypoint.sh` that enables IPv4 and IPv6 forwarding
(`net.ipv4.ip_forward`, `net.ipv6.conf.all.forwarding`) in the container's
network namespace, then `exec`s `tailscaled` (so the daemon stays PID 1). This
is necessary because `tailscaled` does **not** reliably enable IPv6 forwarding
itself inside a container netns — it logs "IPv6 forwarding is disabled" and
advertised IPv6 subnet routes silently fail. The sysctls are writable from
inside a RouterOS container, so the entrypoint sets them directly; no
host-side or `/container` configuration is required. The script is created in
the builder stage so it ships in the same single `/usr/local/bin` `COPY` layer
(preserving the [single-copy property](#avoiding-overlayfs-layer-duplication)).

### Avoiding overlayfs layer duplication

Best practice for the final image: **don't run a `RUN` that mutates a directory
already populated by an earlier layer.** Each Dockerfile instruction is its own
layer; if `/usr/local/bin/` is created by a `COPY` (containing the ~3 MB
`tailscale.combined`) and a later `RUN ln -s …` adds a symlink *inside that same
directory*, overlayfs performs a **copy-up** of the entire directory — including
the 3 MB binary — into the new layer. The binary then physically exists in two
image layers.

The fix: assemble `/usr/local/bin/` completely in the **builder** stage (binary
+ both `argv[0]` symlinks) and bring it into the final image with a **single
`COPY` layer**, never mutating it afterwards. The Dockerfile does this; don't
reintroduce a post-`COPY` `RUN` against that path. You can confirm the published
image carries the binary in exactly one layer:

```
docker save <image> -o img.tar && tar xf img.tar -C img/
# then grep each blob layer for usr/local/bin/tailscale.combined — it must
# appear in exactly ONE layer.
```

Note: this is about keeping the *image* clean. It does **not** change what `du`
reports on the device — see the measurement note below.

To verify the on-flash footprint on a deployed router, use the **free-space
delta**, not `du`:

```
/system/resource/print     # note free-hdd-space before and after adding the container
```

The container should consume **~3.7 MiB** of flash (e.g. 94.6 → 90.9 MiB free).

Do **not** trust `du` inside the container for this. Busybox `du` reports
*allocated blocks*, and RouterOS's container store rounds a ~3 MB file up to
~6 MB of blocks — so `du -sx /` reports ~7 MB even though real flash use is
~3.7 MB. `ls -la /usr/local/bin` confirms the binary's true content size
(~3.1 MB) and that it is a single file with two symlinks (no duplication).
The image itself carries the binary in exactly one layer (verified at the blob
level); the inflation is purely the filesystem's block accounting.

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
| ipnbus | Lets `tailscale up` wait for completion and print the login URL; without it `up` returns immediately without confirming success |

## Features intentionally omitted

| Feature | Reason |
|---|---|
| `clientupdate` | **Deliberately removed** — see [Why the built-in updater is removed](#why-the-built-in-updater-is-removed) |
| `cachenetmap` | **Deliberately removed** — see [Why netmap disk-caching is removed](#why-netmap-disk-caching-is-removed) |
| `logtail` | Would attempt persistent log writes; wear flash. Removing it also removes stderr verbosity filtering — restored by an injected filter, see [Log verbosity filtering](#log-verbosity-filtering) |
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

### Log verbosity filtering

Upstream `tailscaled` embeds verbosity tags (`[v1]`, `[v2]`, …) inside its log
messages and relies on the **logtail** subsystem to act on them: in a stock
build, logtail's log policy intercepts everything written via the standard
`log` package, parses the tag, and only writes a line to stderr when its level
is within `--verbose` (default 0 — non-verbose messages only). The `--verbose`
flag is literally wired into logtail (`pol.SetVerbosityLevel(args.verbose)` in
`cmd/tailscaled/tailscaled.go`).

This build omits logtail (`ts_omit_logtail`) to avoid log-upload code and
flash writes — but that removed the stderr filtering along with it, as
collateral damage. The result: every verbose line went **unfiltered** to
stderr and into the RouterOS container log, with the literal `[v1]` tag still
in the text. On an active node that means constant spam, several lines per
minute:

```
tailscale: ... [v1] Accept: TCP{...:53256 > ...:50000} 391 tcp non-syn
tailscale: ... netcheck: [v1] report: udp=true v6=true ... derp=22 ...
tailscale: ... wg: [v2] [0GwzF] - Receiving keepalive packet
```

This is a [known](https://github.com/tailscale/tailscale/issues/12158)
[long-standing](https://github.com/tailscale/tailscale/issues/1548) complaint
even in full builds, and RouterOS logging offers no way to discard matching
messages (no drop action, rules are all-match — a regex rule duplicates rather
than diverts).

The fix here: the build injects a ~20-line Go file
(`patches/stderr_verbosity_filter.go`, copied into `cmd/tailscaled/` before
`go build`) whose `init()` wraps the standard log output and silently drops
any line carrying a `[v1]`/`[v2]`/`[v3]` tag. This restores the exact
equivalent of logtail's default `StderrLevel=0` behavior without pulling in
the upload machinery. Properties:

- **No upstream sources modified** — it's a new file in the package, so it
  survives Tailscale version bumps without rebasing (only relies on the
  daemon using the stdlib `log` package, which is core behavior).
- **Build-tagged `//go:build ts_omit_logtail`** — if logtail is ever
  re-enabled, the file compiles out automatically and logtail's own filtering
  takes over; the two can never conflict.
- **Runtime escape hatch** — setting the `TS_LOG_VERBOSITY=1` environment
  variable disables the filter (and, conveniently, the same knob is read by
  upstream as the default `--verbose` level). Verbose logs are one
  `/container/envs/add` away; no rebuild needed. See
  [USAGE.md → Logging](USAGE.md#logging).

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

### What lives in the state dir

| File | Purpose | Write frequency |
|---|---|---|
| `tailscaled.state` | Node identity, auth keys, prefs | On auth / key rotation / prefs change |
| `derpmap.cached.json` | Cached DERP relay server list for **bootstrap DNS**: at cold start with broken/unavailable DNS, tailscaled asks DERP servers to resolve the control plane. The binary ships a static DERP list, but it goes stale; this cache keeps the current one. | Once at first auth, then **only when Tailscale's relay infrastructure changes** (a few times a year). `dnsfallback.UpdateCache` has a deep-equal guard and skips the write when the DERP map is unchanged — netmap churn never touches it. |

`derpmap.cached.json` is intentionally **kept** despite the flash-wear policy:
the policy targets *frequent* writes (netmap deltas, logs), not one-shot
caches. On a router this cache is genuinely useful — after a power outage the
device may boot with WAN up but upstream DNS broken, exactly the case where a
fresh DERP list lets the node reach the control plane anyway. With
`cachenetmap` omitted, this file and `tailscaled.state` are the only cold-start
resilience the node has. (There is no `ts_omit_*` tag for it; it is written
only because `--statedir` is set.)

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
  upstream releases; each bump arrives as its own PR. Base image tags also get
  their `@sha256` digests refreshed via `pinDigests`. Notable rules:
  - `tailscale` only follows **stable** releases — Tailscale uses even minor
    versions for stable (`v1.98.x`) and odd for unstable (`v1.99.x`), so the
    rule filters to even minors.
- `.woodpecker/renovate.yaml` — the scheduled job that runs `renovate/renovate`
  against this repo.
- `.woodpecker/pr-build.yaml` — builds all three arches (no push) on every PR
  and reports status to Gitea. This is the gate for automerge.

### Automerge policy

These updates **automerge** once the PR build passes — they reach `:stable`
(and the routers) without manual review:

| Update | Automerge? | Why |
|---|---|---|
| Tailscale stable (patch **and** minor) | ✅ | the point of the project; the PR build catches breakage |
| Go / Alpine / busybox **patch** | ✅ | bugfix-only, build-internal |
| Base-image **digest** refresh (same tag) | ✅ | content refresh, no version change |
| Go / Alpine / busybox **minor/major** | ❌ manual | larger toolchain/base changes warrant review |
| Renovate runner, syntax frontend | ❌ manual | tooling — review deliberately |

**Important:** automerge depends on the PR build being a **required status
check** in Gitea branch protection. The PR build only proves the image *builds*
for all arches — it does not run the daemon, so a runtime regression in a new
Tailscale release could still be automerged. That is an accepted trade-off for
the convenience of unattended Tailscale updates; if a release misbehaves, roll
back by re-tagging the previous `v…-mt.N` (the immutable tags are kept).

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
