#!/usr/bin/env bash
set -euo pipefail

# Cross-compile the Rust backend for the Paper Pro Move's aarch64 target,
# following the same Cross.toml-based approach chessmarkable uses for this
# device family. Adjust the target triple if `cross` reports a mismatch for
# your specific rm-appload toolchain image.
cd "$(dirname "$0")/../backend"
# --features transport is required here: the bin target (and backend_app.rs)
# are gated behind it since they depend on appload-client (see Global Constraints
# and Task 1) — this is the first point in the whole plan where that feature is
# actually compiled, since the dev machine used for Tasks 1-9 had no Linux target.
cross build --release --target aarch64-unknown-linux-gnu --features transport --bin backend

mkdir -p ../dist/remarkable-lichess
cp target/aarch64-unknown-linux-gnu/release/backend ../dist/remarkable-lichess/backend

cd ../frontend
cp manifest.json ../dist/remarkable-lichess/manifest.json
# QML resource compilation (rcc) follows rm-appload's own example build
# scripts (build-rm.sh / build-rmpp.sh in examples/appload/full/) — copy the
# exact rcc invocation from whichever of those matches this device's XOVI
# version once confirmed in Task 14 Step 3, rather than guessing the flags here.
cp -r ui ../dist/remarkable-lichess/ui
