#!/usr/bin/env bash

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
IMAGE="${IMAGE:-nvcr.io/nvidia/isaac-sim:6.0.1}"
RESULT_DIR="${RESULT_DIR:-$REPO_ROOT/output/T2-gpu-physx-smoke}"
PYTHON_SCRIPT="${PYTHON_SCRIPT:-$REPO_ROOT/tests/gpu_physx_smoke.py}"
BODIES="${BODIES:-1024}"
STEPS="${STEPS:-600}"
SEED="${SEED:-20260720}"
SHUTDOWN_MODE="${SHUTDOWN_MODE:-process-exit}"
CONTAINER_NAME="${CONTAINER_NAME:-isaacsim601-gpu-physx-smoke}"

RUNTIME_DIR="$RESULT_DIR/runtime"
KIT_LOG_DIR="$RUNTIME_DIR/kit_logs"
RUN_LOG="$RESULT_DIR/run_stdout_stderr.log"
RESULT_JSON="$RESULT_DIR/result.json"
TELEMETRY_PID=""
PMON_PID=""

stop_telemetry() {
    if [[ -n "$TELEMETRY_PID" ]]; then
        kill "$TELEMETRY_PID" 2>/dev/null || true
        wait "$TELEMETRY_PID" 2>/dev/null || true
    fi
    if [[ -n "$PMON_PID" ]]; then
        kill "$PMON_PID" 2>/dev/null || true
        wait "$PMON_PID" 2>/dev/null || true
    fi
}

trap stop_telemetry EXIT INT TERM

mkdir -p \
    "$RUNTIME_DIR/cache/main" \
    "$RUNTIME_DIR/cache/computecache" \
    "$RUNTIME_DIR/config" \
    "$RUNTIME_DIR/data" \
    "$RUNTIME_DIR/logs" \
    "$RUNTIME_DIR/pkg" \
    "$RUNTIME_DIR/hub" \
    "$KIT_LOG_DIR"
chmod a+rwx \
    "$RESULT_DIR" \
    "$RUNTIME_DIR" \
    "$RUNTIME_DIR/cache" \
    "$RUNTIME_DIR/cache/main" \
    "$RUNTIME_DIR/cache/computecache" \
    "$RUNTIME_DIR/config" \
    "$RUNTIME_DIR/data" \
    "$RUNTIME_DIR/logs" \
    "$RUNTIME_DIR/pkg" \
    "$RUNTIME_DIR/hub" \
    "$KIT_LOG_DIR"

STARTED_AT="$(date --utc --iso-8601=seconds)"
STARTED_JOURNAL="$(date --utc '+%Y-%m-%d %H:%M:%S UTC')"
printf '%s\n' "$STARTED_AT" > "$RESULT_DIR/started_at_utc.txt"
printf '%s\n' "$IMAGE" > "$RESULT_DIR/image_reference.txt"
printf 'bodies=%s\nsteps=%s\nseed=%s\nshutdown_mode=%s\n' \
    "$BODIES" "$STEPS" "$SEED" "$SHUTDOWN_MODE" \
    > "$RESULT_DIR/workload_parameters.txt"
docker image inspect "$IMAGE" > "$RESULT_DIR/image_inspect.json"
docker ps --no-trunc > "$RESULT_DIR/containers_before.txt"
nvidia-smi -q > "$RESULT_DIR/nvidia_smi_pre.txt"
nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv \
    > "$RESULT_DIR/gpu_processes_pre.csv"

nvidia-smi \
    --query-gpu=timestamp,index,name,pstate,utilization.gpu,utilization.memory,utilization.encoder,utilization.decoder,memory.used,memory.total,power.draw,temperature.gpu,clocks.sm,clocks.mem \
    --format=csv \
    --loop=1 > "$RESULT_DIR/gpu_telemetry.csv" 2>&1 &
TELEMETRY_PID=$!

nvidia-smi pmon -s um -d 1 > "$RESULT_DIR/gpu_process_telemetry.txt" 2>&1 &
PMON_PID=$!

