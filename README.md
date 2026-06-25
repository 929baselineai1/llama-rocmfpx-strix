# llama-rocmfpx-strix

ROCmFPX (`ciru-ai/ROCmFPX` — llama.cpp fork with ROCmFP4) packaged for **AMD Strix Halo** (Radeon 8060S, RDNA 3.5, `gfx1151`). Ships Mesa 26.1.3 RADV with `RADV_PERFTEST=gpl` for full RDNA3+ performance.

Two bases provided — pick the one that matches your host:

| File | Base | When to use |
|---|---|---|
| **`Containerfile.fedora`** | `fedora:43` | Fedora/RHEL hosts. Mirrors the working M5 host build exactly (clang 21, LLVM 21, meson 1.8). First-try success. |
| **`Containerfile.ubuntu`** | `rocm/dev-ubuntu-24.04:7.2.2` | Ubuntu/Debian hosts. More common as a container base, but Mesa source build needs extra deps (`libpolly-18-dev libisl-dev`). |

No "auto-detect" logic. Pick the file at build time, that's it.

## Quick start

```bash
# Pull from Docker Hub
podman pull baselineai/llama-rocmfpx-strix:fedora-43

# Run
podman run --rm -it \
    --device /dev/dri \
    --group-add keep-groups \
    --security-opt seccomp=unconfined \
    -v ~/.cache/huggingface:/root/.cache/huggingface \
    -p 8080:8080 \
    baselineai/llama-rocmfpx-strix:fedora-43 \
    --model <model.gguf> --port 8080
```

The `entrypoint.sh` sets the 5 Strix Halo env vars (`HSA_OVERRIDE_GFX_VERSION`, `RADV_PERFTEST=gpl`, `GGML_HIP_ENABLE_UNIFIED_MEMORY=1`, `LD_PRELOAD=libvulkan_radeon.so`, `VK_DRIVER_FILES=…`) before execing `llama-server`.

## Build locally

```bash
git clone https://github.com/baselineai/llama-rocmfpx-strix
cd llama-rocmfpx-strix

# Fedora
podman build -t llama-rocmfpx-strix:fedora-43 -f Containerfile.fedora .

# Ubuntu
podman build -t llama-rocmfpx-strix:ubuntu-24.04 -f Containerfile.ubuntu .
```

## What this image gives you

- **ROCmFPX** — `ciru-ai/ROCmFPX` (llama.cpp fork with ROCmFP4 + MTP speculative decoding). Built from `main`.
- **Mesa 26.1.3 RADV** — built from source with the exact flags used on the working M5 host. Static-LLVM link, Wayland-only platform, no GL/GLX/GBM.
- **Strix Halo tuned** — `gfx1151` baked in, unified memory enabled, `RADV_PERFTEST=gpl` for the RDNA3+ perf library.
- **~1.5 GB** image (Fedora) or **~1.8 GB** (Ubuntu, due to ROCm dev base).

## Verified performance

On the M5 host (Radeon 8060S, Fedora 43, Mesa 26.1.3, ROCm 7.2.2, ROCmFPX main): **~140 tok/s** on Qwen3.5-27B Q4_K_M. Container build reproduces the same flags; runtime throughput should match.

## Files in this repo

```
Containerfile.fedora      # Fedora 43 base, ~1.5 GB image
Containerfile.ubuntu      # Ubuntu 24.04 base, ~1.8 GB image
entrypoint.sh             # Strix Halo env vars + exec llama-server
docker-bake.hcl           # Multi-tag build definitions for buildx/bake
.github/workflows/build.yml  # CI: build + push to Docker Hub on tag
```

## CI / publishing

Tagged as:
- `baselineai/llama-rocmfpx-strix:fedora-43`
- `baselineai/llama-rocmfpx-strix:ubuntu-24.04`
- `baselineai/llama-rocmfpx-strix:latest` (alias to fedora-43, the verified path)

## Credits

- `ciru-ai/ROCmFPX` — the engine
- Mesa RADV — `RADV_PERFTEST=gpl` is a Mesa-only opt-in that lights up the RDNA3+ graphics pipeline library
- AMD ROCm 7.2.2 — `gfx1151` support landed in 7.0+

## Post-mortems (why this took longer than expected)

Four build failures in the original Ubuntu attempt, all captured:
1. [meson 1.3.2 < 1.4.0 required](Knowledge/post-mortems/2026-06-26-container-meson-version-mismatch.md)
2. [mako/yaml Python modules missing](Knowledge/post-mortems/2026-06-26-container-mesa-missing-mako-yaml.md)
3. [bison/flex required for gallium build](Knowledge/post-mortems/2026-06-26-container-mesa-missing-bison-flex.md)
4. [Polly link error and strategy pivot](Knowledge/post-mortems/2026-06-26-container-polly-link-error-and-strategy-pivot.md)

The Fedora path avoids all four because the host's `meson 1.8.5` and LLVM 21 don't trip the same checks. **Lesson: when a build fails 3+ times in a row, the build environment is the problem, not the next dep.**
