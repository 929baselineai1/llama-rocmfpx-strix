#!/usr/bin/env bash
# Build Chadrock ROCmFP4 + MTP llama.cpp on this machine.
#
# This is the *host-native* build path. It does NOT use Docker/Podman — it
# installs system packages via dnf, clones ciru-ai/ROCmFPX, and runs the
# pinned build script from upstream.
#
# Why host-native instead of a container image:
#   - GitHub Actions free runners only have 16 GB RAM and 4 vCPU, which OOMs
#     during the Vulkan shader generation step. Strix Halo machines have
#     64-128 GB, so building directly on the target hardware is faster and
#     has no memory ceiling.
#   - ROCmFPX depends on the host's /dev/kfd and /dev/dri anyway. A
#     prebuilt image would have to ship kernel modules and exact-match ROCm
#     minor versions; building on-host avoids that mismatch.
#   - One command, one set of pinned versions. No container runtime needed.
#
# What this does (in order):
#   1. Detects OS (Fedora 43+ supported; Ubuntu/RHEL is a stretch goal).
#   2. Installs ROCm, Mesa Vulkan, SPIRV-Headers, and build tools via dnf.
#   3. Clones ciru-ai/ROCmFPX at the commit pinned by llm.ciru.ai/chadrock-
#      rocmfpx/ (currently 7aa484a2). Updating that page updates our build.
#   4. Runs scripts/build-strix-rocmfp4-mtp.sh with llama-server + llama-bench
#      targets. This produces ./build-strix-rocmfp4/bin/llama-server.
#   5. Symlinks the built binary into /usr/local/bin so `llama-server` works
#      from anywhere.
#
# Usage:
#   ./build.sh
#
# Idempotent: re-runs skip already-installed packages and reuse the cloned
# source tree. Safe to rerun after a `git pull` in the ROCmFPX checkout.
#
# Time on a fresh Strix Halo: ~30 min (10 min dnf + 20 min cold compile).
# Time on a warm ccache: ~5 min for incremental rebuilds.

set -euo pipefail

# Pinned to match llm.ciru.ai/chadrock-rocmfpx/ — when ciru-ai updates their
# site, update this hash.
ROCMFPX_REF="7aa484a2f0a504dc612a3d74a068024f3e6d6353"
ROCMFPX_REPO="https://github.com/ciru-ai/ROCmFPX.git"
ROCM_VERSION="7.2.2"

# Warm ccache download (set by --with-ccache). When set, the script downloads
# and extracts the pre-warmed cache before building, dropping cold-build
# time from ~30 min to ~10 min when the user's env matches the cache's
# fingerprint. See the v0.2.0-ccache1 release notes for what "matches" means.
CCACHE_TARBALL=""
CCACHE_RELEASE_URL="https://github.com/929baselineai1/llama-rocmfpx-strix/releases/download/v0.2.0-ccache1/ccache-warm.tar.xz"

# Parse args
while [ "$#" -gt 0 ]; do
    case "$1" in
        --with-ccache)
            # Next arg is local path; if absent, download from release
            if [ -n "${2:-}" ] && [ "${2:0:1}" != "-" ]; then
                CCACHE_TARBALL="$2"
                shift 2
            else
                CCACHE_TARBALL="__DOWNLOAD__"
                shift 1
            fi
            ;;
        --with-ccache=*)
            CCACHE_TARBALL="${1#*=}"
            shift 1
            ;;
        -h|--help)
            echo "usage: $0 [--with-ccache [path/to/ccache-warm.tar.xz]]"
            echo
            echo "  --with-ccache [path]"
            echo "      Pre-warm ccache before the build. With a path, use that local"
            echo "      tarball. Without a path, download from the v0.2.0-ccache1 release"
            echo "      (~560 MB; only worth it when your env matches the fingerprint in"
            echo "      the release notes)."
            exit 0
            ;;
        *)
            echo "error: unknown argument: $1" >&2
            echo "       pass --help for usage" >&2
            exit 1
            ;;
    esac
done

# ---- OS detection ----------------------------------------------------------

