#!/usr/bin/env bash

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
DEPLOYMENT_DIR="$REPO_ROOT/deploy"
RESULT_DIR="${RESULT_DIR:-$REPO_ROOT/output/T5-C-cosmos-full-streaming}"
OUTPUT_DIR="$RESULT_DIR/workdir/_out_cosmos_simple"
IMAGE="${IMAGE:-nvcr.io/nvidia/isaac-sim:6.0.1}"
COMPOSE_PROJECT="${COMPOSE_PROJECT:-isaacsim-tests}"
CONTAINER_NAME="${CONTAINER_NAME:-${COMPOSE_PROJECT}-isaac-sim-1}"
PYTHON_SCRIPT="$REPO_ROOT/tests/cosmos_writer_streaming.py"
VALIDATOR_SCRIPT="$REPO_ROOT/tests/validate_cosmos_output.py"
BASE_COMPOSE="$DEPLOYMENT_DIR/docker-compose.yml"
OVERRIDE_COMPOSE="$DEPLOYMENT_DIR/docker-compose.cosmos-streaming.yml"
ENV_FILE="$DEPLOYMENT_DIR/.env"
export T5C_RESULT_DIR="$RESULT_DIR"
STARTUP_WATCHDOG_SECONDS="${STARTUP_WATCHDOG_SECONDS:-600}"
NO_PROGRESS_SECONDS="${NO_PROGRESS_SECONDS:-360}"
WRITER_DRAIN_TIMEOUT_SECONDS="${WRITER_DRAIN_TIMEOUT_SECONDS:-600}"
OVERALL_TIMEOUT_SECONDS="${OVERALL_TIMEOUT_SECONDS:-2400}"

RUNNER_LOG="$RESULT_DIR/runner.log"
APP_LOG="$RESULT_DIR/app_stdout_stderr.log"
TELEMETRY_PID=""
PMON_PID=""
LOG_PID=""
STOP_REASON="NONE"

stop_background_jobs() {
    for pid in "$TELEMETRY_PID" "$PMON_PID" "$LOG_PID"; do
        if [[ -n "$pid" ]]; then
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        fi
    done
}

capture_watchdog_state() {
    local reason="$1"
    printf '%s\n' "$reason" > "$RESULT_DIR/watchdog_status.txt"
    docker inspect "$CONTAINER_NAME" > "$RESULT_DIR/watchdog_container_inspect.json" 2>&1 || true
    docker top "$CONTAINER_NAME" -eo pid,ppid,user,stat,etime,pcpu,pmem,args \
        > "$RESULT_DIR/watchdog_container_top.txt" 2>&1 || true
    nvidia-smi -q > "$RESULT_DIR/watchdog_nvidia_smi.txt" 2>&1 || true
}

trap stop_background_jobs EXIT INT TERM

if [[ ! -f "$ENV_FILE" ]]; then
    printf 'Missing %s. Copy deploy/.env.example to deploy/.env first.\n' "$ENV_FILE" >&2
    exit 2
fi

if [[ -e "$RESULT_DIR" ]]; then
    printf 'Refusing to overwrite existing T5-C evidence: %s\n' "$RESULT_DIR" >&2
    exit 2
fi

