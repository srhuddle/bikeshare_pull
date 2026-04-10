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

CONTAINER_NAME="${OSRM_CONTAINER_NAME:-cabi-osrm}"

DOCKER_BIN="$(find_docker_bin || true)"
if [[ -z "$DOCKER_BIN" ]]; then
  echo "Docker is required but not installed or not on PATH."
  exit 1
fi

"$DOCKER_BIN" rm -f "$CONTAINER_NAME"
