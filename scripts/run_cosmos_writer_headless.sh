#!/usr/bin/env bash

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
IMAGE="${IMAGE:-nvcr.io/nvidia/isaac-sim:6.0.1}"
RESULT_DIR="${RESULT_DIR:-$REPO_ROOT/output/T5-A-cosmos-headless}"
PYTHON_SCRIPT="${PYTHON_SCRIPT:-$REPO_ROOT/tests/cosmos_writer_simple_headless.py}"
REFERENCE_SCRIPT="${REFERENCE_SCRIPT:-$REPO_ROOT/tests/cosmos_writer_reference.py}"
VALIDATOR_SCRIPT="${VALIDATOR_SCRIPT:-$REPO_ROOT/tests/validate_cosmos_output.py}"
CONTAINER_NAME="${CONTAINER_NAME:-isaacsim601-t5-cosmos-headless}"
TEST_ID="${TEST_ID:-T5-A}"
SOURCE_MODE="${SOURCE_MODE:-headless}"
EXECUTION_SURFACE="${EXECUTION_SURFACE:-standalone headless}"
SCRIPT_EVIDENCE_NAME="${SCRIPT_EVIDENCE_NAME:-cosmos_writer_simple_headless.py}"
STARTUP_WATCHDOG_SECONDS="${STARTUP_WATCHDOG_SECONDS:-420}"
NO_PROGRESS_SECONDS="${NO_PROGRESS_SECONDS:-240}"
WRITER_DRAIN_TIMEOUT_SECONDS="${WRITER_DRAIN_TIMEOUT_SECONDS:-360}"
OVERALL_TIMEOUT_SECONDS="${OVERALL_TIMEOUT_SECONDS:-1800}"
SHUTDOWN_GRACE_SECONDS="${SHUTDOWN_GRACE_SECONDS:-60}"

RUNTIME_DIR="$RESULT_DIR/runtime"
KIT_LOG_DIR="$RUNTIME_DIR/kit_logs"
WORK_DIR="$RESULT_DIR/workdir"
OUTPUT_DIR="$WORK_DIR/_out_cosmos_simple"
RUN_LOG="$RESULT_DIR/run_stdout_stderr.log"
TELEMETRY_PID=""
PMON_PID=""
DOCKER_RUN_PID=""
STOP_REASON=""

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

container_running() {
    [[ -n "$(docker ps --quiet --filter "name=^/${CONTAINER_NAME}$" 2>/dev/null)" ]]
}

capture_watchdog_state() {
    local reason="$1"
    printf '%s\n' "$reason" > "$RESULT_DIR/watchdog_status.txt"
    docker inspect "$CONTAINER_NAME" > "$RESULT_DIR/watchdog_container_inspect.json" 2>&1 || true
    docker top "$CONTAINER_NAME" -eo pid,ppid,user,stat,etime,pcpu,pmem,args \
        > "$RESULT_DIR/watchdog_container_top.txt" 2>&1 || true
    nvidia-smi -q > "$RESULT_DIR/watchdog_nvidia_smi.txt" 2>&1 || true
    nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv \
        > "$RESULT_DIR/watchdog_gpu_processes.csv" 2>&1 || true
}

stop_workload_container() {
    local reason="$1"
    STOP_REASON="$reason"
    capture_watchdog_state "$reason"
    if container_running; then
        docker stop --timeout 20 "$CONTAINER_NAME" > "$RESULT_DIR/watchdog_docker_stop.txt" 2>&1 || true
    fi
}

cleanup() {
    stop_telemetry
    if container_running; then
        docker stop --timeout 10 "$CONTAINER_NAME" >/dev/null 2>&1 || true
    fi
}

trap cleanup EXIT INT TERM

if [[ -n "$(docker ps -a --quiet --filter "name=^/${CONTAINER_NAME}$" 2>/dev/null)" ]]; then
    printf 'Refusing to reuse existing container name: %s\n' "$CONTAINER_NAME" >&2
    exit 2
fi

mkdir -p \
    "$RESULT_DIR" \
    "$WORK_DIR" \
    "$RUNTIME_DIR/cache/main" \
    "$RUNTIME_DIR/cache/computecache" \
    "$RUNTIME_DIR/config" \
    "$RUNTIME_DIR/data" \
    "$RUNTIME_DIR/logs" \
    "$RUNTIME_DIR/pkg" \
    "$RUNTIME_DIR/hub" \
    "$KIT_LOG_DIR"
chmod -R a+rwX "$RESULT_DIR"

