#!/usr/bin/env bash
set -euo pipefail

APP_SRC="${APP_SRC:-/workspace/remarkable-lichess}"
APPLOAD_SRC="${APPLOAD_SRC:-/workspace/rm-appload}"
XOVI_SRC="${XOVI_SRC:-/workspace/xovi}"
APP_DIR="${APPLOAD_SRC}/applications_root/remarkable-lichess"
TOKEN_DIR="/home/root/.config/remarkable-lichess"

mkdir -p "$TOKEN_DIR" /tmp/.X11-unix
chmod 1777 /tmp/.X11-unix

echo "==> Building AppLoad PC emulator for Linux"
export XOVI_REPO="${XOVI_SRC}"
cd "${APPLOAD_SRC}"
# Host checkout may contain macOS .o/Makefile artifacts — wipe and regenerate.
make distclean >/dev/null 2>&1 || true
make clean >/dev/null 2>&1 || true
rm -f .qmake.stash Makefile appload
rm -f ./*.o ./*/*.o ./src/*.o ./src/*/*.o ./moc_*.cpp ./qrc_*.cpp 2>/dev/null || true
find . -maxdepth 3 \( -name '*.o' -o -name 'moc_*.cpp' -o -name 'qrc_*.cpp' \) -delete 2>/dev/null || true
rm -rf appload.app
qmake6 .
make -j"$(nproc)"
test -x "${APPLOAD_SRC}/appload"

echo "==> Building Linux backend with transport"
cd "${APP_SRC}/backend"
# Keep Linux artifacts out of the macOS host target/ tree.
export CARGO_TARGET_DIR=/tmp/remarkable-lichess-backend-target
cargo build --release --features transport --bin backend
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
"${RCC_BIN}" --binary -o resources.rcc application.qrc

echo "==> Staging app into applications_root"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/backend"
cp "${APP_SRC}/frontend/manifest.json" "${APP_DIR}/manifest.json"
cp "${APP_SRC}/frontend/resources.rcc" "${APP_DIR}/resources.rcc"
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
# Arg auto-starts that application id (see AppLoadEmuOnly).
./appload remarkable-lichess >/tmp/appload.log 2>&1 &
APP_PID=$!

echo "Ready: open http://localhost:6080/vnc.html"
echo "Auto-starting Lichess app (id=remarkable-lichess)."
wait "${APP_PID}"
