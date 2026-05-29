# mikrotik-tailscale

[<img src="https://woodpecker.lumpiasty.xyz/api/badges/3/status.svg" alt="Pipeline status">](https://woodpecker.lumpiasty.xyz/repos/3)

A minimal Tailscale Docker image built for MikroTik routers running
[Container](https://help.mikrotik.com/docs/display/ROS/Container). Fits in
16 MB internal flash. Built from source with only router-relevant features
included.

- **~4 MB** extracted rootfs (`FROM scratch` + UPX'd Tailscale binary + a custom
  static busybox debug shell).
- **Multi-arch**: amd64, arm64, arm/v7 — one tag, RouterOS pulls the right one.
- **No built-in updater** (it would pull the full upstream binary and wear
  flash); updates are delivered by CI and pulled only when the image actually
  changed.
- **Flash-wear conscious**: minimal persistent state, no netmap disk-caching,
  tmpfs for scratch and runtime.

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
