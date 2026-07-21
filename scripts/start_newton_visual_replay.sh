#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
IMAGE="${IMAGE:-nvcr.io/nvidia/isaac-lab:3.0.0-beta2-post1}"
CONTAINER_NAME="${CONTAINER_NAME:-isaaclab30b2-t6-newton-visual-replay}"
TASK="${TASK:-Isaac-Ant-Direct-v0}"
PHYSICS_PRESET="${PHYSICS_PRESET:-newton_mjwarp}"
NUM_ENVS="${NUM_ENVS:-16}"
PUBLIC_IP="${PUBLIC_IP:?Set PUBLIC_IP to the trusted-network address used by the browser}"
SIGNAL_PORT="${SIGNAL_PORT:-49200}"
STREAM_PORT="${STREAM_PORT:-48100}"
WEB_VIEWER_PORT="${WEB_VIEWER_PORT:-8210}"
SOURCE_CHECKPOINT="${SOURCE_CHECKPOINT:?Set SOURCE_CHECKPOINT to a trained RSL-RL model_*.pt file}"
REPLAY_DIR="${REPLAY_DIR:-$REPO_ROOT/output/T6-newton-visual-replay/runtime}"
DEPLOYMENT_DIR="${DEPLOYMENT_DIR:-$REPO_ROOT/deploy}"
COMPOSE_PROJECT="${COMPOSE_PROJECT:-isaacsim-tests}"
COMPOSE_FILE="$DEPLOYMENT_DIR/docker-compose.yml"
ENV_FILE="$DEPLOYMENT_DIR/.env"

if [[ ! -f "$ENV_FILE" ]]; then
    printf 'Missing %s. Copy deploy/.env.example to deploy/.env first.\n' "$ENV_FILE" >&2
    exit 2
fi

if [[ ! -r "$SOURCE_CHECKPOINT" ]]; then
    printf 'Checkpoint is not readable: %s\n' "$SOURCE_CHECKPOINT" >&2
    exit 2
fi

if docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
    printf 'Container already exists: %s\n' "$CONTAINER_NAME" >&2
    printf 'Run scripts/stop_newton_visual_replay.sh before starting a new replay.\n' >&2
    exit 2
fi

if ss -H -ltn "sport = :$SIGNAL_PORT" | grep -q .; then
    printf 'TCP signal port %s is already in use.\n' "$SIGNAL_PORT" >&2
    exit 2
fi

mkdir -p \
    "$REPLAY_DIR/checkpoint" \
    "$REPLAY_DIR/cache/kit" \
    "$REPLAY_DIR/cache/ov" \
    "$REPLAY_DIR/cache/pip" \
    "$REPLAY_DIR/cache/glcache" \
    "$REPLAY_DIR/cache/computecache" \
    "$REPLAY_DIR/logs" \
    "$REPLAY_DIR/data" \
    "$REPLAY_DIR/documents" \
    "$REPLAY_DIR/kit_logs"
cp "$SOURCE_CHECKPOINT" "$REPLAY_DIR/checkpoint/model_99.pt"
chmod a+rwx \
    "$REPLAY_DIR" \
    "$REPLAY_DIR/checkpoint" \
    "$REPLAY_DIR/cache" \
    "$REPLAY_DIR/cache/kit" \
    "$REPLAY_DIR/cache/ov" \
    "$REPLAY_DIR/cache/pip" \
    "$REPLAY_DIR/cache/glcache" \
    "$REPLAY_DIR/cache/computecache" \
    "$REPLAY_DIR/logs" \
    "$REPLAY_DIR/data" \
    "$REPLAY_DIR/documents" \
    "$REPLAY_DIR/kit_logs"
chmod a+rw "$REPLAY_DIR/checkpoint/model_99.pt"

printf '%s\n' "$SOURCE_CHECKPOINT" > "$REPLAY_DIR/checkpoint_source.txt"
printf 'image=%s\ntask=%s\nphysics_preset=%s\nnum_envs=%s\npublic_ip=%s\nsignal_port=%s\nstream_port=%s\nweb_viewer_port=%s\n' \
    "$IMAGE" "$TASK" "$PHYSICS_PRESET" "$NUM_ENVS" "$PUBLIC_IP" \
    "$SIGNAL_PORT" "$STREAM_PORT" "$WEB_VIEWER_PORT" \
    > "$REPLAY_DIR/replay_parameters.txt"