case "$SOURCE_MODE" in
    headless)
        if ! sed 's/SimulationApp(launch_config={"headless": False})/SimulationApp(launch_config={"headless": True})/' \
            "$REFERENCE_SCRIPT" | cmp -s - "$PYTHON_SCRIPT"; then
            printf 'Headless test source differs from the NVIDIA reference by more than the approved launch flag.\n' >&2
            exit 2
        fi
        set +e
        diff -u "$REFERENCE_SCRIPT" "$PYTHON_SCRIPT" > "$RESULT_DIR/headless_only.patch"
        DIFF_RC=$?
        if [[ "$DIFF_RC" -ne 1 ]]; then
            printf 'Expected exactly one source diff, diff exit code was %s.\n' "$DIFF_RC" >&2
            exit 2
        fi
        ;;
    official)
        if ! cmp -s "$REFERENCE_SCRIPT" "$PYTHON_SCRIPT"; then
            printf 'Official-control source is not byte-identical to the preserved NVIDIA reference.\n' >&2
            exit 2
        fi
        printf '%s\n' "BYTE_IDENTICAL_TO_PRESERVED_NVIDIA_REFERENCE" > "$RESULT_DIR/source_identity.txt"
        ;;
    *)
        printf 'Unknown SOURCE_MODE: %s\n' "$SOURCE_MODE" >&2
        exit 2
        ;;
esac

STARTED_AT="$(date --utc --iso-8601=seconds)"
STARTED_JOURNAL="$(date --utc '+%Y-%m-%d %H:%M:%S UTC')"
START_EPOCH="$(date +%s)"
printf '%s\n' "$STARTED_AT" > "$RESULT_DIR/started_at_utc.txt"
printf '%s\n' "$IMAGE" > "$RESULT_DIR/image_reference.txt"
printf '%s\n' "$CONTAINER_NAME" > "$RESULT_DIR/container_name.txt"
printf 'test_id=%s\nsource_mode=%s\nexecution_surface=%s\nframes=60\nwidth=1280\nheight=720\nmodalities=rgb,shaded_seg,segmentation,depth,edges\nstartup_watchdog_seconds=%s\nno_progress_seconds=%s\nwriter_drain_timeout_seconds=%s\noverall_timeout_seconds=%s\nshutdown_grace_seconds=%s\n' \
    "$TEST_ID" "$SOURCE_MODE" "$EXECUTION_SURFACE" \
    "$STARTUP_WATCHDOG_SECONDS" "$NO_PROGRESS_SECONDS" "$WRITER_DRAIN_TIMEOUT_SECONDS" \
    "$OVERALL_TIMEOUT_SECONDS" "$SHUTDOWN_GRACE_SECONDS" \
    > "$RESULT_DIR/workload_parameters.txt"
printf 'timestamp_utc,frame\n' > "$RESULT_DIR/progress.csv"

docker image inspect "$IMAGE" > "$RESULT_DIR/image_inspect.json"
docker ps --no-trunc > "$RESULT_DIR/containers_before.txt"
nvidia-smi -q > "$RESULT_DIR/nvidia_smi_pre.txt"
nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv \
    > "$RESULT_DIR/gpu_processes_pre.csv"

nvidia-smi \
    --query-gpu=timestamp,index,name,pstate,utilization.gpu,utilization.memory,utilization.encoder,utilization.decoder,memory.used,memory.total,power.draw,temperature.gpu,clocks.sm,clocks.mem \
    --format=csv --loop=1 > "$RESULT_DIR/gpu_telemetry.csv" 2>&1 &
TELEMETRY_PID=$!
nvidia-smi pmon -s um -d 1 > "$RESULT_DIR/gpu_process_telemetry.txt" 2>&1 &
PMON_PID=$!

printf 'T5_RUN_START id=%s source_mode=%s image=%s frames=60 resolution=1280x720\n' \
    "$TEST_ID" "$SOURCE_MODE" "$IMAGE"
docker run --rm \
    --name "$CONTAINER_NAME" \
    --device=nvidia.com/gpu=all \
    --user 1234:1234 \
    --workdir /results/workdir \
    -e ACCEPT_EULA=Y \
    -e NVIDIA_VISIBLE_DEVICES=all \
    -e NVIDIA_DRIVER_CAPABILITIES=all \
    -e PYTHONUNBUFFERED=1 \
    -v "$PYTHON_SCRIPT:/workspace/cosmos_writer_test.py:ro" \
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
    -lc '/isaac-sim/python.sh /workspace/cosmos_writer_test.py --test' \
    > >(tee "$RUN_LOG") 2>&1 &
DOCKER_RUN_PID=$!

