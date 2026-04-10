#!/bin/zsh
set -euo pipefail

find_docker_bin() {
  if command -v docker >/dev/null 2>&1; then
    command -v docker
    return 0
  fi

  local docker_app_bin="/Applications/Docker.app/Contents/Resources/bin/docker"
  if [[ -x "$docker_app_bin" ]]; then
    echo "$docker_app_bin"
    return 0
  fi

  return 1
}

is_truthy() {
  case "${1:l}" in
    1|true|yes|y|on) return 0 ;;
    *) return 1 ;;
  esac
}

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 dataset-name-without-extension"
  echo "Example: $0 dc-metro-region"
  exit 1
fi

DOCKER_BIN="$(find_docker_bin || true)"
if [[ -z "$DOCKER_BIN" ]]; then
  echo "Docker is required but not installed or not on PATH."
  exit 1
fi

DATASET_NAME="$1"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OSRM_DIR="$PROJECT_DIR/data/osrm"
CONTAINER_IMAGE="${OSRM_DOCKER_IMAGE:-osrm/osrm-backend}"
PORT="${OSRM_PORT:-5000}"
CONTAINER_NAME="${OSRM_CONTAINER_NAME:-cabi-osrm}"
STAGE_ROOT="${OSRM_STAGE_ROOT:-/tmp/cabi-osrm-data}"
STARTUP_WAIT_SECONDS="${OSRM_STARTUP_WAIT_SECONDS:-2}"

if [[ ! -f "$OSRM_DIR/$DATASET_NAME.osrm" ]]; then
  echo "Missing prepared OSRM dataset: $OSRM_DIR/$DATASET_NAME.osrm"
  echo "Run scripts/setup_osrm_server.sh first."
  exit 1
fi

stage_dataset() {
  local stage_dir="$STAGE_ROOT/$DATASET_NAME"
  mkdir -p "$stage_dir"
  cp -f "$OSRM_DIR/$DATASET_NAME.osrm"* "$stage_dir/"
  echo "$stage_dir"
}

start_container() {
  local data_dir="$1"
  "$DOCKER_BIN" rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  "$DOCKER_BIN" run -d \
    --name "$CONTAINER_NAME" \
    -p "$PORT:5000" \
    -v "$data_dir:/data" \
    "$CONTAINER_IMAGE" \
    osrm-routed --algorithm mld "/data/$DATASET_NAME.osrm" >/dev/null
  sleep "$STARTUP_WAIT_SECONDS"
}

container_status() {
  "$DOCKER_BIN" inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || true
}

container_logs() {
  "$DOCKER_BIN" logs "$CONTAINER_NAME" 2>&1 || true
}

DATA_DIR="$OSRM_DIR"
USED_STAGING=false

if is_truthy "${OSRM_FORCE_STAGE_DATASET:-false}"; then
  DATA_DIR="$(stage_dataset)"
  USED_STAGING=true
fi

start_container "$DATA_DIR"

if [[ "$(container_status)" != "running" ]]; then
  INITIAL_LOGS="$(container_logs)"
  if [[ "$USED_STAGING" == false ]]; then
    DATA_DIR="$(stage_dataset)"
    USED_STAGING=true
    echo "Initial OSRM start from $OSRM_DIR failed; retrying with staged data in $DATA_DIR"
    start_container "$DATA_DIR"
  fi

  if [[ "$(container_status)" != "running" ]]; then
    echo "OSRM server failed to start."
    if [[ -n "$INITIAL_LOGS" ]]; then
      echo
      echo "Initial container logs:"
      echo "$INITIAL_LOGS"
    fi
    FINAL_LOGS="$(container_logs)"
    if [[ -n "$FINAL_LOGS" ]]; then
      echo
      echo "Latest container logs:"
      echo "$FINAL_LOGS"
    fi
    exit 1
  fi
fi

cat <<EOF

OSRM server started.
Mounted dataset directory:
  $DATA_DIR

Health check:
  curl "http://localhost:$PORT/nearest/v1/cycling/-77.0434,38.9096"

Planner example:
  ROUTE_PLAN_COST_MODEL=osrm \\
  ROUTE_PLAN_OSRM_URL=http://localhost:$PORT \\
  ROUTE_PLAN_OSRM_PROFILE=cycling \\
  ROUTE_PLAN_METRO_FILE=/Users/scotthuddle/Downloads/Metro_Stations_\\(Regional\\).csv \\
  ROUTE_PLAN_TARGET_STATIONS_PER_DAY=30 \\
  ROUTE_PLAN_MAX_TOTAL_DAY_MINUTES=300 \\
  ROUTE_PLAN_WRITE_MAPS=false \\
  Rscript cabi_route_planner.R
EOF
