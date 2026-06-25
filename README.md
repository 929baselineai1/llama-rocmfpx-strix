# llama-rocmfpx-strix

Build ciru-ai/ROCmFPX (llama.cpp fork with ROCmFP4 + MTP speculative
decoding) directly on your **AMD Strix Halo** machine, then run it with the
exact flags from [llm.ciru.ai/chadrock-rocmfpx](https://llm.ciru.ai/chadrock-rocmfpx/).

One command to build, one command to run. No Docker. No GitHub Actions
runner chasing memory limits. Works on Fedora 43+ hosts.

## Quick start

```bash
git clone https://github.com/929baselineai1/llama-rocmfpx-strix
cd llama-rocmfpx-strix

# Build llama-server (10 min on a fresh host, ~5 min with warm ccache)
./build.sh

# Run with a Chadrock model
./run.sh ~/models/Qwable-5-27B-Chadrock-v2-ROCmFP4.gguf
```

That's it. `llama-server` listens on `:8080`. Open it in a browser or hit
the OpenAI-compatible API at `http://localhost:8080/v1/`.

## Why host-native?

The README on [llm.ciru.ai/chadrock-rocmfpx](https://llm.ciru.ai/chadrock-rocmfpx/)
gives you three commands:

```bash
git clone https://github.com/ciru-ai/ROCmFPX.git
cd ROCmFPX
git checkout 7aa484a2f0a504dc612a3d74a068024f3e6d6353
env JOBS=16 scripts/build-strix-rocmfp4-mtp.sh llama-server llama-bench
```

What that page **silently assumes** you've already done:

- ROCm 7.2.2 installed at `/opt/rocm-7.2.2`
- Mesa with `gfx1151` Vulkan support compiled/installed
- SPIRV-Headers at `/usr/include/spirv/`
- Build tools (cmake, ninja, clang, ccache)
- Clang able to find ROCm device libs

If you walk up to a fresh Strix Halo and run those three commands without
that pre-installed, the build fails at the cmake stage with cryptic errors
about missing `spv::Header`, `amdgcn-target`, or no HIP runtime.

**`./build.sh` does the homework that page assumes you've done.** It installs
the system packages, clones ROCmFPX at the exact pinned commit, and runs
ciru-ai's actual build script. One file, ~30 min on a fresh machine, ~5 min
on a warm ccache.

## What `./build.sh` does

1. **Detects OS** — Fedora 43+ verified; Ubuntu 24.04 supported but untested.
2. **Installs system packages** via `dnf`:
   - `rocm-hip-devel rocm-device-libs` (AMD's official ROCm 7.2.2 repo)
   - `vulkan-loader-devel mesa-vulkan-drivers vulkan-tools`
   - `spirv-headers-devel`
   - `cmake ninja-build clang git ccache wget`
3. **Clones `ciru-ai/ROCmFPX`** at the commit pinned by
   [llm.ciru.ai](https://llm.ciru.ai/chadrock-rocmfpx/) (currently
   `7aa484a2f0a504dc612a3d74a068024f3e6d6353`). Idempotent — if the dir
   already exists, just fetches the latest and checks out the pinned ref.
4. **Runs the upstream build script** —
   `env JOBS=$(nproc) scripts/build-strix-rocmfp4-mtp.sh llama-server llama-bench`.
   This produces `~/ROCmFPX/build-strix-rocmfp4/bin/llama-server`.
5. **Installs the binary** to `/usr/local/bin/llama-server`.

The build dir is **kept around** (`~/ROCmFPX/`) because incremental rebuilds
reuse it. Re-running `./build.sh` after a `git pull` only takes a few minutes.

## What `./run.sh` does

1. **Detects the model family** from the filename:
   - `*35B*ace-saber*` or `*35B-ACE-SABER*` → 35B config (n_max=4, ctx=32768, ctk=f16)
   - `*qwable*`, `*Qwable*`, or `*27B*` → 27B config (n_max=6, ctx=131072, ctk=q8_0)
   - Fallback: 27B defaults (more permissive — server will at least start)
2. **Launches `llama-server`** with the Chadrock MTP flags straight from
   the ciru-ai page. Override any of them by passing extra flags:
   ```bash
   ./run.sh ~/models/qwable-5-27b-chadrock-v2-rocmfp4.gguf --port 8081
   PORT=18080 ./run.sh ~/models/qwable-5-27b-chadrock-v2-rocmfp4.gguf
   ```

## Requirements

- **Hardware**: AMD Strix Halo (Radeon 8060S / 8050S, RDNA 3.5, `gfx1151`).
  The 128GB / 96GB / 64GB unified-memory variants all work; the build
  succeeds on 64GB+ but the model GGUF may exceed VRAM on 64GB.
- **OS**: Fedora 43+ verified. Ubuntu 24.04 should work but isn't tested.
- **Disk**: ~5 GB for source tree + ~2.5 GB for `llama-server` binary.
- **RAM**: 16 GB minimum for the build (parallel glslc is hungry);
  32 GB recommended for cold builds, 64 GB+ for warm ccache.

## Updating to a newer ROCmFPX

[llm.ciru.ai/chadrock-rocmfpx](https://llm.ciru.ai/chadrock-rocmfpx/) is the
source of truth for the pinned commit. When that page updates:

1. Edit `ROCMFPX_REF` at the top of `build.sh`.
2. Re-run `./build.sh`. It will fetch the new ref and rebuild.

That's it. `run.sh` doesn't need to change — the ciru-ai script generates
the binary the same way regardless of upstream tag.

## Files in this repo

```
build.sh           # One-shot host-native ROCmFPX builder (~100 lines)
run.sh             # llama-server launcher with Chadrock MTP flags (~120 lines)
Containerfile.*    # Optional: prebuilt-image path (see "Container alternative" below)
entrypoint.sh      # Strix Halo env vars (used by Containerfile, harmless otherwise)
.github/workflows/ # CI for the optional container path
```

## Container alternative

`Containerfile.fedora` and `Containerfile.ubuntu` are still in the repo for
users who prefer a prebuilt image. They build a `podman build`-style
container that includes everything. **These build on GitHub Actions runners,
which only have 16 GB RAM and 4 vCPU — that's why our CI kept OOMing.**
The host-native `build.sh` path avoids that constraint.

If you want the prebuilt-image path anyway (CI, deployment, etc.):

```bash
podman build -t llama-rocmfpx-strix:fedora-43 -f Containerfile.fedora .
podman run --rm -it \
    --device /dev/dri \
    --group-add video --group-add render \
    --security-opt seccomp=unconfined \
    -v /path/to/models:/models:ro \
    -p 8080:8080 \
    llama-rocmfpx-strix:fedora-43 \
    -m /models/<your-model>.gguf --port 8080 --host 0.0.0.0 -ngl 999
```

## Verified performance

M5 host (Radeon 8060S, Fedora 43, Mesa 26.1.3, ROCm 7.2.2, ROCmFPX
`7aa484a2`): ~140 tok/s on Qwen3.5-27B Q4_K_M with MTP enabled (n_max=4).
The host-native `build.sh` reproduces the exact flags that hit that
number; `./run.sh` matches ciru-ai's verified launch flags.

## Credits

- `ciru-ai/ROCmFPX` — the engine, and the source of the build script we wrap
- Mesa RADV — `RADV_PERFTEST=gpl` (set by `entrypoint.sh` for the container
  path; host builds inherit it from the system Mesa config)
- AMD ROCm 7.2.2 — `gfx1151` support landed in 7.0+