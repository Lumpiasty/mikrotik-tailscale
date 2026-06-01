# mikrotik-tailscale

[<img src="https://woodpecker.lumpiasty.xyz/api/badges/3/status.svg" alt="Pipeline status">](https://woodpecker.lumpiasty.xyz/repos/3)

A minimal Tailscale Docker image built for MikroTik routers running
[Container](https://help.mikrotik.com/docs/display/ROS/Container). Fits in
16 MB internal flash. Built from source with only router-relevant features
included.

> Disclaimer: This project has been largely vibe-coded, but I stand behind design and implementation choices made.

- **~4 MB** extracted rootfs (`FROM scratch` + UPX'd Tailscale binary + a custom
  static busybox debug shell).
- **Multi-arch**: amd64, arm64, arm/v7 — one tag, RouterOS pulls the right one.
- **No built-in updater** (it would pull the full upstream binary and wear
  flash); updates are delivered by CI and pulled only when the image actually
  changed.
- **Flash-wear conscious**: minimal persistent state, no netmap disk-caching,
  tmpfs for scratch and runtime.

## Motivation

There is no built-in Tailscale integration in MikroTik, and other solutions
feel underwhelming. I've used Fluent-networks' tailscale-mikrotik until now,
but that basically forced me to connect external storage to my router
just to use Tailscale. This approach, while works, is fragile, wasteful
and overcomplicated, so I decided to do better one myself.

| | **This project** | Fluent-networks/tailscale-mikrotik |
|---|---|---|
| Size | **~4 MB** | ~106 MB |
| Size reduction technique | **Minimal container with custom Tailscale and Busybox builds, compressed by UPX** | Alpine Linux base, Tailscale binary compressed by UPX on build, but auto-update completely nullifies that on first launch |
| Update mechanism | **Automatically released optimized container images with new Tailscale versions, scheduled script updating deployment on new version** | None, opt-in Tailscale built-in auto-update downloading official binaries |
| Flash wear | **Write-heavy functionality compiled out, suitable for low-endurance flash chips** | High, constant netmap cache updates |
| Stability | **Immutable container** | Tailscale app can update on its own |
| Features | **Only router-useful Tailscale features compiled, Busybox providing shell and utils** | Full tailscale, OpenSSH server, Bash, IPTables |

## Documentation

- **[Usage](docs/USAGE.md)** — deploy the published image on a MikroTik router
  and operate it (networking, auth, MagicDNS, automatic updates). Start here if
  you just want it running.
- **[Development](docs/DEVELOPMENT.md)** — build the image, test it locally, bump
  the Tailscale version, and cut releases.
- **[Design & rationale](docs/DESIGN.md)** — size optimizations, the feature
  allowlist, why certain features are deliberately removed, flash-wear
  protection, and the versioning / release / update architecture.

## Supported architectures

| Docker platform | RouterOS arch | Example devices |
|---|---|---|
| `linux/amd64`  | x86 / CHR | x86 installs, Cloud Hosted Router |
| `linux/arm64`  | arm64 | RB5009, CCR2004/2116/2216, hAP ax³, L009, Chateau |
| `linux/arm/v7` | arm (ARMv7) | hAP ac², RB3011, RB4011, RB1100AHx4 |

ARMv5 (hEX Refresh / hAP ax S) is **not** supported — see
[DESIGN.md](docs/DESIGN.md#architecture-support).

## Quick start

- **Run it on a router:** follow **[docs/USAGE.md](docs/USAGE.md)** — it deploys
  the prebuilt image, no build needed.
- **Build it yourself:** `./build.sh` (needs docker buildx + QEMU for
  cross-arch); details in **[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)**.

## Repository layout

| Path | Purpose |
|---|---|
| `Dockerfile` | Multi-stage, multi-arch build (cross-compiled Go + custom busybox) |
| `busybox-applets.config` | Curated busybox applet set |
| `build.sh` | Build all/one arch, optionally export per-arch tarballs |
| `routeros/update-tailscale.rsc` | RouterOS auto-update script (digest compare + recreate) |
| `.woodpecker/` | CI: Renovate cron, release tagging, multi-arch publish |
| `renovate.json` | Dependency-update rules |
| `docs/` | Tutorial and design docs |
