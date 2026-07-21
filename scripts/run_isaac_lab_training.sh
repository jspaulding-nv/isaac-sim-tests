#!/usr/bin/env bash

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
IMAGE="${IMAGE:-nvcr.io/nvidia/isaac-lab:3.0.0-beta2-post1}"
RESULT_DIR="${RESULT_DIR:-$REPO_ROOT/output/T3-isaac-lab-training}"
CONTAINER_NAME="${CONTAINER_NAME:-isaaclab30b2-t3-physx-gate}"
TEST_ID="${TEST_ID:-T3-GATE}"
TASK="${TASK:-Isaac-Ant-Direct-v0}"
PHYSICS_PRESET="${PHYSICS_PRESET:-physx}"
EXPECTED_BACKEND="${EXPECTED_BACKEND:-$PHYSICS_PRESET}"
NUM_ENVS="${NUM_ENVS:-1024}"
MAX_ITERATIONS="${MAX_ITERATIONS:-5}"
SEED="${SEED:-20260720}"
STEPS_PER_ENV_PER_ITERATION="${STEPS_PER_ENV_PER_ITERATION:-32}"
OVERALL_TIMEOUT_SECONDS="${OVERALL_TIMEOUT_SECONDS:-900}"

RUNTIME_DIR="$RESULT_DIR/runtime"
TRAINING_LOG_DIR="$RESULT_DIR/training_logs"
RUN_LOG="$RESULT_DIR/run_stdout_stderr.log"
TELEMETRY_PID=""
PMON_PID=""
DOCKER_RUN_PID=""
STOP_REASON="NONE"

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

cleanup() {
    stop_telemetry
    if container_running; then
        docker stop --timeout 20 "$CONTAINER_NAME" >/dev/null 2>&1 || true
    fi
}

trap cleanup EXIT INT TERM

if [[ -n "$(docker ps -a --quiet --filter "name=^/${CONTAINER_NAME}$" 2>/dev/null)" ]]; then
    printf 'Refusing to reuse existing container name: %s\n' "$CONTAINER_NAME" >&2
    exit 2
fi

mkdir -p \
    "$RESULT_DIR" \
    "$TRAINING_LOG_DIR" \
    "$RUNTIME_DIR/cache/kit" \
    "$RUNTIME_DIR/cache/ov" \
    "$RUNTIME_DIR/cache/pip" \
    "$RUNTIME_DIR/cache/glcache" \
    "$RUNTIME_DIR/cache/computecache" \
    "$RUNTIME_DIR/logs" \
    "$RUNTIME_DIR/data" \
    "$RUNTIME_DIR/documents" \
    "$RUNTIME_DIR/kit_logs"
chmod -R a+rwX "$RESULT_DIR"

STARTED_AT="$(date --utc --iso-8601=seconds)"
STARTED_JOURNAL="$(date --utc '+%Y-%m-%d %H:%M:%S UTC')"
START_EPOCH="$(date +%s)"
TRANSITIONS=$((NUM_ENVS * MAX_ITERATIONS * STEPS_PER_ENV_PER_ITERATION))

printf '%s\n' "$STARTED_AT" > "$RESULT_DIR/started_at_utc.txt"
printf '%s\n' "$IMAGE" > "$RESULT_DIR/image_reference.txt"
printf '%s\n' "$CONTAINER_NAME" > "$RESULT_DIR/container_name.txt"
printf 'test_id=%s\ntask=%s\nphysics_preset=%s\nexpected_backend=%s\nnum_envs=%s\nmax_iterations=%s\nseed=%s\nsteps_per_env_per_iteration=%s\nplanned_transitions=%s\noverall_timeout_seconds=%s\n' \
    "$TEST_ID" "$TASK" "$PHYSICS_PRESET" "$EXPECTED_BACKEND" "$NUM_ENVS" "$MAX_ITERATIONS" "$SEED" \
    "$STEPS_PER_ENV_PER_ITERATION" "$TRANSITIONS" "$OVERALL_TIMEOUT_SECONDS" \
    > "$RESULT_DIR/workload_parameters.txt"

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

