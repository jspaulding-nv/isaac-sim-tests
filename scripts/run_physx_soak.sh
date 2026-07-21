#!/usr/bin/env bash

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
IMAGE="${IMAGE:-nvcr.io/nvidia/isaac-lab:3.0.0-beta2-post1}"
RESULT_DIR="${RESULT_DIR:-$REPO_ROOT/output/T3-physx-soak}"
RUNNER="${RUNNER:-$SCRIPT_DIR/run_isaac_lab_training.sh}"
TASK="${TASK:-Isaac-Ant-Direct-v0}"
PHYSICS_PRESET="${PHYSICS_PRESET:-physx}"
EXPECTED_BACKEND="${EXPECTED_BACKEND:-physx}"
NUM_ENVS="${NUM_ENVS:-16384}"
MAX_ITERATIONS="${MAX_ITERATIONS:-250}"
STEPS_PER_ENV_PER_ITERATION="${STEPS_PER_ENV_PER_ITERATION:-32}"
SEEDS_CSV="${SEEDS_CSV:-20260720,20260721,20260722}"
PER_SEED_TIMEOUT_SECONDS="${PER_SEED_TIMEOUT_SECONDS:-1800}"
CONTAINER_PREFIX="${CONTAINER_PREFIX:-isaaclab30b2-t3-soak}"

RUNNER_PID=""

cleanup() {
    if [[ -n "$RUNNER_PID" ]] && kill -0 "$RUNNER_PID" 2>/dev/null; then
        kill "$RUNNER_PID" 2>/dev/null || true
        wait "$RUNNER_PID" 2>/dev/null || true
    fi
}

trap cleanup EXIT INT TERM

IFS=',' read -r -a SEEDS <<< "$SEEDS_CSV"
EXPECTED_RUNS="${#SEEDS[@]}"
PLANNED_TRANSITIONS_PER_SEED=$((NUM_ENVS * MAX_ITERATIONS * STEPS_PER_ENV_PER_ITERATION))
PLANNED_TOTAL_TRANSITIONS=$((PLANNED_TRANSITIONS_PER_SEED * EXPECTED_RUNS))

if [[ "$EXPECTED_RUNS" -eq 0 ]]; then
    printf 'No seeds were provided.\n' >&2
    exit 2
fi

