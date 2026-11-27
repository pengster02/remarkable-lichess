#!/usr/bin/env bash
set -euo pipefail

# Run remarkable-lichess in AppLoad's Linux PC emulator via Docker + noVNC.
# macOS cannot host AppLoad backends (no AF_UNIX SOCK_SEQPACKET).

unset emulator_token
emulator_token="${LICHESS_TOKEN:-}"
unset LICHESS_TOKEN

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Sibling clones live next to this repo (e.g. ~/rm-appload, ~/xovi).
HOST_ROOT="$(cd "${ROOT}/.." && pwd)"
# Prefer sibling clones next to this repo; fall back to ~/rm-appload + ~/xovi.
APPLOAD_HOST="${APPLOAD_HOST:-}"
XOVI_HOST="${XOVI_HOST:-}"
if [ -z "${APPLOAD_HOST}" ]; then
  if [ -d "${HOST_ROOT}/rm-appload" ]; then
    APPLOAD_HOST="${HOST_ROOT}/rm-appload"
  elif [ -d "${HOME}/rm-appload" ]; then
    APPLOAD_HOST="${HOME}/rm-appload"
  else
    echo "rm-appload not found. Clone https://github.com/asivery/rm-appload next to this repo or set APPLOAD_HOST." >&2
    exit 1
  fi
fi
if [ -z "${XOVI_HOST}" ]; then
  if [ -d "${HOST_ROOT}/xovi" ]; then
    XOVI_HOST="${HOST_ROOT}/xovi"
  elif [ -d "${HOME}/xovi" ]; then
    XOVI_HOST="${HOME}/xovi"
  else
    echo "xovi not found. Clone https://github.com/asivery/xovi or set XOVI_HOST." >&2
    exit 1
  fi
fi

IMAGE="${IMAGE:-remarkable-lichess-local-pc}"
PORT="${PORT:-6080}"
NAME="${NAME:-remarkable-lichess-local}"
READY_TIMEOUT="${READY_TIMEOUT:-180}"
if ! [[ "${READY_TIMEOUT}" =~ ^[1-9][0-9]{0,5}$ ]]; then
  echo "READY_TIMEOUT must be a whole number of seconds from 1 to 999999." >&2
  exit 1
fi
CONFIG_ROOT="/var/lib/remarkable-lichess"
CONFIG_DIR="${CONFIG_ROOT}/config"
APP_SRC="/workspace/remarkable-lichess"
# A named volume follows the emulator name. A checkout bind follows the source tree.
# Container-local storage disappears on replacement.
CONFIG_VOLUME="${NAME}-config"
CONFIG_MOUNT="type=volume,src=${CONFIG_VOLUME},dst=${CONFIG_ROOT},volume-nocopy"

# Optional token: env LICHESS_TOKEN, or repo-local gitignored file.
TOKEN_FILE="${TOKEN_FILE:-${ROOT}/.lichess-token}"
TOKEN_MODE=replace
if [ -z "$emulator_token" ] && [ -f "${TOKEN_FILE}" ]; then
  emulator_token="$(tr -d ' \t\r\n' < "${TOKEN_FILE}")"
  TOKEN_MODE=initial
fi

echo "Building local-pc image (first run is slow)..."
docker build -t "${IMAGE}" "${ROOT}/docker/local-pc"
# Image index IDs can change when BuildKit writes attestations for identical layers.
IMAGE_INFO="$(docker image inspect --format '{{.Architecture}} {{json .RootFS.Layers}}' "${IMAGE}")"
CACHE_PREFIX="${NAME}-${IMAGE_INFO%% *}"
BUILD_KEY="$(printf '%s\n' "${ROOT}" "${APPLOAD_HOST}" "${XOVI_HOST}" "${IMAGE_INFO}" | cksum | cut -d ' ' -f 1)"

