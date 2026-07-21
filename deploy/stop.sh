#!/usr/bin/env bash

set -euo pipefail

DEPLOY_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$DEPLOY_DIR/.env}"
COMPOSE_PROJECT="${COMPOSE_PROJECT:-isaacsim-tests}"

docker compose --env-file "$ENV_FILE" -p "$COMPOSE_PROJECT" \
    -f "$DEPLOY_DIR/docker-compose.yml" down