LAST_FRAME=0
LAST_PROGRESS_EPOCH="$START_EPOCH"
PASS_MARKER_EPOCH=0
FAIL_MARKER_EPOCH=0
while kill -0 "$DOCKER_RUN_PID" 2>/dev/null; do
    NOW_EPOCH="$(date +%s)"
    CURRENT_FRAME="$(grep -oE 'Frame [0-9]+/60' "$RUN_LOG" 2>/dev/null | tail -1 | grep -oE '[0-9]+' | head -1)"
    CURRENT_FRAME="${CURRENT_FRAME:-0}"
    if (( CURRENT_FRAME > LAST_FRAME )); then
        LAST_FRAME="$CURRENT_FRAME"
        LAST_PROGRESS_EPOCH="$NOW_EPOCH"
        printf '%s,%s\n' "$(date --utc --iso-8601=seconds)" "$LAST_FRAME" >> "$RESULT_DIR/progress.csv"
        printf 'T5_PROGRESS frame=%s/60\n' "$LAST_FRAME"
    fi

    if (( PASS_MARKER_EPOCH == 0 )) && grep -Fq '[SDG][Test][PASS]' "$RUN_LOG" 2>/dev/null; then
        PASS_MARKER_EPOCH="$NOW_EPOCH"
        printf '%s\n' "$(date --utc --iso-8601=seconds)" > "$RESULT_DIR/builtin_pass_marker_at_utc.txt"
        printf 'T5_BUILTIN_VALIDATION_PASS\n'
    fi
    if (( FAIL_MARKER_EPOCH == 0 )) && grep -Fq '[SDG][Test][FAIL]' "$RUN_LOG" 2>/dev/null; then
        FAIL_MARKER_EPOCH="$NOW_EPOCH"
        printf '%s\n' "$(date --utc --iso-8601=seconds)" > "$RESULT_DIR/builtin_fail_marker_at_utc.txt"
        printf 'T5_BUILTIN_VALIDATION_FAIL\n'
    fi

    if (( PASS_MARKER_EPOCH > 0 && NOW_EPOCH - PASS_MARKER_EPOCH >= SHUTDOWN_GRACE_SECONDS )); then
        stop_workload_container "POST_PASS_KIT_SHUTDOWN_EXCEEDED_${SHUTDOWN_GRACE_SECONDS}s"
        break
    fi
    if (( FAIL_MARKER_EPOCH > 0 && NOW_EPOCH - FAIL_MARKER_EPOCH >= 30 )); then
        stop_workload_container "POST_FAIL_KIT_SHUTDOWN_EXCEEDED_30s"
        break
    fi
    if (( LAST_FRAME == 0 && NOW_EPOCH - START_EPOCH >= STARTUP_WATCHDOG_SECONDS )); then
        stop_workload_container "STARTUP_NO_FRAME_EXCEEDED_${STARTUP_WATCHDOG_SECONDS}s"
        break
    fi
    if (( LAST_FRAME > 0 && LAST_FRAME < 60 && NOW_EPOCH - LAST_PROGRESS_EPOCH >= NO_PROGRESS_SECONDS )); then
        stop_workload_container "FRAME_NO_PROGRESS_EXCEEDED_${NO_PROGRESS_SECONDS}s_AT_${LAST_FRAME}"
        break
    fi
    if (( LAST_FRAME >= 60 && NOW_EPOCH - LAST_PROGRESS_EPOCH >= WRITER_DRAIN_TIMEOUT_SECONDS )); then
        stop_workload_container "WRITER_DRAIN_EXCEEDED_${WRITER_DRAIN_TIMEOUT_SECONDS}s"
        break
    fi
    if (( NOW_EPOCH - START_EPOCH >= OVERALL_TIMEOUT_SECONDS )); then
        stop_workload_container "OVERALL_TIMEOUT_EXCEEDED_${OVERALL_TIMEOUT_SECONDS}s"
        break
    fi
    sleep 5
done

set +e
wait "$DOCKER_RUN_PID"
DOCKER_RUN_RC=$?
DOCKER_RUN_PID=""
printf '%s\n' "$DOCKER_RUN_RC" > "$RESULT_DIR/docker_run_exit_code.txt"
printf '%s\n' "${STOP_REASON:-NONE}" > "$RESULT_DIR/stop_reason.txt"

stop_telemetry
TELEMETRY_PID=""
PMON_PID=""

FINISHED_AT="$(date --utc --iso-8601=seconds)"
FINISHED_JOURNAL="$(date --utc '+%Y-%m-%d %H:%M:%S UTC')"
printf '%s\n' "$FINISHED_AT" > "$RESULT_DIR/finished_at_utc.txt"
nvidia-smi -q > "$RESULT_DIR/nvidia_smi_post.txt"
nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv \
    > "$RESULT_DIR/gpu_processes_post.csv"
journalctl --dmesg --since "$STARTED_JOURNAL" --until "$FINISHED_JOURNAL" --no-pager \
    > "$RESULT_DIR/kernel_events_during_run.txt" 2>&1 || true

