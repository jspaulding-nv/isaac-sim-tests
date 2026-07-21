#!/usr/bin/env bash

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
IMAGE="${IMAGE:-nvcr.io/nvidia/isaac-lab:3.0.0-beta2-post1}"
RESULT_DIR="${RESULT_DIR:-$REPO_ROOT/output/T6-backend-comparison}"
RUNNER="${RUNNER:-$SCRIPT_DIR/run_isaac_lab_training.sh}"
TASK="${TASK:-Isaac-Ant-Direct-v0}"
NUM_ENVS="${NUM_ENVS:-4096}"
MAX_ITERATIONS="${MAX_ITERATIONS:-100}"
STEPS_PER_ENV_PER_ITERATION="${STEPS_PER_ENV_PER_ITERATION:-32}"
SEEDS_CSV="${SEEDS_CSV:-20260720,20260721,20260722}"
PER_RUN_TIMEOUT_SECONDS="${PER_RUN_TIMEOUT_SECONDS:-1800}"
CONTAINER_PREFIX="${CONTAINER_PREFIX:-isaaclab30b2-t6}"

RUNNER_PID=""

cleanup() {
    if [[ -n "$RUNNER_PID" ]] && kill -0 "$RUNNER_PID" 2>/dev/null; then
        kill "$RUNNER_PID" 2>/dev/null || true
        wait "$RUNNER_PID" 2>/dev/null || true
    fi
}

trap cleanup EXIT INT TERM

IFS=',' read -r -a SEEDS <<< "$SEEDS_CSV"
EXPECTED_RUNS_PER_BACKEND="${#SEEDS[@]}"
EXPECTED_RUNS=$((EXPECTED_RUNS_PER_BACKEND * 2))
PLANNED_TRANSITIONS_PER_RUN=$((NUM_ENVS * MAX_ITERATIONS * STEPS_PER_ENV_PER_ITERATION))
PLANNED_TRANSITIONS_PER_BACKEND=$((PLANNED_TRANSITIONS_PER_RUN * EXPECTED_RUNS_PER_BACKEND))
PLANNED_TOTAL_TRANSITIONS=$((PLANNED_TRANSITIONS_PER_BACKEND * 2))

if [[ "$EXPECTED_RUNS_PER_BACKEND" -eq 0 ]]; then
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
printf 'task=%s\nnum_envs=%s\nmax_iterations_per_run=%s\nsteps_per_env_per_iteration=%s\nseeds=%s\nbackends=physx,newton_mjwarp\nplanned_transitions_per_run=%s\nplanned_transitions_per_backend=%s\nplanned_total_transitions=%s\nper_run_timeout_seconds=%s\n' \
    "$TASK" "$NUM_ENVS" "$MAX_ITERATIONS" "$STEPS_PER_ENV_PER_ITERATION" "$SEEDS_CSV" \
    "$PLANNED_TRANSITIONS_PER_RUN" "$PLANNED_TRANSITIONS_PER_BACKEND" \
    "$PLANNED_TOTAL_TRANSITIONS" "$PER_RUN_TIMEOUT_SECONDS" \
    > "$RESULT_DIR/frozen_workload.txt"

printf 'ordinal\tseed\tphysics_preset\texpected_backend\n' > "$RESULT_DIR/run_order.tsv"
docker image inspect "$IMAGE" > "$RESULT_DIR/image_inspect.json"
docker ps --no-trunc > "$RESULT_DIR/containers_before.txt"
nvidia-smi -q > "$RESULT_DIR/nvidia_smi_pre.txt"
df -h / > "$RESULT_DIR/disk_pre.txt"

RESULT_FILES=()
RUN_FAILURE=0
ORDINAL=0

