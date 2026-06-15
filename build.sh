#!/bin/sh
# Build mikrotik-tailscale images for all supported MikroTik architectures.
#
# Produces one OCI image per architecture and, optionally, a per-arch tarball
# suitable for `/container/add file=...` on RouterOS.
#
# Usage:
#   ./build.sh                 # build all arches, load into local docker
#   ./build.sh arm64           # build a single arch
#   ./build.sh --tar           # build all arches and export .tar files
#   ./build.sh --tar arm64     # build one arch and export its .tar
#
# Requirements:
#   - docker with buildx
#   - For non-native targets: binfmt/QEMU emulators registered for the applet
#     symlink probe step (a minor step; the full C/Go compile is native):
#       docker run --privileged --rm tonistiigi/binfmt --install arm64,arm
set -eu

IMAGE="${IMAGE:-mikrotik-tailscale}"
TAG="${TAG:-latest}"
OUTDIR="${OUTDIR:-dist}"

# MikroTik Container supported architectures (Docker platform -> tag suffix).
# ARMv5 (hEX Refresh / hAP ax S) is intentionally excluded; it has no musl
# base and needs a separate glibc build — see README.
PLATFORMS="linux/amd64:amd64 linux/arm64:arm64 linux/arm/v7:armv7"

make_tar=0
only_arch=""
for arg in "$@"; do
  case "$arg" in
    --tar) make_tar=1 ;;
    -*)    echo "unknown flag: $arg" >&2; exit 1 ;;
    *)     only_arch="$arg" ;;
  esac
done

build_one() {
  platform="$1"
  suffix="$2"
  ref="${IMAGE}:${TAG}-${suffix}"

  echo ">>> Building ${ref} for ${platform}"
  set -- --platform "${platform}" --load -t "${ref}"
  if [ -n "${TAILSCALE_VERSION:-}" ]; then
    set -- "$@" --build-arg "TAILSCALE_VERSION=${TAILSCALE_VERSION}"
  fi
  docker buildx build "$@" .

  if [ "${make_tar}" -eq 1 ]; then
    mkdir -p "${OUTDIR}"
    out="${OUTDIR}/${IMAGE}-${TAG}-${suffix}.tar"
    echo ">>> Exporting ${out}"
    docker save "${ref}" -o "${out}"
    echo "    $(ls -l "${out}" | awk '{printf "%.1f MB", $5/1048576}')  ${out}"
  fi
}

for entry in $PLATFORMS; do
  platform="${entry%%:*}"
  suffix="${entry##*:}"
  if [ -n "${only_arch}" ] && [ "${only_arch}" != "${suffix}" ]; then
    continue
  fi
  build_one "${platform}" "${suffix}"
done

echo ">>> Done."
echo "Images:"
docker images "${IMAGE}" --format '  {{.Repository}}:{{.Tag}}\t{{.Size}}'
