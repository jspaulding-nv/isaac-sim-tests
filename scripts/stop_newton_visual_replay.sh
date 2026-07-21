#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
CONTAINER_NAME="${CONTAINER_NAME:-isaaclab30b2-t6-newton-visual-replay}"
DEPLOYMENT_DIR="${DEPLOYMENT_DIR:-$REPO_ROOT/deploy}"
COMPOSE_PROJECT="${COMPOSE_PROJECT:-isaacsim-tests}"
COMPOSE_FILE="$DEPLOYMENT_DIR/docker-compose.yml"
ENV_FILE="$DEPLOYMENT_DIR/.env"
REPLAY_DIR="${REPLAY_DIR:-$REPO_ROOT/output/T6-newton-visual-replay/runtime}"

if [[ ! -f "$ENV_FILE" ]]; then
    printf 'Missing %s. Copy deploy/.env.example to deploy/.env first.\n' "$ENV_FILE" >&2
    exit 2
fi

if docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
    mkdir -p "$REPLAY_DIR"
    docker logs "$CONTAINER_NAME" > "$REPLAY_DIR/container.log" 2>&1 || true
    docker stop --timeout 30 "$CONTAINER_NAME"
    docker rm "$CONTAINER_NAME"
fi

docker compose --env-file "$ENV_FILE" -p "$COMPOSE_PROJECT" -f "$COMPOSE_FILE" \
    stop web-viewer

printf 'Stopped Isaac Lab visual replay and web viewer.\n'
