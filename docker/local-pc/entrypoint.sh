#!/usr/bin/env bash
set -euo pipefail

APP_SRC="${APP_SRC:-/workspace/remarkable-lichess}"
APPLOAD_SRC="${APPLOAD_SRC:-/workspace/rm-appload}"
XOVI_SRC="${XOVI_SRC:-/workspace/xovi}"
APP_DIR="${APPLOAD_SRC}/applications_root/remarkable-lichess"
BUILD_ROOT="/tmp/remarkable-lichess-build"
APPLOAD_BUILD_DIR="${BUILD_ROOT}/appload"
export REMARKABLE_LICHESS_CONFIG_DIR="${REMARKABLE_LICHESS_CONFIG_DIR:-/tmp/remarkable-lichess-config}"

install -d -m 0700 "$REMARKABLE_LICHESS_CONFIG_DIR"
mkdir -p /tmp/.X11-unix
chmod 1777 /tmp/.X11-unix

echo "==> Building AppLoad PC emulator for Linux"
export XOVI_REPO="${XOVI_SRC}"
mkdir -p "${APPLOAD_BUILD_DIR}"
cd "${APPLOAD_BUILD_DIR}"
# An out-of-tree build keeps host files intact. Cleaning in place deletes host
# output, and copying the whole source tree makes each rebuild cold.
qmake6 "${APPLOAD_SRC}/appload.pro"
make -j"$(nproc)"
test -x "${APPLOAD_BUILD_DIR}/appload"

echo "==> Building Linux backend with transport"
cd "${APP_SRC}/backend"
# Keep Linux artifacts out of the macOS host target/ tree.
export CARGO_TARGET_DIR="${BUILD_ROOT}/backend"
cargo build --locked --release --features transport --bin backend
BACKEND_BIN="${CARGO_TARGET_DIR}/release/backend"

echo "==> Building resources.rcc"
cd "${APP_SRC}/frontend"
RCC_BIN=""
for candidate in /usr/lib/qt6/libexec/rcc /usr/lib/aarch64-linux-gnu/qt6/libexec/rcc rcc; do
  if command -v "$candidate" >/dev/null 2>&1 || [ -x "$candidate" ]; then
    RCC_BIN="$candidate"
    break
  fi
done
if [ -z "${RCC_BIN}" ]; then
  echo "Qt rcc not found" >&2
  exit 1
fi
RCC_FILE="${BUILD_ROOT}/resources.rcc"
"${RCC_BIN}" --binary -o "${RCC_FILE}" application.qrc

echo "==> Staging app into applications_root"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/backend"
cp "${APP_SRC}/frontend/manifest.json" "${APP_DIR}/manifest.json"
cp "${RCC_FILE}" "${APP_DIR}/resources.rcc"
cp "${BACKEND_BIN}" "${APP_DIR}/backend/entry"
chmod +x "${APP_DIR}/backend/entry"

echo "==> Starting Xvfb + window manager + noVNC"
Xvfb :1 -screen 0 "${RESOLUTION}" -ac +extension GLX +render -noreset &
sleep 1
openbox &
x11vnc -display :1 -forever -shared -rfbport 5900 -nopw -xkb >/tmp/x11vnc.log 2>&1 &
websockify --web=/usr/share/novnc 6080 localhost:5900 >/tmp/websockify.log 2>&1 &

echo "==> Launching AppLoad emulator"
cd "${APPLOAD_SRC}"
# Keep the container alive even if the emulator exits; restart for local testing.
while true; do
  "${APPLOAD_BUILD_DIR}/appload" remarkable-lichess >>/tmp/appload.log 2>&1 &
  APP_PID=$!
  echo "AppLoad started (pid=${APP_PID})"
  wait "${APP_PID}" || true
  echo "AppLoad exited; restarting in 2s..." >>/tmp/appload.log
  sleep 2
done
