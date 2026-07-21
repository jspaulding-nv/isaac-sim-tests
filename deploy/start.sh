#!/usr/bin/env bash

set -euo pipefail

DEPLOY_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$DEPLOY_DIR/.env}"
COMPOSE_PROJECT="${COMPOSE_PROJECT:-isaacsim-tests}"

if [[ ! -f "$ENV_FILE" ]]; then
    printf 'Missing %s. Copy .env.example to .env and configure ISAACSIM_HOST.\n' "$ENV_FILE" >&2
    exit 2
fi

cd "$DEPLOY_DIR"
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

ISAAC_SIM_DATA="${ISAAC_SIM_DATA:-./runtime/isaac-sim}"
ISAACSIM_HUB_CACHE_PATH="${ISAACSIM_HUB_CACHE_PATH:-./runtime/hub}"

mkdir -p \
    "$ISAAC_SIM_DATA/cache/main" \
    "$ISAAC_SIM_DATA/cache/computecache" \
    "$ISAAC_SIM_DATA/logs" \
    "$ISAAC_SIM_DATA/config" \
    "$ISAAC_SIM_DATA/data" \
    "$ISAAC_SIM_DATA/pkg" \
    "$ISAACSIM_HUB_CACHE_PATH"
chmod -R a+rwX "$ISAAC_SIM_DATA" "$ISAACSIM_HUB_CACHE_PATH"

docker compose --env-file "$ENV_FILE" -p "$COMPOSE_PROJECT" \
    -f "$DEPLOY_DIR/docker-compose.yml" up --build -d

printf 'Viewer: http://%s:%s\n' "${ISAACSIM_HOST:-127.0.0.1}" "${WEB_VIEWER_PORT:-8210}"