if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VERSION="${VERSION_ID:-unknown}"
else
    echo "error: cannot detect OS (no /etc/os-release)" >&2
    exit 1
fi

case "${OS_ID}" in
    fedora)
        if [ "${OS_VERSION%%.*}" -lt 43 ] 2>/dev/null; then
            echo "error: Fedora 43+ required (detected: ${OS_VERSION})" >&2
            exit 1
        fi
        ;;
    ubuntu)
        echo "warning: Ubuntu host build is untested. Use Fedora 43+ if possible." >&2
        ;;
    *)
        echo "error: unsupported OS: ${OS_ID} ${OS_VERSION}. Use Fedora 43+." >&2
        exit 1
        ;;
esac

echo "==> host:        ${OS_ID} ${OS_VERSION}"
echo "==> ROCmFPX ref: ${ROCMFPX_REF}"
echo "==> ROCm ver:    ${ROCM_VERSION}"

# ---- Step 0.5: validate --with-ccache arg BEFORE doing anything expensive ----

if [ -n "${CCACHE_TARBALL}" ]; then
    if [ "${CCACHE_TARBALL}" != "__DOWNLOAD__" ] && [ ! -s "${CCACHE_TARBALL}" ]; then
        echo "error: --with-ccache file not found: ${CCACHE_TARBALL}" >&2
        exit 1
    fi
    echo "==> ccache:     pre-warm enabled (downloads ~560 MB if no local path given)"
fi

# ---- Step 1: install system packages ---------------------------------------
# ROCm 7.2.2 lives in /opt/rocm-7.2.2 (AMD's official tarball layout). Mesa
# with gfx1151 Vulkan support comes from Fedora's standard repos for F43+.
# spirv-headers (Khronos) is in Fedora's repos as `spirv-headers`.

echo
echo "==> installing system packages (this may take ~10 min on a fresh host)"

if [ "${OS_ID}" = "fedora" ]; then
    # ROCm 7.2.2: AMD's official el10 repo serves Fedora 43. We pin the
    # repo to that version so future ROCm releases don't break our build.
    if [ ! -f /etc/yum.repos.d/ROCm-7.2.2.repo ]; then
        echo "    adding AMD ROCm 7.2.2 repo"
        sudo tee /etc/yum.repos.d/ROCm-7.2.2.repo >/dev/null <<EOF
[ROCm-${ROCM_VERSION}]
name=ROCm ${ROCM_VERSION} (el10)
baseurl=https://repo.radeon.com/rocm/rhel${ROCM_VERSION%%.*}/main/
enabled=1
priority=50
gpgcheck=0
EOF
    fi

    sudo dnf install -y \
        rocm-hip-devel \
        rocm-device-libs \
        vulkan-loader-devel \
        mesa-vulkan-drivers \
        vulkan-tools \
        spirv-headers-devel \
        cmake \
        ninja-build \
        clang \
        git \
        ccache

elif [ "${OS_ID}" = "ubuntu" ]; then
    sudo apt-get update
    sudo apt-get install -y \
        rocm-hip-sdk \
        mesa-vulkan-drivers \
        vulkan-tools \
        spirv-headers \
        cmake \
        ninja-build \
        clang \
        git \
        ccache
fi

# ---- Step 2: clone ROCmFPX ------------------------------------------------

ROCMFPX_DIR="${HOME}/ROCmFPX"
if [ ! -d "${ROCMFPX_DIR}" ]; then
    echo
    echo "==> cloning ciru-ai/ROCmFPX"
    git clone "${ROCMFPX_REPO}" "${ROCMFPX_DIR}"
fi

cd "${ROCMFPX_DIR}"

# Pin to the upstream-tested commit. `git fetch` and `git checkout` are
# idempotent — if we're already there, this is a no-op.
git fetch origin "${ROCMFPX_REF}" --depth=1 2>/dev/null || true
git checkout "${ROCMFPX_REF}"

# ---- Step 2.5: optional pre-warmed ccache ---------------------------------

