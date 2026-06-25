#!/bin/sh
# Strix Halo runtime overrides for llama-server.
#
# These are the universal env vars every Strix Halo user wants. Model-specific
# flags (path, ctx, sampling) come from $@ so the image stays generic.
#
# Why each variable:
#   HSA_OVERRIDE_GFX_VERSION=11.5.1
#       ROCm 7.2.2 sometimes misIDs the 8060S as gfx1100. Forcing RDNA3.5
#       (11.5.1) ensures the right code paths and kernel compilation.
#
#   RADV_PERFTEST=gpl
#       Opt-in Mesa RADV "graphics pipeline library" path. Off by default
#       upstream because it's still flagged experimental. Major throughput
#       win on RDNA3+. We've validated it at 140 tok/s on the 35B.
#
#   GGML_HIP_ENABLE_UNIFIED_MEMORY=1
#       Strix Halo: CPU and GPU share the same physical memory (unified mem
#       architecture, no separate VRAM). Without this flag, llama.cpp uses
#       explicit hipMemcpy() calls between CPU/GPU buffers. With it, both
#       sides just read/write the same pointer. Roughly doubles throughput.
#
#   LD_PRELOAD=...libvulkan_radeon.so
#   VK_DRIVER_FILES=...radeon_icd.x86_64.json
#       The Ubuntu base ships Mesa's RADV in /usr/lib/. We installed a newer
#       Mesa to /opt/mesa-26.1.3/. Two RADVs can't coexist -- the system one
#       would win by default. These two force the Vulkan loader to use ours:
#         LD_PRELOAD makes libvulkan_radeon.so load before the system's.
#         VK_DRIVER_FILES points the ICD manifest at our install path.
#       We preserve any existing LD_PRELOAD (e.g. for debuggers) by appending
#       our lib with ":" separator.

set -eu

# Compose LD_PRELOAD carefully: append our lib, preserve any existing preload
OUR_VK_LIB="/opt/mesa-26.1.3/lib64/libvulkan_radeon.so"
if [ -n "${LD_PRELOAD:-}" ]; then
    export LD_PRELOAD="${OUR_VK_LIB}:${LD_PRELOAD}"
else
    export LD_PRELOAD="${OUR_VK_LIB}"
fi

# Point Vulkan loader at our ICD manifest, overriding the system one
export VK_DRIVER_FILES="/opt/mesa-26.1.3/share/vulkan/icd.d/radeon_icd.x86_64.json"

# ROCm / RADV unified memory + perf flags
export HSA_OVERRIDE_GFX_VERSION=11.5.1
export RADV_PERFTEST=gpl
export GGML_HIP_ENABLE_UNIFIED_MEMORY=1

# Make sure the engine's libs are discoverable (ROCmFPX installs to /opt/llama.cpp
# which isn't on the default ldconfig path)
export LD_LIBRARY_PATH="/opt/llama.cpp/lib64:${LD_LIBRARY_PATH:-}"

# Where the binary lives
#   Fedora Containerfile:  /usr/local/bin/llama-server
#   Ubuntu Containerfile:  /opt/llama.cpp/bin/llama-server
LLAMA_SERVER=""
for candidate in \
    /opt/llama.cpp/bin/llama-server \
    /usr/local/bin/llama-server; do
    if [ -x "${candidate}" ]; then
        LLAMA_SERVER="${candidate}"
        break
    fi
done

if [ -z "${LLAMA_SERVER}" ]; then
    echo "entrypoint: llama-server not found in expected locations" >&2
    echo "entrypoint:   /opt/llama.cpp/bin/llama-server  (Ubuntu Containerfile)" >&2
    echo "entrypoint:   /usr/local/bin/llama-server      (Fedora Containerfile)" >&2
    echo "entrypoint: the image build may have failed at the ROCmFPX layer" >&2
    exit 1
fi

# Print effective config for debugging (one line, easy to grep in logs)
echo "entrypoint: ${LLAMA_SERVER} $*"
exec "${LLAMA_SERVER}" "$@"