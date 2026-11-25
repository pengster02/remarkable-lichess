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
trap 'rm -rf -- "${STAGE}"' EXIT

mkdir "${STAGE}/backend"
cp target/aarch64-unknown-linux-gnu/release/backend "${STAGE}/backend/entry"

cd "${ROOT}/frontend"
cp manifest.json "${STAGE}/manifest.json"

# A local rcc avoids preparing the Docker compiler image.
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
  (
    unset DOCKER_DEFAULT_PLATFORM
    RCC_CONTEXT="${ROOT}/docker/tablet-rcc"
    # Recipe tags allow offline reuse. A fixed tag can hide Dockerfile edits,
    # and always building can require a registry lookup for the base image.
    RCC_IMAGE="remarkable-lichess-tablet-rcc:$(cksum < "${RCC_CONTEXT}/Dockerfile" | awk '{print $1 "-" $2}')"
    if ! docker image inspect "${RCC_IMAGE}" >/dev/null 2>&1; then
      docker build -t "${RCC_IMAGE}" "${RCC_CONTEXT}"
    fi
    echo "Using Docker Qt resource compiler ${RCC_IMAGE}"
    docker run --rm --network none --user "$(id -u):$(id -g)" \
      -v "$PWD:/frontend:ro" -v "${STAGE}:/bundle" -w /frontend \
      "${RCC_IMAGE}" --binary -o /bundle/resources.rcc application.qrc
  )
fi

python3 "${ROOT}/scripts/tablet-package.py" publish "${STAGE}"
