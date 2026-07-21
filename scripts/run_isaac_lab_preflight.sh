#!/usr/bin/env bash

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
IMAGE="${IMAGE:-nvcr.io/nvidia/isaac-lab:3.0.0-beta2-post1}"
RESULT_DIR="${RESULT_DIR:-$REPO_ROOT/output/T3-isaac-lab-preflight}"
CONTAINER_NAME="${CONTAINER_NAME:-isaaclab30b2-t3-preflight}"
RUNTIME_DIR="$RESULT_DIR/runtime"
RUN_LOG="$RESULT_DIR/run_stdout_stderr.log"

mkdir -p \
    "$RESULT_DIR" \
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
printf '%s\n' "$STARTED_AT" > "$RESULT_DIR/started_at_utc.txt"
printf '%s\n' "$IMAGE" > "$RESULT_DIR/image_reference.txt"
printf '%s\n' "$CONTAINER_NAME" > "$RESULT_DIR/container_name.txt"

docker image inspect "$IMAGE" > "$RESULT_DIR/image_inspect.json"
docker ps --no-trunc > "$RESULT_DIR/containers_before.txt"
nvidia-smi -q > "$RESULT_DIR/nvidia_smi_pre.txt"

docker run --rm \
    --entrypoint /bin/cat \
    "$IMAGE" \
    /workspace/isaaclab/VERSION \
    > "$RESULT_DIR/isaac_lab_source_version.txt"

docker run --rm \
    --entrypoint /bin/cat \
    "$IMAGE" \
    /isaac-sim/VERSION \
    > "$RESULT_DIR/isaac_sim_version.txt"

docker run --rm \
    --entrypoint /isaac-sim/python.sh \
    "$IMAGE" \
    -c 'import importlib.metadata as m, platform, torch, warp; print("python=" + platform.python_version()); print("torch=" + torch.__version__); print("torch_cuda=" + str(torch.version.cuda)); print("warp=" + m.version("warp-lang")); print("rsl_rl=" + m.version("rsl-rl-lib")); print("isaaclab_dist=" + m.version("isaaclab"))' \
    > "$RESULT_DIR/python_package_versions.txt"

docker run --rm \
    --device=nvidia.com/gpu=all \
    --entrypoint /isaac-sim/python.sh \
    "$IMAGE" \
    -c 'import torch; p=torch.cuda.get_device_properties(0); print("cuda_available=" + str(torch.cuda.is_available())); print("device_count=" + str(torch.cuda.device_count())); print("device_name=" + torch.cuda.get_device_name(0)); print("compute_capability=" + str(torch.cuda.get_device_capability(0))); print("total_memory_bytes=" + str(p.total_memory)); print("arch_list=" + str(torch.cuda.get_arch_list()))' \
    > "$RESULT_DIR/container_cuda_inventory.txt"

set +e
docker run --rm \
    --name "$CONTAINER_NAME" \
    --network=host \
    --device=nvidia.com/gpu=all \
    -e ACCEPT_EULA=Y \
    -e NVIDIA_VISIBLE_DEVICES=all \
    -e NVIDIA_DRIVER_CAPABILITIES=all \
    -e PYTHONUNBUFFERED=1 \
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
    -lc './isaaclab.sh -p scripts/environments/list_envs.py --keyword Ant --show_presets' \
    2>&1 | tee "$RUN_LOG"
RUN_RC=${PIPESTATUS[0]}
set -e

printf '%s\n' "$RUN_RC" > "$RESULT_DIR/docker_run_exit_code.txt"
docker ps --no-trunc > "$RESULT_DIR/containers_after.txt"
nvidia-smi -q > "$RESULT_DIR/nvidia_smi_post.txt"

FINISHED_AT="$(date --utc --iso-8601=seconds)"
printf '%s\n' "$FINISHED_AT" > "$RESULT_DIR/finished_at_utc.txt"

SIGNATURES='error 719|cudaErrorLaunchFailure|PhysX Internal CUDA error|illegal memory access|CUDA context validation failed|switching to software|GPU solver pipeline failed|GPU Bp pipeline failed|Traceback \(most recent call last\)'
set +e
rg --line-number --ignore-case "$SIGNATURES" "$RUN_LOG" "$RUNTIME_DIR/kit_logs" \
    > "$RESULT_DIR/negative_signature_scan.txt"
SCAN_RC=$?
set -e

case "$SCAN_RC" in
    0) printf '%s\n' "MATCHES_FOUND" > "$RESULT_DIR/negative_signature_scan_status.txt" ;;
    1) printf '%s\n' "NO_MATCHES" > "$RESULT_DIR/negative_signature_scan_status.txt" ;;
    *) printf 'SCAN_ERROR_%s\n' "$SCAN_RC" > "$RESULT_DIR/negative_signature_scan_status.txt" ;;
esac

cp "$0" "$RESULT_DIR/run_isaac_lab_preflight.sh"
exit "$RUN_RC"
