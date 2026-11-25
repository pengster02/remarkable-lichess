#!/usr/bin/env bash
set -euo pipefail

# Cross-compile the Rust backend for the Paper Pro Move's aarch64 target via
# `cross`'s own default Docker image for this triple -- no Cross.toml exists
# in backend/ (there's nothing to customize about the image yet). Adjust the
# target triple if `cross` reports a mismatch for your specific rm-appload
# toolchain image.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}/backend"
# Local dev sometimes exports CARGO_TARGET_DIR for `cargo test` runs --
# unset it here so the `cp` below (which assumes the default ./target layout)
# doesn't silently pick up a stale/empty binary if that's still set in the
# calling shell.
unset CARGO_TARGET_DIR
# cross-rs publishes amd64-only images; on Apple Silicon, pin the platform so
# `docker run` does not look for a missing linux/arm64 manifest.
export CROSS_CONTAINER_OPTS="${CROSS_CONTAINER_OPTS:---platform linux/amd64}"
# --features transport is required here: the bin target (and backend_app.rs)
# are gated behind it since they depend on appload-client (see Global Constraints
# and Task 1) — this is the first point in the whole plan where that feature is
# actually compiled, since the dev machine used for Tasks 1-9 had no Linux target.
# `production` turns logging on for the shipped build only (see backend/Cargo.toml);
# without it a release build compiles every log call out.
cross build --locked --release --target aarch64-unknown-linux-gnu --features transport,production --bin backend

mkdir -p "${ROOT}/dist"
STAGE="$(mktemp -d "${ROOT}/dist/.remarkable-lichess.build.XXXXXXXX")"
STUB_DIR=""
cleanup() {
  rm -rf -- "${STAGE}"
  if [ -n "${STUB_DIR}" ]; then rm -rf -- "${STUB_DIR}"; fi
}
trap cleanup EXIT

mkdir "${STAGE}/backend"
cp target/aarch64-unknown-linux-gnu/release/backend "${STAGE}/backend/entry"

cd "${ROOT}/frontend"
cp manifest.json "${STAGE}/manifest.json"

# A local rcc can emit the same resource format as the wheel. Using it avoids
# pulling a compiler image for a stub or installing Qt packages in a container.
if [ -z "${RCC_BIN:-}" ] && command -v rcc >/dev/null && rcc --version >/dev/null 2>&1; then
  RCC_BIN="$(command -v rcc)"
fi
if [ -z "${RCC_BIN:-}" ] && command -v qmake6 >/dev/null; then
  if qt_libexec="$(qmake6 -query QT_HOST_LIBEXECS 2>/dev/null)" && [ -x "${qt_libexec}/rcc" ]; then
    RCC_BIN="${qt_libexec}/rcc"
  fi
fi
if [ -n "${RCC_BIN:-}" ]; then
  echo "Using Qt resource compiler ${RCC_BIN}"
  "${RCC_BIN}" --binary -o "${STAGE}/resources.rcc" application.qrc
else

# AppLoad loads QML from a compiled Qt resource bundle (resources.rcc), not
# loose .qml files on disk -- confirmed on-device (Task 14): it requests
# qrc:/<app-namespace>/ui/main.qml, which only resolves if a real .rcc exists.
# When a local Qt compiler is unavailable, compile via containers without
# apt-installing qt6-base-dev in an Ubuntu container
# (the original approach here): some build environments can reach PyPI,
# crates.io, and Docker Hub just fine but not Debian/Ubuntu's own package
# mirrors at all (confirmed live in one such environment: every apt mirror,
# http and https, timed out on every retry, while pip/cargo/docker pull all
# worked immediately) -- and qt6-base-dev alone pulls in ~30 packages
# (vulkan, wayland, gtk theme, translations, ...), multiplying the exposure
# to that kind of flaky/blocked package-mirror access for zero benefit, since
# only the `rcc` binary itself is ever used.
#
# Instead: PySide6's own PyPI wheel bundles the real Qt6 `rcc` binary (same
# binary format Qt itself ships, since PySide6 is built from the same Qt6
# source) plus almost all of its shared-library dependencies -- except
# libglib-2.0.so.0, needed only by libQt6Core.so.6's optional GLib
# event-loop integration, which a plain file-to-file `rcc` invocation never
# actually drives. glib_stub.c supplies just the ~15 symbols that
# integration needs to *load* (confirmed via `nm -D` against the real
# libQt6Core.so.6), compiled fresh each run using the same aarch64 cross
# toolchain the backend build above already pulled -- no extra image, no
# extra network dependency, and no risk of a stale prebuilt binary drifting
# from its own source.
  CROSS_IMAGE="ghcr.io/cross-rs/aarch64-unknown-linux-gnu:main"
  # The amd64 cross image emits the arm64 stub for the PySide container.
  STUB_DIR="$(mktemp -d)"
  cp ../scripts/glib_stub.c "$STUB_DIR/"
  docker run --rm --platform linux/amd64 -v "$STUB_DIR:/stub" "$CROSS_IMAGE" \
    aarch64-linux-gnu-gcc-13 -shared -fPIC -Wl,-soname,libglib-2.0.so.0 -o /stub/libglib-2.0.so.0 /stub/glib_stub.c

# Do NOT inherit DOCKER_DEFAULT_PLATFORM=linux/amd64 here: PySide6's rcc must
# run as the host's native arch (arm64 on Apple Silicon) so the aarch64 glib
# stub above can load. Force clearing the platform for this one container.
  docker run --rm --platform linux/arm64 \
    -v "$(pwd):/frontend:ro" \
    -v "$STUB_DIR:/stublib:ro" \
    -v "${STAGE}:/bundle" \
    python:3-slim bash -c '
      set -e
      pip install --no-cache-dir --quiet pyside6-essentials
      PYSIDE_DIR="$(python3 -c "import PySide6, os; print(os.path.dirname(PySide6.__file__))")"
      cp /stublib/libglib-2.0.so.0 "$PYSIDE_DIR/Qt/lib/libglib-2.0.so.0"
      cd /frontend && "$PYSIDE_DIR/Qt/libexec/rcc" --binary -o /bundle/resources.rcc application.qrc
    '
fi

python3 "${ROOT}/scripts/tablet-package.py" publish "${STAGE}"