docker compose --env-file "$ENV_FILE" -p "$COMPOSE_PROJECT" -f "$COMPOSE_FILE" \
    up -d --no-deps web-viewer

KIT_ARGS="--no-window --/exts/omni.renderer.core/present/enabled=true --/app/livestream/allowResize=true --/exts/omni.kit.livestream.app/primaryStream/publicIp=$PUBLIC_IP --/exts/omni.kit.livestream.app/primaryStream/signalPort=$SIGNAL_PORT --/exts/omni.kit.livestream.app/primaryStream/streamPort=$STREAM_PORT --/exts/omni.kit.livestream.app/primaryStream/allowDynamicResize=true --/exts/omni.kit.livestream.app/primaryStream/streamType=webrtc"

docker run -d \
    --name "$CONTAINER_NAME" \
    --network=host \
    --device=nvidia.com/gpu=all \
    --workdir /workspace/isaaclab \
    -e ACCEPT_EULA=Y \
    -e NVIDIA_VISIBLE_DEVICES=all \
    -e NVIDIA_DRIVER_CAPABILITIES=all \
    -e PYTHONUNBUFFERED=1 \
    -e PUBLIC_IP="$PUBLIC_IP" \
    -v "$REPLAY_DIR/checkpoint:/replay:rw" \
    -v "$REPLAY_DIR/cache/kit:/isaac-sim/kit/cache:rw" \
    -v "$REPLAY_DIR/cache/ov:/root/.cache/ov:rw" \
    -v "$REPLAY_DIR/cache/pip:/root/.cache/pip:rw" \
    -v "$REPLAY_DIR/cache/glcache:/root/.cache/nvidia/GLCache:rw" \
    -v "$REPLAY_DIR/cache/computecache:/root/.nv/ComputeCache:rw" \
    -v "$REPLAY_DIR/logs:/root/.nvidia-omniverse/logs:rw" \
    -v "$REPLAY_DIR/data:/root/.local/share/ov/data:rw" \
    -v "$REPLAY_DIR/documents:/root/Documents:rw" \
    -v "$REPLAY_DIR/kit_logs:/isaac-sim/kit/logs:rw" \
    --entrypoint /workspace/isaaclab/isaaclab.sh \
    "$IMAGE" \
    play \
    --rl_library rsl_rl \
    --task "$TASK" \
    --num_envs "$NUM_ENVS" \
    --checkpoint /replay/model_99.pt \
    --seed 20260720 \
    --real-time \
    --livestream 1 \
    --enable_cameras \
    --experience /workspace/isaaclab/apps/isaaclab.python.rendering.kit \
    --viz kit \
    --kit_args "$KIT_ARGS" \
    "physics=$PHYSICS_PRESET" \
    > "$REPLAY_DIR/container_id.txt"

DEADLINE=$((SECONDS + 480))
while (( SECONDS < DEADLINE )); do
    if [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME")" != "true" ]]; then
        docker logs "$CONTAINER_NAME" > "$REPLAY_DIR/container.log" 2>&1 || true
        printf 'Replay container exited before becoming ready. See %s/container.log\n' "$REPLAY_DIR" >&2
        exit 1
    fi

    if docker logs "$CONTAINER_NAME" 2>&1 | grep -Fq '[INFO]: Loading model checkpoint from: /replay/model_99.pt' \
        && ss -H -ltn "sport = :$SIGNAL_PORT" | grep -q . \
        && curl --fail --silent "http://127.0.0.1:$WEB_VIEWER_PORT/" >/dev/null; then
        docker logs "$CONTAINER_NAME" > "$REPLAY_DIR/container.log" 2>&1
        date --utc --iso-8601=seconds > "$REPLAY_DIR/ready_at_utc.txt"
        printf 'READY\n'
        printf 'Browser URL: http://%s:%s\n' "$PUBLIC_IP" "$WEB_VIEWER_PORT"
        printf 'Signal: %s:%s/TCP\n' "$PUBLIC_IP" "$SIGNAL_PORT"
        printf 'Media: %s:%s/UDP\n' "$PUBLIC_IP" "$STREAM_PORT"
        exit 0
    fi
    sleep 5
done

docker logs "$CONTAINER_NAME" > "$REPLAY_DIR/container.log" 2>&1 || true
printf 'Replay did not become ready before the 480-second deadline.\n' >&2
exit 1