SCRIPT_MODE="$(stat -c '%a' "$PYTHON_SCRIPT")"
SCRIPT_OTHER_MODE="${SCRIPT_MODE: -1}"
if (( (8#$SCRIPT_OTHER_MODE & 4) == 0 )); then
    printf 'T5-C script must be world-readable for container UID 1234; current mode is %s.\n' "$SCRIPT_MODE" >&2
    exit 2
fi

mkdir -p "$RESULT_DIR/workdir"
chmod -R a+rwX "$RESULT_DIR"
exec > >(tee "$RUNNER_LOG") 2>&1

STARTED_AT="$(date --utc --iso-8601=seconds)"
STARTED_JOURNAL="$(date --utc '+%Y-%m-%d %H:%M:%S UTC')"
START_EPOCH="$(date +%s)"
LAST_PROGRESS_EPOCH="$START_EPOCH"
LAST_FRAME=0
DRAIN_STARTED_EPOCH=0
printf '%s\n' "$STARTED_AT" > "$RESULT_DIR/started_at_utc.txt"
printf '%s\n' "$IMAGE" > "$RESULT_DIR/image_reference.txt"
printf 'test_id=T5-C\nexecution_surface=Isaac Sim Full Streaming App\nframes=60\nwidth=1280\nheight=720\nmodalities=rgb,shaded_seg,segmentation,depth,edges\nstartup_watchdog_seconds=%s\nno_progress_seconds=%s\nwriter_drain_timeout_seconds=%s\noverall_timeout_seconds=%s\n' \
    "$STARTUP_WATCHDOG_SECONDS" "$NO_PROGRESS_SECONDS" "$WRITER_DRAIN_TIMEOUT_SECONDS" \
    "$OVERALL_TIMEOUT_SECONDS" > "$RESULT_DIR/workload_parameters.txt"
printf 'timestamp_utc,frame\n' > "$RESULT_DIR/progress.csv"

docker image inspect "$IMAGE" > "$RESULT_DIR/image_inspect.json"
docker compose --env-file "$ENV_FILE" -p "$COMPOSE_PROJECT" -f "$BASE_COMPOSE" ps -a \
    > "$RESULT_DIR/containers_before.txt"
nvidia-smi -q > "$RESULT_DIR/nvidia_smi_pre.txt"
nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv \
    > "$RESULT_DIR/gpu_processes_pre.csv"

nvidia-smi \
    --query-gpu=timestamp,index,name,pstate,utilization.gpu,utilization.memory,utilization.encoder,utilization.decoder,memory.used,memory.total,power.draw,temperature.gpu,clocks.sm,clocks.mem \
    --format=csv --loop=1 > "$RESULT_DIR/gpu_telemetry.csv" 2>&1 &
TELEMETRY_PID=$!
nvidia-smi pmon -s um -d 1 > "$RESULT_DIR/gpu_process_telemetry.txt" 2>&1 &
PMON_PID=$!

printf 'T5C_LAUNCH image=%s frames=60 resolution=1280x720\n' "$IMAGE"
docker compose \
    --env-file "$ENV_FILE" \
    -p "$COMPOSE_PROJECT" \
    -f "$BASE_COMPOSE" \
    -f "$OVERRIDE_COMPOSE" \
    up -d --no-deps --force-recreate isaac-sim \
    > "$RESULT_DIR/compose_up.txt" 2>&1
COMPOSE_RC=$?
printf '%s\n' "$COMPOSE_RC" > "$RESULT_DIR/compose_up_exit_code.txt"
if (( COMPOSE_RC != 0 )); then
    STOP_REASON="COMPOSE_UP_FAILED"
    capture_watchdog_state "$STOP_REASON"
fi

if (( COMPOSE_RC == 0 )); then
    docker logs --follow --since "$STARTED_AT" "$CONTAINER_NAME" > "$APP_LOG" 2>&1 &
    LOG_PID=$!

    while true; do
        NOW_EPOCH="$(date +%s)"
        CURRENT_FRAME="$(grep -oE 'T5C_FRAME_COMPLETE frame=[0-9]+/60' "$APP_LOG" 2>/dev/null | tail -1 | grep -oE '[0-9]+/60' | cut -d/ -f1)"
        CURRENT_FRAME="${CURRENT_FRAME:-0}"
        if (( CURRENT_FRAME > LAST_FRAME )); then
            LAST_FRAME="$CURRENT_FRAME"
            LAST_PROGRESS_EPOCH="$NOW_EPOCH"
            printf '%s,%s\n' "$(date --utc --iso-8601=seconds)" "$LAST_FRAME" >> "$RESULT_DIR/progress.csv"
            printf 'T5C_PROGRESS frame=%s/60\n' "$LAST_FRAME"
        fi

        if (( DRAIN_STARTED_EPOCH == 0 )) && grep -Fq 'T5C_WRITER_DRAIN_STARTED' "$APP_LOG" 2>/dev/null; then
            DRAIN_STARTED_EPOCH="$NOW_EPOCH"
            printf '%s\n' "$(date --utc --iso-8601=seconds)" > "$RESULT_DIR/writer_drain_started_at_utc.txt"
            printf 'T5C_WRITER_DRAIN_OBSERVED\n'
        fi
        if grep -Fq 'T5C_RUN_COMPLETE' "$APP_LOG" 2>/dev/null; then
            printf 'T5C_COMPLETION_MARKER_OBSERVED\n'
            break
        fi
        if grep -Fq 'T5C_RUN_FAIL' "$APP_LOG" 2>/dev/null; then
            STOP_REASON="WORKLOAD_REPORTED_FAILURE"
            printf 'T5C_FAILURE_MARKER_OBSERVED\n'
            break
        fi
        if ! docker inspect --format '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null | grep -Fxq true; then
            STOP_REASON="STREAMING_CONTAINER_EXITED"
            break
        fi
        if (( LAST_FRAME == 0 && NOW_EPOCH - START_EPOCH >= STARTUP_WATCHDOG_SECONDS )); then
            STOP_REASON="STARTUP_NO_FRAME_EXCEEDED_${STARTUP_WATCHDOG_SECONDS}s"
            capture_watchdog_state "$STOP_REASON"
            break
        fi
        if (( LAST_FRAME > 0 && LAST_FRAME < 60 && NOW_EPOCH - LAST_PROGRESS_EPOCH >= NO_PROGRESS_SECONDS )); then
            STOP_REASON="FRAME_NO_PROGRESS_EXCEEDED_${NO_PROGRESS_SECONDS}s_AT_${LAST_FRAME}"
            capture_watchdog_state "$STOP_REASON"
            break
        fi
        if (( DRAIN_STARTED_EPOCH > 0 && NOW_EPOCH - DRAIN_STARTED_EPOCH >= WRITER_DRAIN_TIMEOUT_SECONDS )); then
            STOP_REASON="WRITER_DRAIN_EXCEEDED_${WRITER_DRAIN_TIMEOUT_SECONDS}s"
            capture_watchdog_state "$STOP_REASON"
            break
        fi
        if (( NOW_EPOCH - START_EPOCH >= OVERALL_TIMEOUT_SECONDS )); then
            STOP_REASON="OVERALL_TIMEOUT_EXCEEDED_${OVERALL_TIMEOUT_SECONDS}s"
            capture_watchdog_state "$STOP_REASON"
            break
        fi
        sleep 5
    done
fi

stop_background_jobs
TELEMETRY_PID=""
PMON_PID=""
LOG_PID=""
docker logs --since "$STARTED_AT" "$CONTAINER_NAME" > "$APP_LOG" 2>&1 || true

FINISHED_AT="$(date --utc --iso-8601=seconds)"
FINISHED_JOURNAL="$(date --utc '+%Y-%m-%d %H:%M:%S UTC')"
printf '%s\n' "$FINISHED_AT" > "$RESULT_DIR/finished_at_utc.txt"
printf '%s\n' "$STOP_REASON" > "$RESULT_DIR/stop_reason.txt"
docker compose --env-file "$ENV_FILE" -p "$COMPOSE_PROJECT" -f "$BASE_COMPOSE" -f "$OVERRIDE_COMPOSE" ps -a \
    > "$RESULT_DIR/containers_after.txt" 2>&1 || true
docker inspect "$CONTAINER_NAME" > "$RESULT_DIR/container_inspect.json" 2>&1 || true
docker top "$CONTAINER_NAME" -eo pid,ppid,user,stat,etime,pcpu,pmem,args \
    > "$RESULT_DIR/container_top.txt" 2>&1 || true
nvidia-smi -q > "$RESULT_DIR/nvidia_smi_post.txt"
nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv \
    > "$RESULT_DIR/gpu_processes_post.csv"
journalctl --dmesg --since "$STARTED_JOURNAL" --until "$FINISHED_JOURNAL" --no-pager \
    > "$RESULT_DIR/kernel_events_during_run.txt" 2>&1 || true

KIT_LOG_PATH="$(docker exec "$CONTAINER_NAME" sh -lc 'ls -t /isaac-sim/.nvidia-omniverse/logs/Kit/*/*/kit_*.log 2>/dev/null | head -1' 2>/dev/null)"
if [[ -n "$KIT_LOG_PATH" ]]; then
    printf '%s\n' "$KIT_LOG_PATH" > "$RESULT_DIR/kit_log_path.txt"
    docker cp "$CONTAINER_NAME:$KIT_LOG_PATH" "$RESULT_DIR/kit.log" > "$RESULT_DIR/docker_cp_kit_log.txt" 2>&1 || true
fi

printf 'T5C_OUTPUT_VALIDATION_START\n'
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

if [[ -d "$OUTPUT_DIR" ]]; then
    find "$OUTPUT_DIR" -type f -printf '%f\n' \
        | awk -F. '{count[tolower($NF)]++} END {for (ext in count) printf "%s %d\n", ext, count[ext]}' \
        | sort > "$RESULT_DIR/output_file_counts.txt"
    find "$OUTPUT_DIR" -type f -print0 \
        | sort -z \
        | xargs -0 sha256sum \
        | sed "s#  $OUTPUT_DIR/#  #" \
        > "$RESULT_DIR/output_manifest.sha256"
fi

cp "$PYTHON_SCRIPT" "$RESULT_DIR/cosmos_writer_streaming.py"
cp "$VALIDATOR_SCRIPT" "$RESULT_DIR/validate_cosmos_output.py"
cp "$OVERRIDE_COMPOSE" "$RESULT_DIR/docker-compose.cosmos-streaming.yml"
cp "$0" "$RESULT_DIR/run_cosmos_writer_streaming_evidence.sh"

SIGNATURES='error 719|cudaErrorLaunchFailure|PhysX Internal CUDA error|illegal memory access|CUDA context validation failed|GPU solver pipeline failed|GPU Bp pipeline failed|CosmosWriter skipped video encoding|Hardware encoding failed|Traceback \(most recent call last\)|Timed out while waiting for pending Replicator writer schedules|Timed out waiting for async writer|renderer failed to advance|T5C_RUN_FAIL'
SCAN_INPUTS=("$APP_LOG")
if [[ -s "$RESULT_DIR/kit.log" ]]; then
    SCAN_INPUTS+=("$RESULT_DIR/kit.log")
fi
rg --line-number --ignore-case "$SIGNATURES" "${SCAN_INPUTS[@]}" > "$RESULT_DIR/negative_signature_scan.txt"
SIGNATURE_SCAN_RC=$?
rg --line-number --ignore-case 'NVRM: Xid|Xid \(' "$RESULT_DIR/kernel_events_during_run.txt" \
    > "$RESULT_DIR/kernel_xid_scan.txt"
XID_SCAN_RC=$?

case "$SIGNATURE_SCAN_RC" in
    0) SIGNATURE_STATUS="MATCHES_FOUND" ;;
    1) SIGNATURE_STATUS="NO_MATCHES" ;;
    *) SIGNATURE_STATUS="SCAN_ERROR_${SIGNATURE_SCAN_RC}" ;;