printf 'T3_RUN_START test_id=%s task=%s physics=%s envs=%s iterations=%s seed=%s transitions=%s\n' \
    "$TEST_ID" "$TASK" "$PHYSICS_PRESET" "$NUM_ENVS" "$MAX_ITERATIONS" "$SEED" "$TRANSITIONS"

docker run --rm \
    --name "$CONTAINER_NAME" \
    --network=host \
    --device=nvidia.com/gpu=all \
    -e ACCEPT_EULA=Y \
    -e NVIDIA_VISIBLE_DEVICES=all \
    -e NVIDIA_DRIVER_CAPABILITIES=all \
    -e PYTHONUNBUFFERED=1 \
    -v "$TRAINING_LOG_DIR:/workspace/isaaclab/logs:rw" \
    -v "$RUNTIME_DIR/cache/kit:/isaac-sim/kit/cache:rw" \
    -v "$RUNTIME_DIR/cache/ov:/root/.cache/ov:rw" \
    -v "$RUNTIME_DIR/cache/pip:/root/.cache/pip:rw" \
    -v "$RUNTIME_DIR/cache/glcache:/root/.cache/nvidia/GLCache:rw" \
    -v "$RUNTIME_DIR/cache/computecache:/root/.nv/ComputeCache:rw" \
    -v "$RUNTIME_DIR/logs:/root/.nvidia-omniverse/logs:rw" \
    -v "$RUNTIME_DIR/data:/root/.local/share/ov/data:rw" \
    -v "$RUNTIME_DIR/documents:/root/Documents:rw" \
    -v "$RUNTIME_DIR/kit_logs:/isaac-sim/kit/logs:rw" \
    --entrypoint /bin/bash \
    "$IMAGE" \
    -lc "./isaaclab.sh train --rl_library rsl_rl --task $TASK --viz none --num_envs $NUM_ENVS --max_iterations $MAX_ITERATIONS --seed $SEED physics=$PHYSICS_PRESET" \
    > >(tee "$RUN_LOG") 2>&1 &
DOCKER_RUN_PID=$!

while kill -0 "$DOCKER_RUN_PID" 2>/dev/null; do
    NOW_EPOCH="$(date +%s)"
    if (( NOW_EPOCH - START_EPOCH >= OVERALL_TIMEOUT_SECONDS )); then
        STOP_REASON="OVERALL_TIMEOUT_EXCEEDED_${OVERALL_TIMEOUT_SECONDS}s"
        printf '%s\n' "$STOP_REASON" > "$RESULT_DIR/watchdog_status.txt"
        docker inspect "$CONTAINER_NAME" > "$RESULT_DIR/watchdog_container_inspect.json" 2>&1 || true
        docker top "$CONTAINER_NAME" -eo pid,ppid,user,stat,etime,pcpu,pmem,args \
            > "$RESULT_DIR/watchdog_container_top.txt" 2>&1 || true
        docker stop --timeout 20 "$CONTAINER_NAME" > "$RESULT_DIR/watchdog_docker_stop.txt" 2>&1 || true
        break
    fi
    sleep 5
done

set +e
wait "$DOCKER_RUN_PID"
RUN_RC=$?
set -e
DOCKER_RUN_PID=""

stop_telemetry
TELEMETRY_PID=""
PMON_PID=""

FINISHED_AT="$(date --utc --iso-8601=seconds)"
FINISHED_JOURNAL="$(date --utc '+%Y-%m-%d %H:%M:%S UTC')"
FINISHED_EPOCH="$(date +%s)"
WALLCLOCK_SECONDS=$((FINISHED_EPOCH - START_EPOCH))
printf '%s\n' "$FINISHED_AT" > "$RESULT_DIR/finished_at_utc.txt"
printf '%s\n' "$RUN_RC" > "$RESULT_DIR/docker_run_exit_code.txt"
printf '%s\n' "$STOP_REASON" > "$RESULT_DIR/stop_reason.txt"