migrate_legacy_config() (
  local previous_id="$1" legacy="/tmp/remarkable-lichess-config" backup copy_error
  umask 077
  backup="$(mktemp -d "${TMPDIR:-/tmp}/remarkable-lichess-config.XXXXXXXX")" || exit 1
  trap 'rm -r -- "$backup"' EXIT
  # Verify the copy before publishing it. Direct extraction can leave partial data.
  # A streamed extractor can finish before the copy command reports failure.
  if ! copy_error="$(docker cp "${previous_id}:${legacy}" - 2>&1 > "${backup}/config.tar")"; then
    if [[ "$copy_error" == *"Could not find the file ${legacy} in container ${previous_id}" ]]; then
      exit 0
    fi
    printf '%s\n' "$copy_error" >&2
    exit 1
  fi

  docker run --rm --network none -i --mount "${CONFIG_MOUNT}" \
    --entrypoint /bin/sh "${IMAGE}" -eu -c '
      config="$1"
      stage="$(mktemp -d "$2/.migrate.XXXXXXXX")"
      trap '\''rm -rf -- "$stage"'\'' EXIT
      tar -xf - -C "$stage"
      source="$stage/$3"
      chmod 0700 "$source"
      if mv -Tn -- "$source" "$config" 2>/dev/null && [ ! -d "$source" ]; then
        exit 0
      fi
      if [ -d "$config" ] && diff -qr --no-dereference -- "$source" "$config" >/dev/null; then
        exit 0
      fi
      echo "Could not install emulator configuration. The volume may contain different data." >&2
      exit 1
    ' migrate "${CONFIG_DIR}" "${CONFIG_ROOT}" "${legacy##*/}" < "${backup}/config.tar"
)

restart_previous() {
  if [ "${PREVIOUS_STOPPED}" = 1 ]; then
    docker start "${PREVIOUS_ID}" >/dev/null ||
      echo "Could not restart ${NAME}. Retry with docker start ${NAME}." >&2
  fi
}

PREVIOUS_ID="$(docker ps -a --no-trunc --format '{{.ID}} {{.Names}}' |
  awk -v name="${NAME}" '$2 == name { print $1 }')"
