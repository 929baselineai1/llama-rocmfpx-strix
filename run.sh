#!/usr/bin/env bash
# Launch llama-server with the Chadrock ROCmFP4 + MTP flags from
# llm.ciru.ai/chadrock-rocmfpx/. Picks the model size based on the GGUF
# filename so you don't have to remember which config applies.
#
# Usage:
#   ./run.sh /path/to/chadrock-model.gguf [extra llama-server flags...]
#
# The binary built by ./build.sh lives in ~/ROCmFPX/build-strix-rocmfp4/bin/.
# We invoke it directly so we can run from any working directory.
#
# Flag sources: llm.ciru.ai/chadrock-rocmfpx/ llama-configs section.
#   - 35B ACE/SABER ROCmFP4: n_max=4, ctx=32768, ctk=f16, ctv=f16
#   - Qwable 5 27B ROCmFP4:   n_max=6, ctx=131072, ctk=q8_0, ctv=q8_0

set -euo pipefail

if [ "$#" -lt 1 ]; then
    echo "usage: $0 /path/to/chadrock-model.gguf [extra llama-server flags...]" >&2
    echo
    echo "  example:"
    echo "    ./run.sh ~/models/qwable-5-27b-chadrock-v2-rocmfp4.gguf"
    echo "    ./run.sh ~/models/chadrock-35b-ace-saber-rocmfp4-mtp.gguf --port 8081"
    exit 1
fi

MODEL_FILE="$(realpath "$1")"
if [ ! -f "${MODEL_FILE}" ]; then
    echo "error: model file not found: ${MODEL_FILE}" >&2
    exit 1
fi
shift

# Default port. Override by passing --port N as an extra flag.
PORT="${PORT:-8080}"

SERVER_BIN="${HOME}/ROCmFPX/build-strix-rocmfp4/bin/llama-server"
if [ ! -x "${SERVER_BIN}" ]; then
    echo "error: llama-server not built. Run ./build.sh first." >&2
    exit 1
fi

# Pick the config based on the model filename. The two known Chadrock
# families are 35B ACE/SABER (smaller ctx, tighter MTP cap) and Qwable 5 27B
# (huge ctx, looser MTP cap). If neither matches, fall back to the 27B
# defaults — they're more permissive and will at least start.
MODEL_NAME="$(basename "${MODEL_FILE}")"
case "${MODEL_NAME}" in
    *35B*ace-saber*|*35B*ACE-SABER*|*35B-ACE-SABER*)
        echo "==> detected 35B ACE/SABER model — using n_max=4, ctx=32768, ctk=f16"
        N_MAX=4
        CTX=32768
        CTK="f16"
        CTV="f16"
        ;;
    *qwable*|*Qwable*|*Qwable-5*|*27B*)
        echo "==> detected 27B-class model — using n_max=6, ctx=131072, ctk=q8_0"
        N_MAX=6
        CTX=131072
        CTK="q8_0"
        CTV="q8_0"
        ;;
    *)
        echo "warning: unrecognized model name '${MODEL_NAME}'"
        echo "         falling back to 27B defaults (n_max=6, ctx=131072, ctk=q8_0)"
        echo "         pass --n-max, -c, -ctk manually to override"
        N_MAX=6
        CTX=131072
        CTK="q8_0"
        CTV="q8_0"
        ;;
esac

echo "==> server:  ${SERVER_BIN}"
echo "==> model:   ${MODEL_FILE}"
echo "==> host:    0.0.0.0:${PORT}  (override with --port N as an extra flag)"
echo

exec "${SERVER_BIN}" \
    -m "${MODEL_FILE}" \
    --host 0.0.0.0 \
    --port "${PORT}" \
    --jinja \
    -c "${CTX}" \
    --reasoning off \
    --reasoning-format none \
    --reasoning-budget -1 \
    --no-context-shift \
    -dev Vulkan0 \
    -ngl 999 \
    -fa on \
    -b 2048 \
    -ub 512 \
    -t 16 \
    -tb 32 \
    -ctk "${CTK}" \
    -ctv "${CTV}" \
    --temp 0 \
    --top-p 0.95 \
    --top-k 20 \
    --seed 123 \
    --parallel 1 \
    --no-mmproj \
    --metrics \
    --no-webui \
    --slot-prompt-similarity 0.0 \
    --spec-type draft-mtp \
    --spec-draft-device Vulkan0 \
    --spec-draft-ngl all \
    --spec-draft-threads 16 \
    --spec-draft-threads-batch 32 \
    --spec-draft-type-k f16 \
    --spec-draft-type-v f16 \
    --spec-draft-n-max "${N_MAX}" \
    --spec-draft-n-min 0 \
    --spec-draft-p-min 0.0 \
    --spec-draft-p-split 0.20 \
    --no-spec-draft-backend-sampling \
    --spec-draft-poll 1 \
    --spec-draft-poll-batch 1 \
    "$@"