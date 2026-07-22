#!/usr/bin/env bash
set -euo pipefail

# Cross-compile the Rust backend for the Paper Pro Move's aarch64 target via
# `cross`'s own default Docker image for this triple -- no Cross.toml exists
# in backend/ (there's nothing to customize about the image yet). Adjust the
# target triple if `cross` reports a mismatch for your specific rm-appload
# toolchain image.
cd "$(dirname "$0")/../backend"
# The plan's own dev docs tell developers to export CARGO_TARGET_DIR for local
# `cargo test` runs (see docs/superpowers/plans/2026-07-21-ui-strategy-phases-plan.md) --
# unset it here so the `cp` below (which assumes the default ./target layout)
# doesn't silently pick up a stale/empty binary if that's still set in the
# calling shell.
unset CARGO_TARGET_DIR
# --features transport is required here: the bin target (and backend_app.rs)
# are gated behind it since they depend on appload-client (see Global Constraints
# and Task 1) — this is the first point in the whole plan where that feature is
# actually compiled, since the dev machine used for Tasks 1-9 had no Linux target.
cross build --release --target aarch64-unknown-linux-gnu --features transport --bin backend

mkdir -p ../dist/remarkable-lichess/backend
cp target/aarch64-unknown-linux-gnu/release/backend ../dist/remarkable-lichess/backend/entry

cd ../frontend
cp manifest.json ../dist/remarkable-lichess/manifest.json

# AppLoad loads QML from a compiled Qt resource bundle (resources.rcc), not
# loose .qml files on disk -- confirmed on-device (Task 14): it requests
# qrc:/<app-namespace>/ui/main.qml, which only resolves if a real .rcc exists.
# No Qt toolchain on the macOS dev machine, so compile it in a throwaway
# Ubuntu container via Rancher/Docker instead.
docker run --rm -e DEBIAN_FRONTEND=noninteractive \
  -v "$(pwd):/frontend" \
  ubuntu:24.04 bash -c "
    apt-get update -qq && apt-get install -y -qq qt6-base-dev >/dev/null 2>&1
    cd /frontend && /usr/lib/qt6/libexec/rcc --binary -o resources.rcc application.qrc
  "
cp resources.rcc ../dist/remarkable-lichess/resources.rcc
