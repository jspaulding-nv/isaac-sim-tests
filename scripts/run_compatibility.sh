#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
IMAGE="${IMAGE:-nvcr.io/nvidia/isaac-sim:6.0.1}"
RESULT_DIR="${RESULT_DIR:-$REPO_ROOT/output/T1-compatibility}"

mkdir -p "$RESULT_DIR"
docker image inspect "$IMAGE" > "$RESULT_DIR/image-inspect.json"

set +e
docker run \
    --name isaacsim-tests-compatibility \
    --entrypoint bash \
    --rm \
    --network=host \
    --device=nvidia.com/gpu=all \
    -e ACCEPT_EULA=Y \
    "$IMAGE" \
    ./isaac-sim.compatibility_check.sh --/app/quitAfter=10 --no-window \
    2>&1 | tee "$RESULT_DIR/compatibility.log"
rc=${PIPESTATUS[0]}
set -e

printf '%s\n' "$rc" > "$RESULT_DIR/exit-code.txt"
exit "$rc"
