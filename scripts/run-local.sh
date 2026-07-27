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

# Optional token: env LICHESS_TOKEN, or repo-local gitignored file.
TOKEN_FILE="${TOKEN_FILE:-${ROOT}/.lichess-token}"
if [ -z "${LICHESS_TOKEN:-}" ] && [ -f "${TOKEN_FILE}" ]; then
  LICHESS_TOKEN="$(tr -d ' \t\r\n' < "${TOKEN_FILE}")"
fi

echo "Building local-pc image (first run is slow)..."
docker build -t "${IMAGE}" "${ROOT}/docker/local-pc"

docker rm -f "${NAME}" >/dev/null 2>&1 || true

RUN_ARGS=(
  -d --name "${NAME}"
  -p "${PORT}:6080"
  -v "${ROOT}:/workspace/remarkable-lichess"
  -v "${APPLOAD_HOST}:/workspace/rm-appload"
  -v "${XOVI_HOST}:/workspace/xovi"
  -e APP_SRC=/workspace/remarkable-lichess
  -e APPLOAD_SRC=/workspace/rm-appload
  -e XOVI_SRC=/workspace/xovi
)
if [ -n "${LICHESS_TOKEN:-}" ]; then
  RUN_ARGS+=(-e "LICHESS_TOKEN=${LICHESS_TOKEN}")
  echo "Seeding Lichess token into the emulator."
else
  echo "No LICHESS_TOKEN / .lichess-token yet — Setup screen will ask for one."
fi

echo "Starting emulator on http://localhost:${PORT}/vnc.html"
docker run "${RUN_ARGS[@]}" "${IMAGE}"

echo "Container ${NAME} started. Waiting for noVNC..."
for i in $(seq 1 90); do
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