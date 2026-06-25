#!/usr/bin/env bash
# Launch a llama-server inside the built image.
#
# Usage:
#   ./run.sh /path/to/model.gguf [extra llama-server flags...]
#
# The base (fedora or ubuntu) is auto-detected from the local image tags. You
# can pin it with BASE=ubuntu or BASE=fedora to be explicit.
#
# Required runtime flags we add for you:
#   --device /dev/dri             expose GPU device nodes (/dev/dri/renderD128)
#   --group-add keep-groups        keep in-container user in host's render/video
#                                  groups so they can read the device nodes
#   --security-opt seccomp=unconfined  ROCm needs this; rocm-runtime makes
#                                      ptrace-related syscalls the default
#                                      seccomp filter rejects
#   --network host                let llama-server bind :8080 directly; avoids
#                                  container networking weirdness for high-
#                                  throughput local APIs
#   -v $MODEL_DIR:/models:ro      mount model files read-only at /models
#
# Everything else (host, port, ctx size, sampling flags, etc.) you pass yourself.

set -euo pipefail

if [ "$#" -lt 1 ]; then
    echo "usage: $0 /path/to/model.gguf [extra llama-server flags...]" >&2
    echo "  example: $0 ~/models/Qwen3.6-35B.gguf --port 8080 -c 32768 -ngl 999" >&2
    exit 1
fi

if ! command -v podman >/dev/null 2>&1; then
    if command -v docker >/dev/null 2>&1; then
        RUNTIME=docker
    else
        echo "error: neither podman nor docker found" >&2
        exit 1
    fi
else
    RUNTIME=podman
fi

MODEL_FILE="$(realpath "$1")"
MODEL_DIR="$(dirname "${MODEL_FILE}")"
MODEL_BASENAME="$(basename "${MODEL_FILE}")"
shift

# Pick image. If BASE is set, use that. Otherwise, prefer fedora if both exist.
if [ -n "${BASE:-}" ]; then
    case "${BASE}" in
        fedora) IMAGE="llama-rocmfpx-strix:fedora-43" ;;
        ubuntu) IMAGE="llama-rocmfpx-strix:ubuntu-24.04" ;;
        *) echo "error: BASE must be 'fedora' or 'ubuntu' (got: ${BASE})" >&2; exit 1 ;;
    esac
elif "${RUNTIME}" image exists llama-rocmfpx-strix:fedora-43 2>/dev/null; then
    IMAGE="llama-rocmfpx-strix:fedora-43"
elif "${RUNTIME}" image exists llama-rocmfpx-strix:ubuntu-24.04 2>/dev/null; then
    IMAGE="llama-rocmfpx-strix:ubuntu-24.04"
else
    echo "error: no built image found. Run ./build.sh first." >&2
    exit 1
fi

echo "==> using image: ${IMAGE}"

"${RUNTIME}" run --rm -it \
    --device /dev/dri \
    --group-add keep-groups \
    --security-opt seccomp=unconfined \
    --network host \
    -v "${MODEL_DIR}:/models:ro" \
    "${IMAGE}" \
    -m "/models/${MODEL_BASENAME}" \
    "$@"