docker ps --no-trunc > "$RESULT_DIR/containers_after.txt"
nvidia-smi -q > "$RESULT_DIR/nvidia_smi_post.txt"
nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv \
    > "$RESULT_DIR/gpu_processes_post.csv"
journalctl --dmesg --since "$STARTED_JOURNAL" --until "$FINISHED_JOURNAL" --no-pager \
    > "$RESULT_DIR/kernel_events_during_run.txt" 2>&1 || true

SIGNATURES='error 719|cudaErrorLaunchFailure|PhysX Internal CUDA error|illegal memory access|CUDA context validation failed|switching to software|GPU solver pipeline failed|GPU Bp pipeline failed|Traceback \(most recent call last\)'
set +e
rg --line-number --ignore-case "$SIGNATURES" "$RUN_LOG" "$RUNTIME_DIR/kit_logs" \
    > "$RESULT_DIR/negative_signature_scan.txt"
SCAN_RC=$?
rg --line-number --ignore-case 'NVRM: Xid|Xid \(' "$RESULT_DIR/kernel_events_during_run.txt" \
    > "$RESULT_DIR/kernel_xid_scan.txt"
XID_SCAN_RC=$?
set -e

case "$SCAN_RC" in
    0) printf '%s\n' "MATCHES_FOUND" > "$RESULT_DIR/negative_signature_scan_status.txt" ;;
    1) printf '%s\n' "NO_MATCHES" > "$RESULT_DIR/negative_signature_scan_status.txt" ;;
    *) printf 'SCAN_ERROR_%s\n' "$SCAN_RC" > "$RESULT_DIR/negative_signature_scan_status.txt" ;;
esac
case "$XID_SCAN_RC" in
    0) printf '%s\n' "MATCHES_FOUND" > "$RESULT_DIR/kernel_xid_scan_status.txt" ;;
    1) printf '%s\n' "NO_MATCHES" > "$RESULT_DIR/kernel_xid_scan_status.txt" ;;
    *) printf 'SCAN_ERROR_%s\n' "$XID_SCAN_RC" > "$RESULT_DIR/kernel_xid_scan_status.txt" ;;
esac

TRAINING_MARKER="MISSING"
if rg --quiet '^Training time: [0-9]' "$RUN_LOG"; then
    TRAINING_MARKER="PRESENT"
fi

DEVICE_MARKER="MISSING"
if rg --quiet 'Environment device[[:space:]]*: cuda:0' "$RUN_LOG"; then
    DEVICE_MARKER="PRESENT"
fi

BACKEND_MARKER="MISSING"
BACKEND_EVIDENCE="NONE"
if [[ "$EXPECTED_BACKEND" == "newton" ]]; then
    if rg --fixed-strings --quiet 'isaaclab_newton/physics/newton_manager.py' "$RUN_LOG" \
        && rg --quiet '^Initialize solver took:' "$RUN_LOG" \
        && rg --quiet '^CUDA graph took:' "$RUN_LOG"; then
        BACKEND_MARKER="PRESENT"
        BACKEND_EVIDENCE="newton_manager+solver+cuda_graph"
    fi
elif rg --fixed-strings --quiet "Registered backend '$EXPECTED_BACKEND' for factory Articulation." "$RUN_LOG"; then
    BACKEND_MARKER="PRESENT"
    BACKEND_EVIDENCE="factory_registration"
fi

ENV_COUNT_MARKER="MISSING"
if rg --quiet "Number of environments:[[:space:]]+$NUM_ENVS" "$RUN_LOG"; then
    ENV_COUNT_MARKER="PRESENT"
fi

TOTAL_STEPS_MARKER="MISSING"
if rg --quiet "Total steps:[[:space:]]+$TRANSITIONS" "$RUN_LOG"; then
    TOTAL_STEPS_MARKER="PRESENT"
fi