if [ -n "${CCACHE_TARBALL}" ]; then
    echo
    echo "==> pre-warming ccache from ${CCACHE_TARBALL}"

    # Resolve the actual file: either a local path the user gave us, or
    # download from the GitHub release.
    if [ "${CCACHE_TARBALL}" = "__DOWNLOAD__" ]; then
        CCACHE_TARBALL="/tmp/ccache-warm.tar.xz"
        if [ ! -s "${CCACHE_TARBALL}" ]; then
            echo "    downloading ${CCACHE_RELEASE_URL}"
            if command -v curl >/dev/null 2>&1; then
                curl -fL --progress-bar -o "${CCACHE_TARBALL}" "${CCACHE_RELEASE_URL}" \
                    || { echo "error: download failed" >&2; exit 1; }
            elif command -v wget >/dev/null 2>&1; then
                wget -O "${CCACHE_TARBALL}" "${CCACHE_RELEASE_URL}" \
                    || { echo "error: download failed" >&2; exit 1; }
            else
                echo "error: neither curl nor wget found; install one and rerun" >&2
                exit 1
            fi
        else
            echo "    using existing ${CCACHE_TARBALL}"
        fi
    fi

    # ccache defaults to ~/.cache/ccache; respect $CCACHE_DIR if set.
    CCACHE_TARGET_DIR="${CCACHE_DIR:-${HOME}/.cache/ccache}"
    mkdir -p "${CCACHE_TARGET_DIR}"

    echo "    extracting to ${CCACHE_TARGET_DIR}"
    tar -xJf "${CCACHE_TARBALL}" -C "${HOME}" \
        || { echo "error: extraction failed" >&2; exit 1; }

    # Quick sanity check: ccache sees N entries
    if CCACHE_DIR="${CCACHE_TARGET_DIR}" ccache -s >/dev/null 2>&1; then
        CCACHE_HITS=$(CCACHE_DIR="${CCACHE_TARGET_DIR}" ccache -s 2>/dev/null | awk '/Hits:/{print $2; exit}')
        echo "    pre-warmed cache: ${CCACHE_HITS:-?} hits available"
        echo "    (hit rate depends on your env matching the cache fingerprint;"
        echo "     see the v0.2.0-ccache1 release notes)"
    else
        echo "    warning: could not query cache stats (may be empty or corrupt)"
    fi
fi

# ---- Step 3: build llama-server + llama-bench -----------------------------

echo
echo "==> running ciru-ai's pinned build script (this is the long step)"
echo "    first build: ~20 min cold. warm ccache: ~5 min."

# The upstream script uses /home/caf/strix-fp4 by default for rocWMMA
# headers; we don't have those (we're not using rocWMMA), so the script's
# missing-dir check is fine and the build proceeds without them.
# GGML_HIP_ROCWMMA_FATTN=OFF is the default — we don't need rocWMMA for the
# Chadrock inference path.

env JOBS="$(nproc)" \
    scripts/build-strix-rocmfp4-mtp.sh llama-server llama-bench

BUILD_DIR="${ROCMFPX_DIR}/build-strix-rocmfp4"
SERVER_BIN="${BUILD_DIR}/bin/llama-server"

if [ ! -x "${SERVER_BIN}" ]; then
    echo "error: build did not produce ${SERVER_BIN}" >&2
    exit 1
fi

# ---- Step 4: install to /usr/local/bin ------------------------------------

echo
echo "==> installing llama-server to /usr/local/bin"
sudo install -m 0755 "${SERVER_BIN}" /usr/local/bin/llama-server
sudo install -m 0755 "${BUILD_DIR}/bin/llama-bench" /usr/local/bin/llama-bench 2>/dev/null || true

# ---- done ------------------------------------------------------------------

echo
echo "==> build complete"
echo "    binary:     /usr/local/bin/llama-server"
echo "    source dir: ${ROCMFPX_DIR} (kept around so ./run.sh can cd into it)"
echo
echo "    verify:     llama-server --version"
echo "    next step:  ./run.sh /path/to/chadrock-model.gguf"