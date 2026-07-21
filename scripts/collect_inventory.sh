#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
RESULT_DIR="${RESULT_DIR:-$REPO_ROOT/output/T0-inventory}"

mkdir -p "$RESULT_DIR"

capture() {
    local name="$1"
    shift
    {
        printf 'Started: %s\n' "$(date --utc --iso-8601=seconds)"
        printf 'Command:'
        printf ' %q' "$@"
        printf '\n\n'
        "$@"
    } > "$RESULT_DIR/$name.txt" 2>&1
}

capture time date --utc --iso-8601=seconds
capture os bash -lc 'uname -sr; cat /etc/os-release'
capture cpu_memory bash -lc 'lscpu; free -h; getconf _NPROCESSORS_ONLN'
capture storage df -hT "$REPO_ROOT" /tmp
capture gpu_summary nvidia-smi
capture gpu_csv nvidia-smi \
    --query-gpu=timestamp,name,driver_version,memory.total,memory.used,memory.free,compute_cap,pstate,compute_mode,display_active,display_mode,mig.mode.current \
    --format=csv
capture gpu_idle nvidia-smi dmon -c 1
capture container_runtime bash -lc \
    'docker version; docker info --format "Server={{.ServerVersion}} DefaultRuntime={{.DefaultRuntime}} Runtimes={{json .Runtimes}}"'
capture toolkit_versions bash -lc \
    'nvidia-container-cli --version 2>/dev/null || true; nvidia-ctk --version 2>/dev/null || true'
capture video_capabilities bash -lc \
    'command -v ffmpeg || true; ffmpeg -hide_banner -encoders 2>/dev/null | rg -i "nvenc|cuda" || true'
capture python bash -lc 'python3 --version; python3 -m pip --version 2>/dev/null || true'

printf '%s\n' "$(date --utc --iso-8601=seconds)" > "$RESULT_DIR/COLLECTION_COMPLETE"
printf 'Privacy-safe inventory written to %s\n' "$RESULT_DIR"
printf 'Do not publish additional raw system logs without reviewing docs/privacy.md.\n'