for INDEX in "${!SEEDS[@]}"; do
    SEED="${SEEDS[$INDEX]}"
    if (( INDEX % 2 == 0 )); then
        PRESETS=(physx newton_mjwarp)
    else
        PRESETS=(newton_mjwarp physx)
    fi

    for PHYSICS_PRESET in "${PRESETS[@]}"; do
        ORDINAL=$((ORDINAL + 1))
        if [[ "$PHYSICS_PRESET" == "physx" ]]; then
            EXPECTED_BACKEND="physx"
            BACKEND_LABEL="physx"
        else
            EXPECTED_BACKEND="newton"
            BACKEND_LABEL="newton_mjwarp"
        fi

        RUN_DIR="$RESULT_DIR/$BACKEND_LABEL/seed_$SEED"
        CONTAINER_NAME="${CONTAINER_PREFIX}-${BACKEND_LABEL//_/-}-${SEED}"
        mkdir -p "$RUN_DIR"
        chmod a+rwx "$RUN_DIR"
        printf '%s\t%s\t%s\t%s\n' "$ORDINAL" "$SEED" "$PHYSICS_PRESET" "$EXPECTED_BACKEND" \
            >> "$RESULT_DIR/run_order.tsv"

        printf 'T6_RUN_START ordinal=%s/%s seed=%s physics=%s envs=%s iterations=%s planned_transitions=%s\n' \
            "$ORDINAL" "$EXPECTED_RUNS" "$SEED" "$PHYSICS_PRESET" "$NUM_ENVS" \
            "$MAX_ITERATIONS" "$PLANNED_TRANSITIONS_PER_RUN"

        IMAGE="$IMAGE" \
        RESULT_DIR="$RUN_DIR" \
        CONTAINER_NAME="$CONTAINER_NAME" \
        TEST_ID="T6-COMPARISON-RUN" \
        TASK="$TASK" \
        PHYSICS_PRESET="$PHYSICS_PRESET" \
        EXPECTED_BACKEND="$EXPECTED_BACKEND" \
        NUM_ENVS="$NUM_ENVS" \
        MAX_ITERATIONS="$MAX_ITERATIONS" \
        SEED="$SEED" \
        STEPS_PER_ENV_PER_ITERATION="$STEPS_PER_ENV_PER_ITERATION" \
        OVERALL_TIMEOUT_SECONDS="$PER_RUN_TIMEOUT_SECONDS" \
        "$RUNNER" > "$RUN_DIR/orchestrator_console.log" 2>&1 &
        RUNNER_PID=$!

        LAST_REPORTED_ITERATION=""
        while kill -0 "$RUNNER_PID" 2>/dev/null; do
            CURRENT_ITERATION="$(rg -o 'Learning iteration [0-9]+/[0-9]+' "$RUN_DIR/run_stdout_stderr.log" 2>/dev/null | tail -1 | awk '{split($3, parts, "/"); print parts[1]}')"
            if [[ -n "$CURRENT_ITERATION" && "$CURRENT_ITERATION" != "$LAST_REPORTED_ITERATION" ]]; then
                if (( CURRENT_ITERATION == 0 || CURRENT_ITERATION % 25 == 0 || CURRENT_ITERATION + 1 == MAX_ITERATIONS )); then
                    CURRENT_STEPS_PER_SECOND="$(awk '/Steps per second:/{value=$4} END{print value+0}' "$RUN_DIR/run_stdout_stderr.log" 2>/dev/null)"
                    printf 'T6_PROGRESS ordinal=%s seed=%s physics=%s iteration=%s/%s steps_per_second=%s\n' \
                        "$ORDINAL" "$SEED" "$PHYSICS_PRESET" "$CURRENT_ITERATION" \
                        "$MAX_ITERATIONS" "$CURRENT_STEPS_PER_SECOND"
                fi
                LAST_REPORTED_ITERATION="$CURRENT_ITERATION"
            fi
            sleep 15
        done

        wait "$RUNNER_PID"
        RUN_RC=$?
        RUNNER_PID=""
        printf '%s\n' "$RUN_RC" > "$RUN_DIR/orchestrator_runner_exit_code.txt"

        if [[ -s "$RUN_DIR/result.json" ]]; then
            RESULT_FILES+=("$RUN_DIR/result.json")
            RUN_STATUS="$(jq -r '.status' "$RUN_DIR/result.json")"
        else
            RUN_STATUS="MISSING_RESULT"
        fi

        printf 'T6_RUN_COMPLETE ordinal=%s/%s seed=%s physics=%s status=%s runner_exit_code=%s\n' \
            "$ORDINAL" "$EXPECTED_RUNS" "$SEED" "$PHYSICS_PRESET" "$RUN_STATUS" "$RUN_RC"

        if [[ "$RUN_RC" -ne 0 || "$RUN_STATUS" != "PASS" ]]; then
            RUN_FAILURE=1
        fi
    done
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
        --arg seeds_csv "$SEEDS_CSV" \
        --arg started_at "$STARTED_AT" \
        --arg finished_at "$FINISHED_AT" \
        --argjson expected_runs "$EXPECTED_RUNS" \
        --argjson expected_runs_per_backend "$EXPECTED_RUNS_PER_BACKEND" \
        --argjson completed_runs "$COMPLETED_RUNS" \
        --argjson num_envs "$NUM_ENVS" \
        --argjson max_iterations_per_run "$MAX_ITERATIONS" \
        --argjson planned_transitions_per_run "$PLANNED_TRANSITIONS_PER_RUN" \
        --argjson planned_transitions_per_backend "$PLANNED_TRANSITIONS_PER_BACKEND" \
        --argjson planned_total_transitions "$PLANNED_TOTAL_TRANSITIONS" \
        --argjson wallclock_seconds "$WALLCLOCK_SECONDS" \
        '. as $all
        | def summarize($preset):
            [$all[] | select(.physics_preset == $preset)] as $runs
            | ($runs | map(.planned_transitions) | add // 0) as $transitions
            | ($runs | map(.training_seconds) | add // 0) as $training_seconds
            | {
                expected_runs: $expected_runs_per_backend,
                completed_runs: ($runs | length),
                passing_runs: ($runs | map(select(.status == "PASS")) | length),
                observed_transitions: $transitions,
                total_training_seconds: $training_seconds,
                total_wallclock_seconds: ($runs | map(.wallclock_seconds) | add // 0),
                mean_training_steps_per_second: (if $training_seconds > 0 then $transitions / $training_seconds else 0 end),
                mean_final_steps_per_second: (if ($runs | length) > 0 then ($runs | map(.final_steps_per_second) | add) / ($runs | length) else 0 end),
                mean_scene_creation_seconds: (if ($runs | length) > 0 then ($runs | map(.scene_creation_seconds) | add) / ($runs | length) else 0 end),
                mean_simulation_start_seconds: (if ($runs | length) > 0 then ($runs | map(.simulation_start_seconds) | add) / ($runs | length) else 0 end),
                mean_final_reward: (if ($runs | length) > 0 then ($runs | map(.final_mean_reward) | add) / ($runs | length) else 0 end),
                mean_final_episode_length: (if ($runs | length) > 0 then ($runs | map(.final_mean_episode_length) | add) / ($runs | length) else 0 end),
                peak_gpu_utilization_pct: ($runs | map(.telemetry.max_gpu_utilization_pct) | max // 0),
                peak_memory_used_mib: ($runs | map(.telemetry.max_memory_used_mib) | max // 0),
                peak_power_w: ($runs | map(.telemetry.max_power_w) | max // 0)
            };
        (summarize("physx")) as $physx
        | (summarize("newton_mjwarp")) as $newton
        | {
            test_id: "T6",
            status: $status,
            image: $image,
            task: $task,
            seeds_csv: $seeds_csv,
            expected_runs: $expected_runs,
            completed_runs: $completed_runs,
            num_envs: $num_envs,
            max_iterations_per_run: $max_iterations_per_run,
            planned_transitions_per_run: $planned_transitions_per_run,
            planned_transitions_per_backend: $planned_transitions_per_backend,
            planned_total_transitions: $planned_total_transitions,
            observed_completed_transitions: ($all | map(.planned_transitions) | add),
            aggregate_wallclock_seconds: $wallclock_seconds,
            comparison: {
                physx: $physx,
                newton_mjwarp: $newton,
                newton_to_physx_training_throughput_ratio: (if $physx.mean_training_steps_per_second > 0 then $newton.mean_training_steps_per_second / $physx.mean_training_steps_per_second else 0 end),
                newton_to_physx_total_wallclock_ratio: (if $physx.total_wallclock_seconds > 0 then $newton.total_wallclock_seconds / $physx.total_wallclock_seconds else 0 end),
                newton_to_physx_simulation_start_ratio: (if $physx.mean_simulation_start_seconds > 0 then $newton.mean_simulation_start_seconds / $physx.mean_simulation_start_seconds else 0 end),
                final_reward_delta_newton_minus_physx: ($newton.mean_final_reward - $physx.mean_final_reward)
            },
            started_at_utc: $started_at,
            finished_at_utc: $finished_at,
            runs: $all
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
            test_id: "T6",
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

cp "$0" "$RESULT_DIR/run_t6_backend_comparison.sh"
cp "$RUNNER" "$RESULT_DIR/run_isaac_lab_training_gate.sh"
printf 'T6_COMPLETE status=%s completed_runs=%s/%s planned_total_transitions=%s wallclock_seconds=%s\n' \
    "$STATUS" "$COMPLETED_RUNS" "$EXPECTED_RUNS" "$PLANNED_TOTAL_TRANSITIONS" "$WALLCLOCK_SECONDS"
exit "$OVERALL_RC"