if [[ -d "$RESULT_DIR" && -n "$(find "$RESULT_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    printf 'Refusing to overwrite non-empty result directory: %s\n' "$RESULT_DIR" >&2
    exit 2
fi

mkdir -p "$RESULT_DIR"
chmod a+rwx "$RESULT_DIR"

STARTED_AT="$(date --utc --iso-8601=seconds)"
START_EPOCH="$(date +%s)"
printf '%s\n' "$STARTED_AT" > "$RESULT_DIR/started_at_utc.txt"
printf '%s\n' "$IMAGE" > "$RESULT_DIR/image_reference.txt"
printf 'task=%s\nphysics_preset=%s\nexpected_backend=%s\nnum_envs=%s\nmax_iterations_per_seed=%s\nsteps_per_env_per_iteration=%s\nseeds=%s\nplanned_transitions_per_seed=%s\nplanned_total_transitions=%s\nper_seed_timeout_seconds=%s\n' \
    "$TASK" "$PHYSICS_PRESET" "$EXPECTED_BACKEND" "$NUM_ENVS" "$MAX_ITERATIONS" \
    "$STEPS_PER_ENV_PER_ITERATION" "$SEEDS_CSV" "$PLANNED_TRANSITIONS_PER_SEED" \
    "$PLANNED_TOTAL_TRANSITIONS" "$PER_SEED_TIMEOUT_SECONDS" \
    > "$RESULT_DIR/frozen_workload.txt"

docker image inspect "$IMAGE" > "$RESULT_DIR/image_inspect.json"
docker ps --no-trunc > "$RESULT_DIR/containers_before.txt"
nvidia-smi -q > "$RESULT_DIR/nvidia_smi_pre.txt"
df -h / > "$RESULT_DIR/disk_pre.txt"

RESULT_FILES=()
RUN_FAILURE=0

for SEED in "${SEEDS[@]}"; do
    SEED_DIR="$RESULT_DIR/seed_$SEED"
    CONTAINER_NAME="${CONTAINER_PREFIX}-${SEED}"
    mkdir -p "$SEED_DIR"
    chmod a+rwx "$SEED_DIR"

    printf 'T3_SOAK_SEED_START seed=%s envs=%s iterations=%s planned_transitions=%s\n' \
        "$SEED" "$NUM_ENVS" "$MAX_ITERATIONS" "$PLANNED_TRANSITIONS_PER_SEED"

    IMAGE="$IMAGE" \
    RESULT_DIR="$SEED_DIR" \
    CONTAINER_NAME="$CONTAINER_NAME" \
    TEST_ID="T3-SOAK-SEED" \
    TASK="$TASK" \
    PHYSICS_PRESET="$PHYSICS_PRESET" \
    EXPECTED_BACKEND="$EXPECTED_BACKEND" \
    NUM_ENVS="$NUM_ENVS" \
    MAX_ITERATIONS="$MAX_ITERATIONS" \
    SEED="$SEED" \
    STEPS_PER_ENV_PER_ITERATION="$STEPS_PER_ENV_PER_ITERATION" \
    OVERALL_TIMEOUT_SECONDS="$PER_SEED_TIMEOUT_SECONDS" \
    "$RUNNER" > "$SEED_DIR/orchestrator_console.log" 2>&1 &
    RUNNER_PID=$!

    LAST_REPORTED_ITERATION=""
    while kill -0 "$RUNNER_PID" 2>/dev/null; do
        CURRENT_ITERATION="$(rg -o 'Learning iteration [0-9]+/[0-9]+' "$SEED_DIR/run_stdout_stderr.log" 2>/dev/null | tail -1 | awk '{split($3, parts, "/"); print parts[1]}')"
        if [[ -n "$CURRENT_ITERATION" && "$CURRENT_ITERATION" != "$LAST_REPORTED_ITERATION" ]]; then
            if (( CURRENT_ITERATION == 0 || CURRENT_ITERATION % 25 == 0 || CURRENT_ITERATION + 1 == MAX_ITERATIONS )); then
                CURRENT_STEPS_PER_SECOND="$(awk '/Steps per second:/{value=$4} END{print value+0}' "$SEED_DIR/run_stdout_stderr.log" 2>/dev/null)"
                printf 'T3_SOAK_PROGRESS seed=%s iteration=%s/%s steps_per_second=%s\n' \
                    "$SEED" "$CURRENT_ITERATION" "$MAX_ITERATIONS" "$CURRENT_STEPS_PER_SECOND"
            fi
            LAST_REPORTED_ITERATION="$CURRENT_ITERATION"
        fi
        sleep 15
    done

    wait "$RUNNER_PID"
    RUN_RC=$?
    RUNNER_PID=""
    printf '%s\n' "$RUN_RC" > "$SEED_DIR/orchestrator_runner_exit_code.txt"

    if [[ -s "$SEED_DIR/result.json" ]]; then
        RESULT_FILES+=("$SEED_DIR/result.json")
        SEED_STATUS="$(jq -r '.status' "$SEED_DIR/result.json")"
    else
        SEED_STATUS="MISSING_RESULT"
    fi

    printf 'T3_SOAK_SEED_COMPLETE seed=%s status=%s runner_exit_code=%s\n' \
        "$SEED" "$SEED_STATUS" "$RUN_RC"

    if [[ "$RUN_RC" -ne 0 || "$SEED_STATUS" != "PASS" ]]; then
        RUN_FAILURE=1
        break
    fi
done

FINISHED_AT="$(date --utc --iso-8601=seconds)"
FINISHED_EPOCH="$(date +%s)"
WALLCLOCK_SECONDS=$((FINISHED_EPOCH - START_EPOCH))
printf '%s\n' "$FINISHED_AT" > "$RESULT_DIR/finished_at_utc.txt"
docker ps --no-trunc > "$RESULT_DIR/containers_after.txt"
nvidia-smi -q > "$RESULT_DIR/nvidia_smi_post.txt"
df -h / > "$RESULT_DIR/disk_post.txt"

COMPLETED_RUNS="${#RESULT_FILES[@]}"
STATUS="FAIL"
OVERALL_RC=1
if [[ "$RUN_FAILURE" -eq 0 && "$COMPLETED_RUNS" -eq "$EXPECTED_RUNS" ]]; then
    STATUS="PASS"
    OVERALL_RC=0
fi

if [[ "$COMPLETED_RUNS" -gt 0 ]]; then
    jq -s \
        --arg status "$STATUS" \
        --arg image "$IMAGE" \
        --arg task "$TASK" \
        --arg physics_preset "$PHYSICS_PRESET" \
        --arg seeds_csv "$SEEDS_CSV" \
        --arg started_at "$STARTED_AT" \
        --arg finished_at "$FINISHED_AT" \
        --argjson expected_runs "$EXPECTED_RUNS" \
        --argjson completed_runs "$COMPLETED_RUNS" \
        --argjson num_envs "$NUM_ENVS" \
        --argjson max_iterations_per_seed "$MAX_ITERATIONS" \
        --argjson planned_transitions_per_seed "$PLANNED_TRANSITIONS_PER_SEED" \
        --argjson planned_total_transitions "$PLANNED_TOTAL_TRANSITIONS" \
        --argjson wallclock_seconds "$WALLCLOCK_SECONDS" \
        '{
            test_id: "T3",
            status: $status,
            image: $image,
            task: $task,
            physics_preset: $physics_preset,
            seeds_csv: $seeds_csv,
            expected_runs: $expected_runs,
            completed_runs: $completed_runs,
            num_envs: $num_envs,
            max_iterations_per_seed: $max_iterations_per_seed,
            planned_transitions_per_seed: $planned_transitions_per_seed,
            planned_total_transitions: $planned_total_transitions,
            observed_completed_transitions: (map(.planned_transitions) | add),
            total_training_seconds: (map(.training_seconds) | add),
            aggregate_wallclock_seconds: $wallclock_seconds,
            peak_gpu_utilization_pct: (map(.telemetry.max_gpu_utilization_pct) | max),
            peak_memory_used_mib: (map(.telemetry.max_memory_used_mib) | max),
            peak_power_w: (map(.telemetry.max_power_w) | max),
            started_at_utc: $started_at,
            finished_at_utc: $finished_at,
            runs: .
        }' "${RESULT_FILES[@]}" > "$RESULT_DIR/result.json"
else
    jq -n \
        --arg status "$STATUS" \
        --arg image "$IMAGE" \
        --arg task "$TASK" \
        --arg started_at "$STARTED_AT" \
        --arg finished_at "$FINISHED_AT" \
        --argjson expected_runs "$EXPECTED_RUNS" \
        --argjson wallclock_seconds "$WALLCLOCK_SECONDS" \
        '{
            test_id: "T3",
            status: $status,
            image: $image,
            task: $task,
            expected_runs: $expected_runs,
            completed_runs: 0,
            aggregate_wallclock_seconds: $wallclock_seconds,
            started_at_utc: $started_at,
            finished_at_utc: $finished_at,
            runs: []
        }' > "$RESULT_DIR/result.json"
fi

cp "$0" "$RESULT_DIR/run_t3_physx_soak.sh"
cp "$RUNNER" "$RESULT_DIR/run_t3_training_run.sh"
printf 'T3_SOAK_COMPLETE status=%s completed_runs=%s/%s planned_total_transitions=%s wallclock_seconds=%s\n' \
    "$STATUS" "$COMPLETED_RUNS" "$EXPECTED_RUNS" "$PLANNED_TOTAL_TRANSITIONS" "$WALLCLOCK_SECONDS"
exit "$OVERALL_RC"