TRAINING_SECONDS="$(awk '/^Training time: [0-9]/{value=$3} END{print value+0}' "$RUN_LOG")"
FINAL_STEPS_PER_SECOND="$(awk '/Steps per second:/{value=$4} END{print value+0}' "$RUN_LOG")"
MEAN_TRAINING_STEPS_PER_SECOND="$(awk -v transitions="$TRANSITIONS" -v seconds="$TRAINING_SECONDS" 'BEGIN{printf "%.3f", (seconds > 0 ? transitions / seconds : 0)}')"
SCENE_CREATION_SECONDS="$(awk '/Time taken for scene creation Last:/{for(i=1;i<=NF;i++) if($i=="Last:") value=$(i+1)} END{print value+0}' "$RUN_LOG")"
SIMULATION_START_SECONDS="$(awk '/Time taken for simulation start Last:/{for(i=1;i<=NF;i++) if($i=="Last:") value=$(i+1)} END{print value+0}' "$RUN_LOG")"
NEWTON_SOLVER_INIT_SECONDS="$(awk '/^Initialize solver took: Last:/{value=$5} END{print value+0}' "$RUN_LOG")"
NEWTON_CUDA_GRAPH_SECONDS="$(awk '/^CUDA graph took: Last:/{value=$5} END{print value+0}' "$RUN_LOG")"
FINAL_MEAN_REWARD="$(awk '/Mean reward:/{value=$3} END{print value+0}' "$RUN_LOG")"
FINAL_MEAN_EPISODE_LENGTH="$(awk '/Mean episode length:/{value=$4} END{print value+0}' "$RUN_LOG")"
NEGATIVE_SIGNATURE_SCAN_STATUS="$(cat "$RESULT_DIR/negative_signature_scan_status.txt")"
KERNEL_XID_SCAN_STATUS="$(cat "$RESULT_DIR/kernel_xid_scan_status.txt")"
read -r TELEMETRY_SAMPLES MAX_GPU_UTIL_PCT AVG_GPU_UTIL_PCT MAX_MEMORY_MIB MAX_POWER_W < <(
    awk -F', ' 'NR>1 {
        gpu=$5; sub(/ %.*/, "", gpu)
        memory=$9; sub(/ MiB.*/, "", memory)
        power=$11; sub(/ W.*/, "", power)
        if (gpu+0 > max_gpu) max_gpu=gpu+0
        if (memory+0 > max_memory) max_memory=memory+0
        if (power+0 > max_power) max_power=power+0
        sum_gpu+=gpu; samples++
    } END {
        avg_gpu=(samples > 0 ? sum_gpu/samples : 0)
        printf "%d %d %.3f %d %.3f\n", samples, max_gpu, avg_gpu, max_memory, max_power
    }' "$RESULT_DIR/gpu_telemetry.csv"
)

STATUS="FAIL"
OVERALL_RC=1
if [[ "$RUN_RC" -eq 0 && "$STOP_REASON" == "NONE" && "$SCAN_RC" -eq 1 && "$XID_SCAN_RC" -eq 1 \
    && "$TRAINING_MARKER" == "PRESENT" && "$DEVICE_MARKER" == "PRESENT" \
    && "$BACKEND_MARKER" == "PRESENT" && "$ENV_COUNT_MARKER" == "PRESENT" \
    && "$TOTAL_STEPS_MARKER" == "PRESENT" ]]; then
    STATUS="PASS"
    OVERALL_RC=0
fi

