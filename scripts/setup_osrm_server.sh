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

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 /absolute/path/to/metro-region.osm.pbf"
  exit 1
fi

DOCKER_BIN="$(find_docker_bin || true)"
if [[ -z "$DOCKER_BIN" ]]; then
  echo "Docker is required but not installed or not on PATH."
  echo "Install Docker Desktop first, then rerun this script."
  exit 1
fi

PBF_PATH="$1"
if [[ ! -f "$PBF_PATH" ]]; then
  echo "OSM extract not found: $PBF_PATH"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OSRM_DIR="$PROJECT_DIR/data/osrm"
mkdir -p "$OSRM_DIR"

PBF_BASENAME="$(basename "$PBF_PATH")"
DATASET_NAME="${PBF_BASENAME%.osm.pbf}"
CONTAINER_IMAGE="${OSRM_DOCKER_IMAGE:-osrm/osrm-backend}"
PROFILE_LUA="${OSRM_PROFILE_LUA:-/opt/bicycle.lua}"
TARGET_PBF="$OSRM_DIR/$PBF_BASENAME"

if [[ "$PBF_PATH" != "$TARGET_PBF" ]]; then
  cp -f "$PBF_PATH" "$TARGET_PBF"
fi

echo "Preparing OSRM dataset in $OSRM_DIR"
echo "Dataset: $PBF_BASENAME"
echo "Profile: $PROFILE_LUA"

"$DOCKER_BIN" run --rm \
  -v "$OSRM_DIR:/data" \
  "$CONTAINER_IMAGE" \
  osrm-extract -p "$PROFILE_LUA" "/data/$PBF_BASENAME"

"$DOCKER_BIN" run --rm \
  -v "$OSRM_DIR:/data" \
  "$CONTAINER_IMAGE" \
  osrm-partition "/data/$DATASET_NAME.osrm"

"$DOCKER_BIN" run --rm \
  -v "$OSRM_DIR:/data" \
  "$CONTAINER_IMAGE" \
  osrm-customize "/data/$DATASET_NAME.osrm"

cat <<EOF

OSRM preprocessing completed.

Next step:
  $PROJECT_DIR/scripts/start_osrm_server.sh "$DATASET_NAME"

Then run the planner with:
  ROUTE_PLAN_COST_MODEL=osrm \\
  ROUTE_PLAN_OSRM_URL=http://localhost:5000 \\
  ROUTE_PLAN_METRO_FILE=/Users/scotthuddle/Downloads/Metro_Stations_\\(Regional\\).csv \\
  ROUTE_PLAN_TARGET_STATIONS_PER_DAY=30 \\
  ROUTE_PLAN_MAX_TOTAL_DAY_MINUTES=300 \\
  ROUTE_PLAN_WRITE_MAPS=false \\
  Rscript cabi_route_planner.R
EOF
