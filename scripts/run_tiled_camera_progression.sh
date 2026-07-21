#!/usr/bin/env bash

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
IMAGE="${IMAGE:-nvcr.io/nvidia/isaac-sim:6.0.1}"
RESULT_DIR="${RESULT_DIR:-$REPO_ROOT/output/T4-tiled-camera}"
PYTHON_SCRIPT="${PYTHON_SCRIPT:-$REPO_ROOT/tests/tiled_camera_progression.py}"
SEED="${SEED:-20260721}"
WATCHDOG_SECONDS="${WATCHDOG_SECONDS:-120}"
STARTUP_WATCHDOG_SECONDS="${STARTUP_WATCHDOG_SECONDS:-420}"
STAGE_TIMEOUT_SECONDS="${STAGE_TIMEOUT_SECONDS:-900}"
CONTAINER_PREFIX="${CONTAINER_PREFIX:-isaacsim601-t4}"

STAGES=(
    "T4-A_single_control single 1 240 320 120"
    "T4-B_tiled_1 tiled 1 240 320 120"
    "T4-C_tiled_16 tiled 16 240 320 300"
    "T4-D_tiled_64 tiled 64 240 320 300"
    "T4-E_tiled_64_high_res tiled 64 480 640 120"
)

RUNTIME_DIR="$RESULT_DIR/runtime"
KIT_LOG_DIR="$RUNTIME_DIR/kit_logs"
TELEMETRY_PID=""
PMON_PID=""
OVERALL_RC=0

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
    "$RESULT_DIR" \
    "$RUNTIME_DIR/cache/main" \
    "$RUNTIME_DIR/cache/computecache" \
    "$RUNTIME_DIR/config" \
    "$RUNTIME_DIR/data" \
    "$RUNTIME_DIR/logs" \
    "$RUNTIME_DIR/pkg" \
    "$RUNTIME_DIR/hub" \
    "$KIT_LOG_DIR"
chmod -R a+rwX "$RESULT_DIR"

STARTED_AT="$(date --utc --iso-8601=seconds)"
STARTED_JOURNAL="$(date --utc '+%Y-%m-%d %H:%M:%S UTC')"
printf '%s\n' "$STARTED_AT" > "$RESULT_DIR/started_at_utc.txt"
printf '%s\n' "$IMAGE" > "$RESULT_DIR/image_reference.txt"
printf 'seed=%s\nwatchdog_seconds=%s\nstartup_watchdog_seconds=%s\nstage_timeout_seconds=%s\n' \
    "$SEED" "$WATCHDOG_SECONDS" "$STARTUP_WATCHDOG_SECONDS" "$STAGE_TIMEOUT_SECONDS" \
    > "$RESULT_DIR/workload_parameters.txt"
printf 'stage_id,mode,cameras,height,width,frames\n' > "$RESULT_DIR/stage_matrix.csv"
printf 'stage_id,docker_exit_code,result_status\n' > "$RESULT_DIR/stage_exit_codes.csv"
for stage in "${STAGES[@]}"; do
    read -r stage_id mode cameras height width frames <<< "$stage"
    printf '%s,%s,%s,%s,%s,%s\n' "$stage_id" "$mode" "$cameras" "$height" "$width" "$frames" \
        >> "$RESULT_DIR/stage_matrix.csv"
done

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

