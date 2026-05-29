# Development

Building the image, testing it locally, bumping the Tailscale version, and
cutting releases. This is for working *on* this repo; if you just want to run
the published image on a router, see [USAGE.md](USAGE.md).

For the reasoning behind the build choices, see [DESIGN.md](DESIGN.md).

## Prerequisites

- `docker` with `buildx`.
- For cross-arch builds, QEMU/binfmt emulators registered:

  ```sh
  docker run --privileged --rm tonistiigi/binfmt --install arm64,arm
  ```

The Go toolchain and busybox are built inside the image stages, so no local Go
install is needed.

## Building

### All architectures at once

Use the helper script:

```sh
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

## Running (local test)

Quick smoke test on a dev machine with Docker (this is *not* how it runs on a
router — see [USAGE.md](USAGE.md) for that):

```sh
# Create a volume for persistent state
docker volume create tailscale-state

# Start the daemon
docker run -d \
  --name tailscale \
  --cap-add NET_ADMIN \
  --cap-add NET_RAW \
  --device /dev/net/tun \
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

For headless / unattended auth, use a reusable auth key from the admin console
(**Settings → Keys**):

```sh
docker exec tailscale tailscale up \
  --authkey=tskey-auth-<key> \
  --advertise-routes=192.168.88.0/24 \
  --advertise-exit-node
```

## Bumping the Tailscale version

Version bumps (Tailscale, busybox, base image digests) are normally proposed
automatically via Renovate (see
[DESIGN.md → Dependency pinning](DESIGN.md#dependency-pinning--automated-updates)).
Merge the Renovate PR; a Tailscale bump then auto-publishes a new release.

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

## Cutting a manual release

A Tailscale bump auto-creates `v<ts>-mt.1` and publishes it. For a meaningful
fix/change on the *current* Tailscale version, tag the next `mt.N` by hand:

```sh
# fix something, commit to main, then:
git tag -a v1.98.3-mt.2 -m "Fix X"
git push origin v1.98.3-mt.2
```

The tag push triggers the build + multi-arch publish automatically. See
[DESIGN.md → Versioning & releases](DESIGN.md#versioning--releases) for the full
scheme and CI wiring.

## Validating CI configs locally

```sh
# Renovate repo config
docker run --rm -e RENOVATE_CONFIG_TYPE=repo -v "$PWD":/work -w /work \
  --entrypoint renovate-config-validator renovate/renovate

# Woodpecker pipelines
docker run --rm -v "$PWD":/work -w /work \
  woodpeckerci/woodpecker-cli:v3 lint .woodpecker/renovate.yaml
```