esac
case "$XID_SCAN_RC" in
    0) XID_STATUS="MATCHES_FOUND" ;;
    1) XID_STATUS="NO_MATCHES" ;;
    *) XID_STATUS="SCAN_ERROR_${XID_SCAN_RC}" ;;
esac
printf '%s\n' "$SIGNATURE_STATUS" > "$RESULT_DIR/negative_signature_scan_status.txt"
printf '%s\n' "$XID_STATUS" > "$RESULT_DIR/kernel_xid_scan_status.txt"
GRAPH_CYCLE_COUNT="$(rg -c 'Illegal cycle connection' "$APP_LOG" 2>/dev/null || true)"
GRAPH_CYCLE_COUNT="${GRAPH_CYCLE_COUNT:-0}"
printf '%s\n' "$GRAPH_CYCLE_COUNT" > "$RESULT_DIR/graph_cycle_warning_count.txt"

WORKLOAD_STATUS="FAIL"
if grep -Fq 'T5C_RUN_COMPLETE frames=60 png=300 mp4=5' "$APP_LOG"; then
    WORKLOAD_STATUS="PASS"
fi
BUILTIN_STATUS="MISSING"
if [[ -s "$RESULT_DIR/builtin_validation.json" ]]; then
    BUILTIN_STATUS="$(jq -r '.status // "UNKNOWN"' "$RESULT_DIR/builtin_validation.json")"