PREVIOUS_STOPPED=0
if [ -n "${PREVIOUS_ID}" ]; then
  PREVIOUS_RUNNING="$(docker container inspect --format '{{.State.Running}}' "${PREVIOUS_ID}")"
  PREVIOUS_MOUNT="$(docker container inspect --format \
    "{{range .Mounts}}{{if eq .Destination \"${CONFIG_ROOT}\"}}{{.Type}} {{.Name}}{{end}}{{end}}" \
    "${PREVIOUS_ID}")"
  NEEDS_MIGRATION=0
  if [ "${PREVIOUS_MOUNT}" != "volume ${CONFIG_VOLUME}" ]; then
    NEEDS_MIGRATION=1
  fi
  if [ "${NEEDS_MIGRATION}" = 1 ]; then
    if [ "${PREVIOUS_RUNNING}" = true ]; then
      docker stop "${PREVIOUS_ID}" >/dev/null
      PREVIOUS_STOPPED=1
    fi
  fi
  if [ "${NEEDS_MIGRATION}" = 1 ] && ! migrate_legacy_config "${PREVIOUS_ID}"; then
    echo "Could not preserve configuration from ${NAME}. Its container is still available." >&2
    restart_previous
    exit 1
  fi
fi

RUN_ARGS=(
  --name "${NAME}"
  -p "127.0.0.1:${PORT}:6080"
  # Source binds preserve live edits. A whole checkout exposes host credentials.
  # Copying sources into the image would require rebuilding it after an edit.
  -v "${ROOT}/backend:${APP_SRC}/backend:ro"
  -v "${ROOT}/frontend:${APP_SRC}/frontend:ro"
  -v "${APPLOAD_HOST}:/workspace/rm-appload"
  -v "${XOVI_HOST}:/workspace/xovi"
  --mount "${CONFIG_MOUNT}"
  -e "REMARKABLE_LICHESS_CONFIG_DIR=${CONFIG_DIR}"
  # Key compiled output by checkout and image. Host targets mix platforms, and
  # a shared build directory can reuse artifacts from the wrong checkout.
  -v "${CACHE_PREFIX}-${BUILD_KEY}-build:/tmp/remarkable-lichess-build"
  -v "${CACHE_PREFIX}-cargo-registry:/usr/local/cargo/registry"
  -v "${CACHE_PREFIX}-cargo-git:/usr/local/cargo/git"
  -e "APP_SRC=${APP_SRC}"
  -e CARGO_TARGET_DIR=/tmp/remarkable-lichess-build/backend
  -e APPLOAD_SRC=/workspace/rm-appload
  -e XOVI_SRC=/workspace/xovi
)

TOKEN_STAGED=0
update_emulator_token() {
  docker run --rm --network none -i --mount "${CONFIG_MOUNT}" \
    --entrypoint /bin/bash "${IMAGE}" /usr/local/bin/seed-token.sh "${CONFIG_DIR}" "$1" "${CONTAINER_ID}"
}

rollback_launch() {
  local token_restored=1
  if [ -n "${CONTAINER_ID}" ] && ! docker rm -f "${CONTAINER_ID}" >/dev/null; then
    echo "Could not remove failed replacement ${CONTAINER_ID}." >&2
    if [ "${TOKEN_STAGED}" = 1 ]; then
      echo "The previous sign-in backup remains available for that replacement." >&2
      return
    fi
  fi
  if [ "${TOKEN_STAGED}" = 1 ] && ! update_emulator_token rollback </dev/null; then
    echo "Could not restore the emulator sign-in. The previous container will stay stopped." >&2
    token_restored=0
  fi
  if [ -n "${PREVIOUS_ID}" ]; then
    if docker rename "${PREVIOUS_ID}" "${NAME}"; then
      if [ "$token_restored" = 1 ]; then
        restart_previous
      fi
    else
      echo "Could not restore the emulator name. The previous container is ${PREVIOUS_ID}." >&2
    fi
  fi
}

echo "Starting emulator on http://localhost:${PORT}/vnc.html"
# Deleting the old container loses it on a bind failure, and a failed
# docker run can create a replacement without returning its ID.
if [ -n "${PREVIOUS_ID}" ] &&
  ! docker rename "${PREVIOUS_ID}" "${NAME}-previous-${PREVIOUS_ID:0:12}"; then
  restart_previous
  exit 1
fi
if ! CONTAINER_ID="$(docker create "${RUN_ARGS[@]}" "${IMAGE}")"; then
  rollback_launch
  exit 1
fi
if [ -n "${PREVIOUS_ID}" ] && [ "${PREVIOUS_RUNNING}" = true ] && [ "${PREVIOUS_STOPPED}" = 0 ]; then
  if ! docker stop "${PREVIOUS_ID}" >/dev/null; then
    rollback_launch
    exit 1
  fi
  PREVIOUS_STOPPED=1
fi
# Docker retains env vars and arguments. Stdin keeps the token private, and
# the candidate ID lets us restore the previous value if Docker rejects start.
if [ -n "$emulator_token" ]; then
  TOKEN_STAGED=1
  if ! printf '%s\n' "$emulator_token" | update_emulator_token "${TOKEN_MODE}"; then
    echo "Could not seed the emulator token." >&2
    rollback_launch
    exit 1
  fi
fi
unset emulator_token
if ! docker start "${CONTAINER_ID}" >/dev/null; then
  rollback_launch
  exit 1
fi
if [ "${TOKEN_STAGED}" = 1 ] && ! update_emulator_token commit </dev/null; then
  echo "Could not remove the private sign-in backup for ${CONTAINER_ID}." >&2
fi
if [ -n "${PREVIOUS_ID}" ] && ! docker rm "${PREVIOUS_ID}" >/dev/null; then
  echo "The previous container is still available as ${PREVIOUS_ID}." >&2
fi
DEADLINE=$((SECONDS + READY_TIMEOUT))

echo "Container ${NAME} started. Waiting for the noVNC display..."
while (( SECONDS < DEADLINE )); do
  if ! running="$(docker container inspect --format '{{.State.Running}}' "${CONTAINER_ID}")"; then
    echo "Could not check emulator container ${NAME}." >&2
    exit 1
  fi
  if [ "${running}" != true ]; then
    echo "Container ${NAME} exited before noVNC was ready:" >&2
    docker logs "${CONTAINER_ID}" >&2 || true
    exit 1
  fi

  remaining=$((DEADLINE - SECONDS))
  if (( remaining > 0 )) &&
    curl -fs --noproxy 127.0.0.1 --max-time "$((remaining < 2 ? remaining : 2))" \
      "http://127.0.0.1:${PORT}/vnc.html" >/dev/null 2>&1; then
    remaining=$((DEADLINE - SECONDS))
    if (( remaining > 0 )) &&
      docker exec "${CONTAINER_ID}" timeout "$((remaining < 2 ? remaining : 2))" \
        /usr/bin/python3 /usr/local/bin/check-display.py >/dev/null 2>&1; then
      echo "Ready: http://localhost:${PORT}/vnc.html"
      echo "Logs: docker logs -f ${NAME}"
      exit 0
    fi
  fi

  if (( SECONDS < DEADLINE )); then sleep 1; fi
done

echo "The noVNC display did not become ready within ${READY_TIMEOUT} seconds." >&2
echo "The container is still available. Follow progress with docker logs -f ${NAME}." >&2
exit 1
