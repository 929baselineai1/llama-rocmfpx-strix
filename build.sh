#!/usr/bin/env bash
# Build the llama-rocmfpx-strix container image.
#
# Two Containerfiles are provided -- pick one based on your host distro:
#   - Containerfile.fedora  (Fedora/RHEL hosts; ~1.5 GB)
#   - Containerfile.ubuntu  (Ubuntu/Debian hosts; ~1.8 GB)
#
# Default = fedora (verified path on the M5).
# Override with:  BASE=ubuntu ./build.sh
#
# Tags the image as llama-rocmfpx-strix:<base>-<version> by default.
# Override with:  TAG=foo ./build.sh
#
# Build context = current directory, which contains Containerfile.fedora,
# Containerfile.ubuntu, and entrypoint.sh. Nothing else gets shipped -- Mesa
# and ROCmFPX are cloned from upstream during the build.
#
# Typical build time on Strix Halo: 8-12 minutes (Mesa source build is the
# slow part, ~5 min). Final image size: 1.5-1.8 GB.
#
# Mesa version and ROCmFPX ref are pinned as build args. To update either:
#   ./build.sh MESA_TAG=mesa-26.2.0         # new Mesa tag
#   ./build.sh ROCMFPX_REF=v0.5.2            # or a SHA for bit-reproducibility

set -euo pipefail

# Pick a container runtime -- podman preferred, docker fallback
if command -v podman >/dev/null 2>&1; then
    RUNTIME=podman
elif command -v docker >/dev/null 2>&1; then
    RUNTIME=docker
else
    echo "error: neither podman nor docker found in PATH" >&2
    exit 1
fi

# Which base? Default fedora (verified working on the M5).
BASE="${BASE:-fedora}"
case "${BASE}" in
    fedora) CONTAINERFILE="Containerfile.fedora" ; DEFAULT_TAG_SUFFIX="fedora-43" ;;
    ubuntu) CONTAINERFILE="Containerfile.ubuntu" ; DEFAULT_TAG_SUFFIX="ubuntu-24.04" ;;
    *)
        echo "error: BASE must be 'fedora' or 'ubuntu' (got: ${BASE})" >&2
        exit 1
        ;;
esac

TAG="${TAG:-llama-rocmfpx-strix:${DEFAULT_TAG_SUFFIX}}"
CONTEXT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> runtime:      ${RUNTIME}"
echo "==> base:         ${BASE} (${CONTAINERFILE})"
echo "==> tag:          ${TAG}"
echo "==> context:      ${CONTEXT}"
echo "==> build args:   ${*:-<defaults from Containerfile>}"

# Pass through any MESA_TAG=... / ROCMFPX_REF=... overrides as build args
BUILD_ARGS=()
for arg in "$@"; do
    case "${arg}" in
        MESA_TAG=*|ROCMFPX_REF=*|ROCM_VERSION=*)
            BUILD_ARGS+=("--build-arg" "${arg}")
            ;;
        *)
            echo "warning: ignoring unknown arg '${arg}'" >&2
            ;;
    esac
done

"${RUNTIME}" build \
    -t "${TAG}" \
    -f "${CONTEXT}/${CONTAINERFILE}" \
    "${BUILD_ARGS[@]}" \
    "${CONTEXT}"

echo
echo "==> done. image: ${TAG}"
echo "    verify:  ${RUNTIME} run --rm ${TAG} --version"
echo "    run:     BASE=${BASE} ./run.sh /path/to/model.gguf"