for stage in "${STAGES[@]}"; do
    read -r stage_id mode cameras height width frames <<< "$stage"
    stage_dir="$RESULT_DIR/$stage_id"
    mkdir -p "$stage_dir"
    chmod a+rwx "$stage_dir"
    container_name="${CONTAINER_PREFIX}-$(printf '%s' "$stage_id" | tr '[:upper:]_' '[:lower:]-')-$$"
    printf '%s\n' "$(date --utc --iso-8601=seconds)" > "$stage_dir/started_at_utc.txt"
    printf '%s\n' "$container_name" > "$stage_dir/container_name.txt"
    printf 'T4_STAGE_START id=%s mode=%s cameras=%s resolution=%sx%s frames=%s\n' \
        "$stage_id" "$mode" "$cameras" "$width" "$height" "$frames"

    set +e
    timeout --foreground --signal=TERM --kill-after=30s "$STAGE_TIMEOUT_SECONDS" \
        docker run --rm \
        --name "$container_name" \
        --device=nvidia.com/gpu=all \
        --user 1234:1234 \
        -e ACCEPT_EULA=Y \
        -e NVIDIA_VISIBLE_DEVICES=all \
        -v "$PYTHON_SCRIPT:/workspace/tiled_camera_progression.py:ro" \
        -v "$stage_dir:/results:rw" \
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
        -lc "./python.sh /workspace/tiled_camera_progression.py --stage-id $stage_id --mode $mode --cameras $cameras --height $height --width $width --frames $frames --seed $SEED --watchdog-seconds $WATCHDOG_SECONDS --startup-watchdog-seconds $STARTUP_WATCHDOG_SECONDS --output-dir /results" \
        2>&1 | tee "$stage_dir/run_stdout_stderr.log"
    run_rc=${PIPESTATUS[0]}
    set -e

    printf '%s\n' "$run_rc" > "$stage_dir/docker_run_exit_code.txt"
    printf '%s\n' "$(date --utc --iso-8601=seconds)" > "$stage_dir/finished_at_utc.txt"
    if [[ "$run_rc" -eq 124 || "$run_rc" -eq 137 ]]; then
        printf 'OVERALL_TIMEOUT exit_code=%s\n' "$run_rc" > "$stage_dir/watchdog_status.txt"
    elif [[ -s "$stage_dir/result.json" ]]; then
        printf '%s\n' "INTERNAL_NO_PROGRESS_WATCHDOG_ARMED_${WATCHDOG_SECONDS}s" > "$stage_dir/watchdog_status.txt"
    else
        printf '%s\n' "NO_RESULT_JSON" > "$stage_dir/watchdog_status.txt"
    fi

    result_status="MISSING"
    if [[ -s "$stage_dir/result.json" ]]; then
        result_status="$(sed -n 's/^[[:space:]]*"status": "\([A-Z]*\)",*$/\1/p' "$stage_dir/result.json" | head -1)"
        [[ -n "$result_status" ]] || result_status="UNKNOWN"
    fi
    printf '%s,%s,%s\n' "$stage_id" "$run_rc" "$result_status" >> "$RESULT_DIR/stage_exit_codes.csv"
    printf 'T4_STAGE_END id=%s exit_code=%s result=%s\n' "$stage_id" "$run_rc" "$result_status"

    if [[ "$run_rc" -ne 0 || "$result_status" != "PASS" ]]; then
        OVERALL_RC=1
        printf 'Incremental stop after %s because exit_code=%s and result=%s.\n' \
            "$stage_id" "$run_rc" "$result_status" > "$RESULT_DIR/incremental_stop.txt"
        break
    fi
done

stop_telemetry
TELEMETRY_PID=""
PMON_PID=""

FINISHED_AT="$(date --utc --iso-8601=seconds)"
FINISHED_JOURNAL="$(date --utc '+%Y-%m-%d %H:%M:%S UTC')"
printf '%s\n' "$FINISHED_AT" > "$RESULT_DIR/finished_at_utc.txt"
printf '%s\n' "$OVERALL_RC" > "$RESULT_DIR/overall_exit_code.txt"
docker ps --no-trunc > "$RESULT_DIR/containers_after.txt"
nvidia-smi -q > "$RESULT_DIR/nvidia_smi_post.txt"
nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv \
    > "$RESULT_DIR/gpu_processes_post.csv"
journalctl --dmesg --since "$STARTED_JOURNAL" --until "$FINISHED_JOURNAL" --no-pager \
    > "$RESULT_DIR/kernel_events_during_run.txt" 2>&1 || true

cp "$PYTHON_SCRIPT" "$RESULT_DIR/tiled_camera_progression.py"
cp "$0" "$RESULT_DIR/run_tiled_camera_evidence.sh"

SIGNATURES='error 719|cudaErrorLaunchFailure|PhysX Internal CUDA error|illegal memory access|CUDA context validation failed|switching to software|GPU solver pipeline failed|GPU Bp pipeline failed|Warp.*(error|failed)|CUDA.*(error|failed)|Traceback \(most recent call last\)'
set +e
rg --line-number --ignore-case "$SIGNATURES" "$RESULT_DIR"/*/run_stdout_stderr.log "$KIT_LOG_DIR" \
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

exit "$OVERALL_RC"