printf 'T5_OUTPUT_VALIDATION_START\n'
set +e
docker run --rm \
    --user 1234:1234 \
    -v "$VALIDATOR_SCRIPT:/workspace/validate_cosmos_output.py:ro" \
    -v "$RESULT_DIR:/results:rw" \
    --entrypoint bash \
    "$IMAGE" \
    -lc '/isaac-sim/python.sh /workspace/validate_cosmos_output.py --output-root /results/workdir/_out_cosmos_simple --result /results/output_validation.json' \
    2>&1 | tee "$RESULT_DIR/output_validation.log"
VALIDATION_RC=${PIPESTATUS[0]}
printf '%s\n' "$VALIDATION_RC" > "$RESULT_DIR/output_validation_exit_code.txt"

docker ps --no-trunc > "$RESULT_DIR/containers_after.txt"
cp "$PYTHON_SCRIPT" "$RESULT_DIR/$SCRIPT_EVIDENCE_NAME"
cp "$VALIDATOR_SCRIPT" "$RESULT_DIR/validate_cosmos_output.py"
cp "$0" "$RESULT_DIR/run_cosmos_writer_evidence.sh"

SIGNATURES='error 719|cudaErrorLaunchFailure|PhysX Internal CUDA error|illegal memory access|CUDA context validation failed|GPU solver pipeline failed|GPU Bp pipeline failed|CosmosWriter skipped video encoding|Hardware encoding failed|Traceback \(most recent call last\)|Timed out while waiting for pending Replicator writer schedules|Timed out waiting for async writer'
set +e
rg --line-number --ignore-case "$SIGNATURES" "$RUN_LOG" "$KIT_LOG_DIR" \
    > "$RESULT_DIR/negative_signature_scan.txt"
SIGNATURE_SCAN_RC=$?
rg --line-number --ignore-case 'NVRM: Xid|Xid \(' "$RESULT_DIR/kernel_events_during_run.txt" \
    > "$RESULT_DIR/kernel_xid_scan.txt"
XID_SCAN_RC=$?

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

BUILTIN_STATUS="MISSING"
if grep -Fq '[SDG][Test][PASS]' "$RUN_LOG"; then
    BUILTIN_STATUS="PASS"
elif grep -Fq '[SDG][Test][FAIL]' "$RUN_LOG"; then
    BUILTIN_STATUS="FAIL"
fi
VALIDATOR_STATUS="MISSING"
if [[ -s "$RESULT_DIR/output_validation.json" ]]; then
    VALIDATOR_STATUS="$(jq -r '.status // "UNKNOWN"' "$RESULT_DIR/output_validation.json")"
fi
FINAL_STATUS="FAIL"
OVERALL_RC=1
if [[ "$BUILTIN_STATUS" == "PASS" && "$VALIDATOR_STATUS" == "PASS" ]]; then
    FINAL_STATUS="PASS"
    OVERALL_RC=0
fi
LIFECYCLE_STATUS="NATIVE_EXIT"
if [[ "$STOP_REASON" == POST_PASS_KIT_SHUTDOWN_EXCEEDED_* ]]; then
    LIFECYCLE_STATUS="POST_WORKLOAD_SHUTDOWN_TIMEOUT"
fi

jq -n \
    --arg status "$FINAL_STATUS" \
    --arg builtin_status "$BUILTIN_STATUS" \
    --arg validator_status "$VALIDATOR_STATUS" \
    --arg lifecycle_status "$LIFECYCLE_STATUS" \
    --arg stop_reason "${STOP_REASON:-NONE}" \
    --arg started_at "$STARTED_AT" \
    --arg finished_at "$FINISHED_AT" \
    --arg test_id "$TEST_ID" \
    --arg execution_surface "$EXECUTION_SURFACE" \
    --arg source_mode "$SOURCE_MODE" \
    --argjson docker_exit_code "$DOCKER_RUN_RC" \
    --argjson validator_exit_code "$VALIDATION_RC" \
    '{
        test_id: $test_id,
        execution_surface: $execution_surface,
        source_mode: $source_mode,
        status: $status,
        builtin_validation: $builtin_status,
        independent_validation: $validator_status,
        lifecycle_status: $lifecycle_status,
        stop_reason: $stop_reason,
        docker_exit_code: $docker_exit_code,
        validator_exit_code: $validator_exit_code,
        started_at_utc: $started_at,
        finished_at_utc: $finished_at,
        expected: {frames: 60, png_files: 300, mp4_files: 5, width: 1280, height: 720}
    }' > "$RESULT_DIR/result.json"
printf '%s\n' "$OVERALL_RC" > "$RESULT_DIR/overall_exit_code.txt"
printf 'T5_RUN_COMPLETE id=%s status=%s builtin=%s independent=%s lifecycle=%s\n' \
    "$TEST_ID" "$FINAL_STATUS" "$BUILTIN_STATUS" "$VALIDATOR_STATUS" "$LIFECYCLE_STATUS"

exit "$OVERALL_RC"