set +e
docker run --rm \
    --name "$CONTAINER_NAME" \
    --device=nvidia.com/gpu=all \
    --user 1234:1234 \
    -e ACCEPT_EULA=Y \
    -e NVIDIA_VISIBLE_DEVICES=all \
    -v "$PYTHON_SCRIPT:/workspace/gpu_physx_smoke.py:ro" \
    -v "$RESULT_DIR:/results:rw" \
    -v "$RUNTIME_DIR/cache/main:/isaac-sim/.cache:rw" \
    -v "$RUNTIME_DIR/cache/computecache:/isaac-sim/.nv/ComputeCache:rw" \
    -v "$RUNTIME_DIR/config:/isaac-sim/.nvidia-omniverse/config:rw" \
    -v "$RUNTIME_DIR/data:/isaac-sim/.local/share/ov/data:rw" \
    -v "$RUNTIME_DIR/logs:/isaac-sim/.nvidia-omniverse/logs:rw" \
    -v "$RUNTIME_DIR/pkg:/isaac-sim/.local/share/ov/pkg:rw" \
    -v "$RUNTIME_DIR/hub:/var/cache/hub:rw" \
    -v "$KIT_LOG_DIR:/isaac-sim/kit/logs:rw" \
    --entrypoint bash \
    "$IMAGE" \
    -lc "./python.sh /workspace/gpu_physx_smoke.py --bodies $BODIES --steps $STEPS --seed $SEED --shutdown-mode $SHUTDOWN_MODE --output /results/result.json" \
    2>&1 | tee "$RUN_LOG"
RUN_RC=${PIPESTATUS[0]}
set -e

stop_telemetry
TELEMETRY_PID=""
PMON_PID=""

FINISHED_AT="$(date --utc --iso-8601=seconds)"
FINISHED_JOURNAL="$(date --utc '+%Y-%m-%d %H:%M:%S UTC')"
printf '%s\n' "$FINISHED_AT" > "$RESULT_DIR/finished_at_utc.txt"
printf '%s\n' "$RUN_RC" > "$RESULT_DIR/docker_run_exit_code.txt"
docker ps --no-trunc > "$RESULT_DIR/containers_after.txt"
nvidia-smi -q > "$RESULT_DIR/nvidia_smi_post.txt"
nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv \
    > "$RESULT_DIR/gpu_processes_post.csv"
journalctl --dmesg --since "$STARTED_JOURNAL" --until "$FINISHED_JOURNAL" --no-pager \
    > "$RESULT_DIR/kernel_events_during_run.txt" 2>&1 || true

cp "$PYTHON_SCRIPT" "$RESULT_DIR/gpu_physx_smoke.py"
cp "$0" "$RESULT_DIR/run_gpu_physx_smoke.sh"

SIGNATURES='error 719|cudaErrorLaunchFailure|PhysX Internal CUDA error|illegal memory access|CUDA context validation failed|switching to software|GPU solver pipeline failed|GPU Bp pipeline failed'
set +e
rg --line-number --ignore-case "$SIGNATURES" "$RUN_LOG" "$KIT_LOG_DIR" \
    > "$RESULT_DIR/negative_signature_scan.txt"
SIGNATURE_SCAN_RC=$?
rg --line-number --ignore-case 'NVRM: Xid|Xid \(' "$RESULT_DIR/kernel_events_during_run.txt" \
    > "$RESULT_DIR/kernel_xid_scan.txt"
XID_SCAN_RC=$?
set -e

case "$SIGNATURE_SCAN_RC" in
    0) printf '%s\n' "MATCHES_FOUND" > "$RESULT_DIR/negative_signature_scan_status.txt" ;;
    1) printf '%s\n' "NO_MATCHES" > "$RESULT_DIR/negative_signature_scan_status.txt" ;;
    *) printf 'SCAN_ERROR_%s\n' "$SIGNATURE_SCAN_RC" > "$RESULT_DIR/negative_signature_scan_status.txt" ;;
esac

case "$XID_SCAN_RC" in
    0) printf '%s\n' "MATCHES_FOUND" > "$RESULT_DIR/kernel_xid_scan_status.txt" ;;
    1) printf '%s\n' "NO_MATCHES" > "$RESULT_DIR/kernel_xid_scan_status.txt" ;;
    *) printf 'SCAN_ERROR_%s\n' "$XID_SCAN_RC" > "$RESULT_DIR/kernel_xid_scan_status.txt" ;;
esac

if [[ ! -s "$RESULT_JSON" ]]; then
    printf '%s\n' "Result JSON was not created." >&2
    exit 3
fi

exit "$RUN_RC"