jq -n \
    --arg status "$STATUS" \
    --arg test_id "$TEST_ID" \
    --arg task "$TASK" \
    --arg physics_preset "$PHYSICS_PRESET" \
    --arg expected_backend "$EXPECTED_BACKEND" \
    --arg backend_evidence "$BACKEND_EVIDENCE" \
    --arg negative_signature_scan "$NEGATIVE_SIGNATURE_SCAN_STATUS" \
    --arg kernel_xid_scan "$KERNEL_XID_SCAN_STATUS" \
    --arg training_marker "$TRAINING_MARKER" \
    --arg device_marker "$DEVICE_MARKER" \
    --arg backend_marker "$BACKEND_MARKER" \
    --arg env_count_marker "$ENV_COUNT_MARKER" \
    --arg total_steps_marker "$TOTAL_STEPS_MARKER" \
    --arg stop_reason "$STOP_REASON" \
    --arg started_at "$STARTED_AT" \
    --arg finished_at "$FINISHED_AT" \
    --argjson docker_exit_code "$RUN_RC" \
    --argjson num_envs "$NUM_ENVS" \
    --argjson max_iterations "$MAX_ITERATIONS" \
    --argjson seed "$SEED" \
    --argjson planned_transitions "$TRANSITIONS" \
    --argjson wallclock_seconds "$WALLCLOCK_SECONDS" \
    --argjson training_seconds "$TRAINING_SECONDS" \
    --argjson final_steps_per_second "$FINAL_STEPS_PER_SECOND" \
    --argjson mean_training_steps_per_second "$MEAN_TRAINING_STEPS_PER_SECOND" \
    --argjson scene_creation_seconds "$SCENE_CREATION_SECONDS" \
    --argjson simulation_start_seconds "$SIMULATION_START_SECONDS" \
    --argjson newton_solver_init_seconds "$NEWTON_SOLVER_INIT_SECONDS" \
    --argjson newton_cuda_graph_seconds "$NEWTON_CUDA_GRAPH_SECONDS" \
    --argjson final_mean_reward "$FINAL_MEAN_REWARD" \
    --argjson final_mean_episode_length "$FINAL_MEAN_EPISODE_LENGTH" \
    --argjson telemetry_samples "$TELEMETRY_SAMPLES" \
    --argjson max_gpu_utilization_pct "$MAX_GPU_UTIL_PCT" \
    --argjson average_gpu_utilization_pct "$AVG_GPU_UTIL_PCT" \
    --argjson max_memory_used_mib "$MAX_MEMORY_MIB" \
    --argjson max_power_w "$MAX_POWER_W" \
    '{
        test_id: $test_id,
        status: $status,
        task: $task,
        physics_preset: $physics_preset,
        expected_backend: $expected_backend,
        backend_evidence: $backend_evidence,
        num_envs: $num_envs,
        max_iterations: $max_iterations,
        seed: $seed,
        planned_transitions: $planned_transitions,
        training_marker: $training_marker,
        device_marker: $device_marker,
        backend_marker: $backend_marker,
        environment_count_marker: $env_count_marker,
        total_steps_marker: $total_steps_marker,
        negative_signature_scan: $negative_signature_scan,
        kernel_xid_scan: $kernel_xid_scan,
        stop_reason: $stop_reason,
        docker_exit_code: $docker_exit_code,
        wallclock_seconds: $wallclock_seconds,
        training_seconds: $training_seconds,
        final_steps_per_second: $final_steps_per_second,
        mean_training_steps_per_second: $mean_training_steps_per_second,
        scene_creation_seconds: $scene_creation_seconds,
        simulation_start_seconds: $simulation_start_seconds,
        newton_solver_init_seconds: $newton_solver_init_seconds,
        newton_cuda_graph_seconds: $newton_cuda_graph_seconds,
        final_mean_reward: $final_mean_reward,
        final_mean_episode_length: $final_mean_episode_length,
        telemetry: {
            samples: $telemetry_samples,
            max_gpu_utilization_pct: $max_gpu_utilization_pct,
            average_gpu_utilization_pct: $average_gpu_utilization_pct,
            max_memory_used_mib: $max_memory_used_mib,
            max_power_w: $max_power_w
        },
        started_at_utc: $started_at,
        finished_at_utc: $finished_at
    }' > "$RESULT_DIR/result.json"

cp "$0" "$RESULT_DIR/run_t3_physx_gate.sh"
printf 'T3_RUN_COMPLETE test_id=%s status=%s training_marker=%s backend_marker=%s total_steps_marker=%s stop_reason=%s\n' \
    "$TEST_ID" "$STATUS" "$TRAINING_MARKER" "$BACKEND_MARKER" "$TOTAL_STEPS_MARKER" "$STOP_REASON"
exit "$OVERALL_RC"
