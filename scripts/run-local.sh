#!/usr/bin/env bash
set -euo pipefail

# Run remarkable-lichess in AppLoad's Linux PC emulator via Docker + noVNC.
# macOS cannot host AppLoad backends (no AF_UNIX SOCK_SEQPACKET).

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
CONFIG_ROOT="/var/lib/remarkable-lichess"
CONFIG_DIR="${CONFIG_ROOT}/config"
# A named volume follows the emulator name. A checkout bind follows the source tree.
# Container-local storage disappears on replacement.
CONFIG_VOLUME="${NAME}-config"
CONFIG_MOUNT="type=volume,src=${CONFIG_VOLUME},dst=${CONFIG_ROOT},volume-nocopy"

# Optional token: env LICHESS_TOKEN, or repo-local gitignored file.
TOKEN_FILE="${TOKEN_FILE:-${ROOT}/.lichess-token}"
TOKEN_IF_NEW=0
if [ -z "${LICHESS_TOKEN:-}" ] && [ -f "${TOKEN_FILE}" ]; then
  LICHESS_TOKEN="$(tr -d ' \t\r\n' < "${TOKEN_FILE}")"
  TOKEN_IF_NEW=1
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

PREVIOUS_ID="$(docker ps -a --no-trunc --format '{{.ID}} {{.Names}}' |
  awk -v name="${NAME}" '$2 == name { print $1 }')"
if [ -n "${PREVIOUS_ID}" ]; then
  PREVIOUS_MOUNT="$(docker container inspect --format \
    "{{range .Mounts}}{{if eq .Destination \"${CONFIG_ROOT}\"}}{{.Type}} {{.Name}}{{end}}{{end}}" \
    "${PREVIOUS_ID}")"
  if [ "${PREVIOUS_MOUNT}" != "volume ${CONFIG_VOLUME}" ]; then
    PREVIOUS_RUNNING="$(docker container inspect --format '{{.State.Running}}' "${PREVIOUS_ID}")"
    if [ "${PREVIOUS_RUNNING}" = true ]; then
      docker stop "${PREVIOUS_ID}" >/dev/null
    fi
    if ! migrate_legacy_config "${PREVIOUS_ID}"; then
      echo "Could not preserve configuration from ${NAME}. Its container is still available." >&2
      if [ "${PREVIOUS_RUNNING}" = true ]; then
        docker start "${PREVIOUS_ID}" >/dev/null ||
          echo "Could not restart ${NAME}. Retry with docker start ${NAME}." >&2
      fi
      exit 1
    fi
  fi
  docker rm -f "${PREVIOUS_ID}" >/dev/null
fi

RUN_ARGS=(
  -d --name "${NAME}"
  -p "127.0.0.1:${PORT}:6080"
  -v "${ROOT}:/workspace/remarkable-lichess"
  -v "${APPLOAD_HOST}:/workspace/rm-appload"
  -v "${XOVI_HOST}:/workspace/xovi"
  --mount "${CONFIG_MOUNT}"
  -e "REMARKABLE_LICHESS_CONFIG_DIR=${CONFIG_DIR}"
  # Key compiled output by checkout and image. Host targets mix platforms, and
  # a shared build directory can reuse artifacts from the wrong checkout.
  -v "${CACHE_PREFIX}-${BUILD_KEY}-build:/tmp/remarkable-lichess-build"
  -v "${CACHE_PREFIX}-cargo-registry:/usr/local/cargo/registry"
  -v "${CACHE_PREFIX}-cargo-git:/usr/local/cargo/git"
  -e APP_SRC=/workspace/remarkable-lichess
  -e APPLOAD_SRC=/workspace/rm-appload
  -e XOVI_SRC=/workspace/xovi
)
if [ -n "${LICHESS_TOKEN:-}" ]; then
  export LICHESS_TOKEN
  RUN_ARGS+=(-e LICHESS_TOKEN -e "LICHESS_TOKEN_IF_NEW=${TOKEN_IF_NEW}")
fi

echo "Starting emulator on http://localhost:${PORT}/vnc.html"
docker run "${RUN_ARGS[@]}" "${IMAGE}"

echo "Container ${NAME} started. Waiting for noVNC..."
for ((attempt = 0; attempt < 90; attempt++)); do
  if curl -sf "http://127.0.0.1:${PORT}/vnc.html" >/dev/null 2>&1; then
    echo "Ready: http://localhost:${PORT}/vnc.html"
    echo "Logs: docker logs -f ${NAME}"
    exit 0
  fi
  if ! docker ps --format '{{.Names}}' | grep -qx "${NAME}"; then
    echo "Container exited early:" >&2
    docker logs "${NAME}" >&2 || true
    exit 1
  fi
  sleep 2
done

echo "Still starting (first build compiles Qt + Rust). Follow logs:"
echo "  docker logs -f ${NAME}"
echo "Then open http://localhost:${PORT}/vnc.html"