fi
VALIDATOR_STATUS="MISSING"
if [[ -s "$RESULT_DIR/output_validation.json" ]]; then
    VALIDATOR_STATUS="$(jq -r '.status // "UNKNOWN"' "$RESULT_DIR/output_validation.json")"
fi

FINAL_STATUS="FAIL"
OVERALL_RC=1
if [[ "$WORKLOAD_STATUS" == "PASS" && "$BUILTIN_STATUS" == "PASS" && \
      "$VALIDATOR_STATUS" == "PASS" && "$SIGNATURE_STATUS" == "NO_MATCHES" && \
      "$XID_STATUS" == "NO_MATCHES" ]]; then
    FINAL_STATUS="PASS"
    OVERALL_RC=0
fi

jq -n \
    --arg status "$FINAL_STATUS" \
    --arg workload_status "$WORKLOAD_STATUS" \
    --arg builtin_status "$BUILTIN_STATUS" \
    --arg validator_status "$VALIDATOR_STATUS" \
    --arg signature_status "$SIGNATURE_STATUS" \
    --arg xid_status "$XID_STATUS" \
    --arg stop_reason "$STOP_REASON" \
    --arg started_at "$STARTED_AT" \
    --arg finished_at "$FINISHED_AT" \
    --argjson validator_exit_code "$VALIDATION_RC" \
    --argjson graph_cycle_warning_count "$GRAPH_CYCLE_COUNT" \
    '{
        test_id: "T5-C",
        execution_surface: "Isaac Sim Full Streaming App",
        status: $status,
        workload_marker: $workload_status,
        builtin_validation: $builtin_status,
        independent_validation: $validator_status,
        negative_signature_scan: $signature_status,
        kernel_xid_scan: $xid_status,
        stop_reason: $stop_reason,
        validator_exit_code: $validator_exit_code,
        graph_cycle_warning_count: $graph_cycle_warning_count,
        started_at_utc: $started_at,
        finished_at_utc: $finished_at,
        expected: {frames: 60, png_files: 300, mp4_files: 5, width: 1280, height: 720},
        streaming_service_left_running: true
    }' > "$RESULT_DIR/result.json"
printf '%s\n' "$OVERALL_RC" > "$RESULT_DIR/overall_exit_code.txt"
printf 'T5C_EVIDENCE_COMPLETE status=%s workload=%s builtin=%s independent=%s signatures=%s xid=%s\n' \
    "$FINAL_STATUS" "$WORKLOAD_STATUS" "$BUILTIN_STATUS" "$VALIDATOR_STATUS" \
    "$SIGNATURE_STATUS" "$XID_STATUS"

exit "$OVERALL_RC"
